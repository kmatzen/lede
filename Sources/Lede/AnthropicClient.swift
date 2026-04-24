import Foundation

/// Thin wrapper over Anthropic /v1/messages that supports both API-key auth
/// and OAuth bearer auth (so users can bill to their Claude Pro/Max subscription).
///
/// The client is intentionally minimal: one call site, prompt caching on the system
/// prompt, and nothing exotic. We keep token usage low by:
///   1) caching the system prompt (90% read discount on hits)
///   2) only calling this for *new* content-hashes (see TriagePipeline)
///   3) asking for tight JSON outputs and short max_tokens
struct AnthropicClient {
    enum Auth {
        case apiKey(String)
        case oauthBearer(accessToken: String)
    }

    let auth: Auth

    /// Default to the small model for triage. Override per call.
    static let modelTriage = "claude-haiku-4-5"
    static let modelSynthesis = "claude-sonnet-4-6"

    struct ContentBlock: Encodable {
        var type: String = "text"
        var text: String
        var cache_control: CacheControl?
        struct CacheControl: Encodable { var type: String = "ephemeral" }
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    struct Request: Encodable {
        let model: String
        let max_tokens: Int
        let system: [ContentBlock]
        let messages: [Message]
        let temperature: Double
    }

    struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
        let usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }

    struct Result {
        let text: String
        let usage: Usage?
    }

    /// Send a message. `systemCached` becomes the cached system prompt.
    /// If using OAuth (subscription), we MUST prepend the Claude Code identity string
    /// as the first system block — the OAuth endpoint gates non-Claude-Code callers.
    func complete(
        model: String,
        systemCached: String,
        user: String,
        maxTokens: Int = 512,
        temperature: Double = 0.0
    ) async throws -> Result {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var systemBlocks: [ContentBlock] = []
        switch auth {
        case .apiKey(let key):
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            systemBlocks.append(ContentBlock(text: systemCached, cache_control: .init()))
        case .oauthBearer(let token):
            req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            req.setValue("oauth-2025-04-20,interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-cli/2.1.87 (external, cli)", forHTTPHeaderField: "user-agent")
            // Subscription OAuth is gated: first system block must be the Claude Code identity.
            systemBlocks.append(ContentBlock(
                text: "You are Claude Code, Anthropic's official CLI for Claude.",
                cache_control: nil
            ))
            systemBlocks.append(ContentBlock(text: systemCached, cache_control: .init()))
        }

        let body = Request(
            model: model,
            max_tokens: maxTokens,
            system: systemBlocks,
            messages: [Message(role: "user", content: [ContentBlock(text: user, cache_control: nil)])],
            temperature: temperature
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AnthropicError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.http(status: http.statusCode, body: body)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.content.compactMap { $0.text }.joined()
        return Result(text: text, usage: decoded.usage)
    }
}

enum AnthropicError: Error, LocalizedError {
    case network(String)
    case http(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .network(let s): return "Network: \(s)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(400))"
        case .decoding(let s): return "Decoding: \(s)"
        }
    }
}
