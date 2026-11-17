import Foundation
import Security
import ProductiumCore

enum Keychain {
    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                   kSecAttrService as String: "productium"]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecAttrService as String: "productium", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

enum AIError: LocalizedError {
    /// `unusable` carries what came back: a reply with nothing in it the app could show or apply.
    case notConfigured, server(Int, String), unusable(String), overBudget

    /// The raw text behind a failure, for the receipt's Details.
    var detail: String? {
        switch self {
        case .unusable(let raw): return raw.isEmpty ? "(empty reply)" : String(raw.prefix(1500))
        case .server(_, let msg): return msg
        default: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect your Claude server in Settings to use this."
        case .server(let code, let msg):
            switch code {
            case 401: return "The server didn't accept the API key. Check it in Settings → Claude."
            case 429: return "Claude is at its usage limit. Try again in a bit."
            case 529, 503: return "The server is busy. Send again in a moment."
            case 200: return "Your server address answered, but not as claude-server. Check the address in Settings → Claude."
            default: return "Server error \(code): \(msg)"
            }
        case .unusable: return "Claude's reply came back empty twice, so nothing was changed. Send it again."
        case .overBudget: return "Today's AI budget is spent, so this waits until tomorrow."
        }
    }
}

/// What the server says this key used (GET /v1/usage). Its "today" is the server's UTC day.
struct ServerUsage: Decodable, Equatable {
    struct Row: Decodable, Equatable {
        var model: String
        var requests: Int
        var input_tokens: Int
        var output_tokens: Int
        var cached: Int?
        var cache_read_tokens: Int?
        var cache_write_tokens: Int?
        var tokens: Int { output_tokens }
    }
    struct Key: Decodable, Equatable { var name: String?; var rpm: Int?; var daily: Int? }
    var key: Key?
    var today: [Row]
    var last_7_days: [Row]

    var todayTokens: Int { today.reduce(0) { $0 + $1.tokens } }
    var weekTokens: Int { last_7_days.reduce(0) { $0 + $1.tokens } }
    var todayRequests: Int { today.reduce(0) { $0 + $1.requests } }
}

/// Talks to claude-server's Anthropic-compatible API (POST /v1/messages).
/// Every reply's token usage is handed to `onUsage` so the app can meter it.
final class ClaudeClient {
    static let shared = ClaudeClient()
    static let defaultURL = URL(string: "https://raspberrypi.tail29964a.ts.net")!

    /// Called on the main actor with (feature, model, tokens) after every successful request.
    var onUsage: (@MainActor (AIFeature, String, TokenCount) -> Void)?

    var baseURL: URL? {
        get { UserDefaults.standard.string(forKey: "server.url").flatMap(URL.init(string:)) ?? Self.defaultURL }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: "server.url") }
    }

    var apiKey: String? {
        get { Keychain.get("server.key") }
        set { Keychain.set(newValue, for: "server.key") }
    }

    var isConfigured: Bool { baseURL != nil && !(apiKey ?? "").isEmpty }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 90
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func request(_ path: String) throws -> URLRequest {
        guard let base = baseURL, let key = apiKey, !key.isEmpty else { throw AIError.notConfigured }
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        return r
    }

    func complete(_ req: AIRequest, feature: AIFeature) async throws -> AIResponse {
        var r = try request("v1/messages")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ttl = req.cacheTTL { r.setValue(String(ttl), forHTTPHeaderField: "x-cache-ttl") }
        r.timeoutInterval = 120
        r.httpBody = try JSONEncoder().encode(req)
        var (data, resp) = try await session.data(for: r)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Busy or a transient CLI failure: one retry, as the server's guide recommends.
        if [502, 503, 504, 529].contains(code) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            (data, resp) = try await session.data(for: r)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        let body = String(data: data, encoding: .utf8) ?? "(\(data.count) bytes, not text)"
        guard code == 200 else {
            struct Err: Decodable { struct E: Decodable { var message: String? }; var error: E? }
            let msg = (try? JSONDecoder().decode(Err.self, from: data))?.error?.message ?? body
            throw AIError.server(code, String(msg.prefix(200)))
        }
        // Any JSON object is read as a message (see AIResponse). Anything else isn't claude-server.
        guard let res = try? JSONDecoder().decode(AIResponse.self, from: data) else {
            throw AIError.server(200, String(body.prefix(200)))
        }
        let tokens = res.tokens, model = res.model ?? req.model
        if let cb = onUsage { await MainActor.run { cb(feature, model, tokens) } }
        return res
    }

    /// Sends `req` and reads the reply with `read`, which returns nil only when the reply has
    /// nothing usable in it (see Reply.swift). That's rare enough that asking once more is cheaper
    /// than failing; the second request skips the server's response cache so it can't get the
    /// same reply back. Returns the value, the reply it came from, and the tokens of both tries.
    func send<T>(_ req: AIRequest, feature: AIFeature, read: (AIResponse) -> T?) async throws -> (value: T, response: AIResponse, tokens: TokenCount) {
        let first = try await complete(req, feature: feature)
        if let v = read(first) { return (v, first, first.tokens) }
        var again = req
        again.cacheTTL = nil
        let second = try await complete(again, feature: feature)
        guard let v = read(second) else { throw AIError.unusable(second.text.isEmpty ? first.text : second.text) }
        return (v, second, first.tokens + second.tokens)
    }

    /// A reply decoded as `type`. `accept` can turn down an answer that decodes but is empty.
    func structured<T: Decodable>(feature: AIFeature, system: String, user: String, schema: JSONValue, as type: T.Type,
                                  maxTokens: Int, cacheTTL: Int? = nil, accept: @escaping (T) -> Bool = { _ in true }) async throws -> T {
        let req = AIRequest(system: system, messages: [AIMessage(role: "user", content: user)],
                            schema: schema, maxTokens: maxTokens, cacheTTL: cacheTTL)
        return try await send(req, feature: feature) { $0.decoded(T.self, schema: schema, accept: accept) }.value
    }

    /// No tokens: just "is it there". With a key the server also checks auth.
    func ping() async -> Bool {
        guard let base = baseURL else { return false }
        var r = URLRequest(url: base.appendingPathComponent("health"))
        r.timeoutInterval = 8
        if let k = apiKey, !k.isEmpty { r.setValue(k, forHTTPHeaderField: "x-api-key") }
        guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["ok"] == .bool(true)
    }

    enum Check: Equatable { case ok, badKey, unreachable }

    /// Checks the address *and* the key without spending tokens (/health doesn't check keys, /v1/usage does).
    func verify() async -> Check {
        guard let base = baseURL else { return .unreachable }
        var r = URLRequest(url: base.appendingPathComponent("v1/usage"))
        r.timeoutInterval = 8
        r.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
        guard let (_, resp) = try? await session.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else { return .unreachable }
        return code == 200 ? .ok : code == 401 ? .badKey : .unreachable
    }

    /// The server's own count for this key (also no tokens).
    func usage() async -> ServerUsage? {
        guard var r = try? request("v1/usage") else { return nil }
        r.timeoutInterval = 8
        guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ServerUsage.self, from: data)
    }
}
