import Foundation

/// Append-only line log at ~/Library/Application Support/Lede/lede.log and stderr.
/// Intentionally simple: one file, one queue, no rotation.
enum Log {
    static let fileURL: URL = {
        let fm = FileManager.default
        let support = try! fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Lede", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("lede.log")
        rotateIfTooBig(url)
        return url
    }()

    /// Keep the log file from growing without bound: if it's > 5MB, truncate
    /// to the last ~1MB. Cheap one-time check at process start.
    private static func rotateIfTooBig(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return }
        let maxSize = 5 * 1024 * 1024
        guard size > maxSize else { return }
        let keep = 1 * 1024 * 1024
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(size - keep))
        guard let tail = try? handle.readToEnd() else { return }
        try? tail.write(to: url, options: .atomic)
    }

    private static let queue = DispatchQueue(label: "com.lede.log", qos: .utility)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: @autoclosure @escaping () -> String,
                     file: StaticString = #fileID, line: Int = #line) {
        emit("INFO", message(), file: file, line: line)
    }
    static func warn(_ message: @autoclosure @escaping () -> String,
                     file: StaticString = #fileID, line: Int = #line) {
        emit("WARN", message(), file: file, line: line)
    }
    static func error(_ message: @autoclosure @escaping () -> String,
                      file: StaticString = #fileID, line: Int = #line) {
        emit("ERR ", message(), file: file, line: line)
    }

    private static func emit(_ level: String, _ message: String,
                             file: StaticString, line: Int) {
        let ts = iso.string(from: Date())
        let name = "\(file)".split(separator: "/").last.map(String.init) ?? ""
        let formatted = "\(ts) \(level) [\(name):\(line)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(formatted.utf8))
                try? handle.close()
            }
            FileHandle.standardError.write(Data(formatted.utf8))
        }
    }
}
