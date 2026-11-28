import CryptoKit
import Foundation
import ProductiumCore

/// v1.6.1: a copy of each backup on the Productium server (`PUT /v1/backup`), so deleting the app loses nothing even
/// without an iCloud folder. Compressed, then sealed with AES-GCM under a key made from the claude-server API key
/// (kept in the Keychain, which survives an uninstall): the server only stores bytes it can't read. A new API key
/// can't open backups sealed with the old one.
@MainActor
enum ServerBackup {
    static let magic = Data("PBK1".utf8)
    static let atKey = "backup.serverAt", errorKey = "backup.serverError"

    enum Failure: LocalizedError {
        case notConnected, status(Int), unreadable
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Connect Claude to keep a copy on the server."
            case .status(let c): return c == 401 ? "The server didn't accept the API key." : "The server answered \(c)."
            case .unreadable: return "The server's backup couldn't be opened with this API key."
            }
        }
    }

    static var lastAt: Date? {
        get { UserDefaults.standard.object(forKey: atKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: atKey) }
    }
    static var lastError: String? {
        get { UserDefaults.standard.string(forKey: errorKey) }
        set { UserDefaults.standard.set(newValue, forKey: errorKey) }
    }

    private static func key(_ apiKey: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("productium-backup:\(apiKey)".utf8)))
    }

    static func seal(_ data: Data, apiKey: String) throws -> Data {
        let packed = try (data as NSData).compressed(using: .zlib) as Data
        guard let box = try AES.GCM.seal(packed, using: key(apiKey)).combined else { throw Failure.unreadable }
        return magic + box
    }

    static func open(_ sealed: Data, apiKey: String) throws -> Data {
        guard sealed.prefix(magic.count) == magic else { throw Failure.unreadable }
        let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(magic.count))
        let packed = try AES.GCM.open(box, using: key(apiKey))
        return try (packed as NSData).decompressed(using: .zlib) as Data
    }

    private static var apiKey: String? { ClaudeClient.shared.apiKey.flatMap { $0.isEmpty ? nil : $0 } }

    private static func request(_ method: String, apiKey: String) throws -> URLRequest {
        guard let base = ClaudeClient.shared.baseURL else { throw Failure.notConnected }
        var r = URLRequest(url: base.appendingPathComponent("v1/backup"), timeoutInterval: 120)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        return r
    }

    /// Returns the bytes sent.
    static func upload(_ data: Data) async throws -> Int {
        guard let apiKey = Self.apiKey else { throw Failure.notConnected }
        var r = try request("PUT", apiKey: apiKey)
        let body = try seal(data, apiKey: apiKey)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: r, from: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.status(code) }
        return body.count
    }

    /// The newest backup on the server, or nil when there's none (or no key yet).
    static func newest() async -> ExportBundle? {
        guard let apiKey = Self.apiKey, var r = try? request("GET", apiKey: apiKey) else { return nil }
        r.timeoutInterval = 30
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let plain = try? open(data, apiKey: apiKey) else { return nil }
        return try? ExportBundle.read(plain)
    }
}

extension AppModel {
    /// After each backup: the same file, sealed, to the server.
    func uploadServerBackup(_ data: Data) async {
        guard ClaudeClient.shared.isConfigured else { return }
        do {
            let bytes = try await ServerBackup.upload(data)
            ServerBackup.lastAt = Date()
            ServerBackup.lastError = nil
            log(.storage, "server_backup_written", ["bytes": "\(bytes)"])
        } catch {
            ServerBackup.lastError = error.localizedDescription
            log(.storage, "server_backup_failed", level: .warn, ["error": "\(error)"])
        }
    }

    /// A fresh install whose Keychain still has the API key: the server's newest backup.
    func serverBackupToOffer() async -> RestorePreview? {
        guard !state.onboarded, let b = await ServerBackup.newest() else { return nil }
        return RestorePreview(exportedAt: b.exportedAt, summary: BackupFiles.offer(b, now: Date(), calendar: cal, kind: "server backup"),
                              bundle: b)
    }
}
