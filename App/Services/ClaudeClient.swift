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
    case notConfigured, server(Int, String), decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect your Claude server in Settings to use this."
        case .server(let code, let msg): return code == 429 ? "Claude is at its usage limit, so try again later." : "Server error \(code): \(msg)"
        case .decoding: return "Couldn't understand the server's reply."
        }
    }
}

/// Talks to claude-server (see ../claude-server). Haiku = `.fast`, Sonnet = `.reason`.
final class ClaudeClient {
    static let shared = ClaudeClient()

    var baseURL: URL? {
        get { UserDefaults.standard.string(forKey: "server.url").flatMap(URL.init(string:)) }
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

    func complete(_ req: AIRequest) async throws -> AIResponse {
        guard let base = baseURL, let key = apiKey, !key.isEmpty else { throw AIError.notConfigured }
        var r = URLRequest(url: base.appendingPathComponent("v1/complete"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = req.model == AITier.reason.rawValue ? 120 : 45
        r.httpBody = try JSONEncoder().encode(req)
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONDecoder().decode([String: [String: String]].self, from: data))?["error"]?["message"]
                ?? String(data: data, encoding: .utf8) ?? ""
            throw AIError.server(code, String(msg.prefix(200)))
        }
        return try JSONDecoder().decode(AIResponse.self, from: data)
    }

    func structured<T: Decodable>(_ tier: AITier, system: String, user: String, schema: JSONValue,
                                  as type: T.Type, cacheTTL: Int? = nil) async throws -> T {
        let res = try await complete(AIRequest(tier: tier, system: system, messages: [AIMessage(role: "user", content: user)],
                                               schema: schema, cacheTTL: cacheTTL))
        if let s = res.structured, let v = try? s.decode(T.self) { return v }
        if let d = res.text.data(using: .utf8), let v = try? JSONDecoder().decode(T.self, from: d) { return v }
        throw AIError.decoding
    }

    func text(_ tier: AITier, system: String, messages: [AIMessage]) async throws -> String {
        try await complete(AIRequest(tier: tier, system: system, messages: messages)).text
    }

    func ping() async -> Bool {
        guard let base = baseURL else { return false }
        var r = URLRequest(url: base.appendingPathComponent("health"))
        r.timeoutInterval = 8
        if let k = apiKey { r.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["ok"] == .bool(true)
    }
}
