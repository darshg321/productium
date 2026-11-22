import Foundation
import ProductiumCore

struct RestorePreview: Identifiable {
    let id = UUID()
    var exportedAt: Date?
    var summary: String
    var bundle: ExportBundle
}

enum Persistence {
    static var url: URL { LocalStore.containerURL.appendingPathComponent("state.json") }

    /// Set when the stored state couldn't be read; `AppModel` writes it to the telemetry on launch (T2).
    nonisolated(unsafe) static var loadError: String?
    /// The schema a migrated state was stored with (M); its file is kept as `state-schema-<n>.json`.
    nonisolated(unsafe) static var migratedFrom: Int?

    static func load() -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        let stored = Migrations.storedSchema(data)
        if stored >= Migrations.oldest && stored < AppState.schema {
            migratedFrom = stored
            let copy = LocalStore.containerURL.appendingPathComponent("state-schema-\(stored).json")
            if !FileManager.default.fileExists(atPath: copy.path) { try? data.write(to: copy, options: .atomic) }
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode(AppState.self, from: data)
        } catch {
            loadError = "\(error) (\(data.count) bytes)"
            return AppState()
        }
    }

    /// Returns the error text when the state couldn't be encoded or written, so callers can record it (T2).
    @discardableResult
    static func save(_ s: AppState) -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(s)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return nil
        } catch {
            return "\(error)"
        }
    }
}

enum AboutMeStore {
    static var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("about-me.md")
    }

    static func load() -> AboutMe {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return AboutMe.parse(text)
    }

    static func save(_ me: AboutMe) {
        try? Data(me.markdown.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum CallLogStore {
    static var url: URL { LocalStore.containerURL.appendingPathComponent("ai-calls.json") }

    static func load() -> AICallLog {
        guard let data = try? Data(contentsOf: url) else { return AICallLog() }
        return (try? ExportBundle.decoder().decode(AICallLog.self, from: data)) ?? AICallLog()
    }

    static func save(_ log: AICallLog) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(log) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
