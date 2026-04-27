import Foundation
import Darwin

/// One-shot loopback HTTP server used as the OAuth redirect target for
/// installed-app flows (Gmail, Claude subscription). Binds to 127.0.0.1 on an
/// OS-assigned port, accepts a single connection, extracts the OAuth query
/// params from the request line, and returns a simple HTML response.
///
/// We use BSD sockets directly instead of Network.framework — the latter
/// returns EINVAL on `NWListener(using: .tcp, on: .any)` for some macOS versions,
/// and for a short-lived one-request listener the raw-socket path is simpler.
final class LoopbackOAuthServer {
    struct CallbackResult {
        let code: String?
        let state: String?
        let error: String?
    }

    private var listenFd: Int32 = -1

    /// Bind and listen. Returns the chosen port.
    ///
    /// Pass a non-zero `preferredPort` for OAuth providers that require an
    /// exact-match registered redirect URL (Slack). Pass 0 (default) to let
    /// the OS pick — fine for providers that allow any localhost port for
    /// installed-app flows (Google, Microsoft consumer).
    func start(preferredPort: UInt16 = 0) async throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        addr.sin_port = preferredPort.bigEndian

        let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            close(fd)
            if preferredPort != 0 && err == EADDRINUSE {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                              userInfo: [NSLocalizedDescriptionKey:
                                "Port \(preferredPort) is in use. Find what's holding it with `lsof -iTCP:\(preferredPort) -sTCP:LISTEN` and quit it, then retry."])
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "bind failed (\(String(cString: strerror(err))))"])
        }

        // Read back the assigned port.
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        guard listen(fd, 1) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "listen failed"])
        }

        listenFd = fd
        return port
    }

    /// Accept one connection, read its request line, write a response, return the parsed query.
    /// Polls with `poll()` at 100ms intervals so we can react to:
    ///   - caller cancellation (the Cancel button) — propagated via the
    ///     cancellation handler below, which closes the listen socket so
    ///     `poll()` returns an error
    ///   - `stop()` being called externally (socket closes → poll returns error)
    ///   - overall timeout
    func waitForCallback(timeoutSeconds: Int = 120) async throws -> CallbackResult {
        let fd = listenFd
        guard fd >= 0 else {
            throw NSError(domain: "LoopbackOAuth", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "server not started"])
        }
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        // Task.detached doesn't inherit the parent's cancellation, so plumb
        // it through manually: closing the listen fd makes poll() error and
        // unwinds the detached task as a CancellationError.
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.acceptAndParse(listenFd: fd, deadline: deadline)
            }.value
        } onCancel: { [weak self] in
            self?.stop()
        }
    }

    func stop() {
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
    }

    // MARK: - private

    private static func acceptAndParse(listenFd: Int32, deadline: Date) throws -> CallbackResult {
        // Wait for readability with cancellation-friendly polling.
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            if Date() >= deadline {
                throw NSError(domain: "LoopbackOAuth", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "OAuth timeout"])
            }
            var pfd = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 100)  // 100ms tick
            if r < 0 {
                if errno == EINTR { continue }
                // listenFd was closed externally (stop()) → bail.
                throw CancellationError()
            }
            if r == 0 { continue }  // no pending connection yet
            break
        }

        var clientAddr = sockaddr()
        var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFd = accept(listenFd, &clientAddr, &clientLen)
        guard clientFd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "accept failed"])
        }
        defer { close(clientFd) }

        var buf = [UInt8](repeating: 0, count: 8192)
        let n = buf.withUnsafeMutableBufferPointer { recv(clientFd, $0.baseAddress, $0.count, 0) }
        let request: String = {
            if n > 0 { return String(decoding: buf.prefix(n), as: UTF8.self) }
            return ""
        }()
        let firstLine = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let result = parseQuery(requestLine: firstLine)

        let body = (result.error == nil)
            ? "<html><body style='font-family:-apple-system;max-width:480px;margin:80px auto;padding:20px'><h2>Connected ✓</h2><p>You can close this tab and return to Lede.</p></body></html>"
            : "<html><body style='font-family:-apple-system;max-width:480px;margin:80px auto;padding:20px'><h2>Error</h2><pre>\((result.error ?? "").replacingOccurrences(of: "<", with: "&lt;"))</pre></body></html>"
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = resp.withCString { cstr -> ssize_t in
            send(clientFd, cstr, strlen(cstr), 0)
        }
        return result
    }

    private static func parseQuery(requestLine: String) -> CallbackResult {
        // "GET /callback?code=...&state=... HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .init(code: nil, state: nil, error: "malformed request") }
        let path = String(parts[1])
        guard let comps = URLComponents(string: "http://localhost\(path)") else {
            return .init(code: nil, state: nil, error: "bad url")
        }
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let err = q["error"] {
            return .init(code: nil, state: q["state"], error: err)
        }
        return .init(code: q["code"], state: q["state"], error: nil)
    }
}
