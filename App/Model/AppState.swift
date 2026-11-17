import Foundation
import ProductiumCore

/// What an export file holds, shown before it replaces anything.
struct RestorePreview: Identifiable {
    let id = UUID()
    var exportedAt: Date?
    var summary: String
    var bundle: ExportBundle
}

enum Persistence {
    static var url: URL { SharedConfig.containerURL.appendingPathComponent("state.json") }

    static func load() -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(AppState.self, from: data)) ?? AppState()
    }

    static func save(_ s: AppState) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// about-me.md: what the app knows about the student, as a markdown file they can edit.
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

/// The full AI call log (prompts and replies) lives in its own file: it's for reading when
/// something looks off, and keeping it out of state.json keeps every save small.
enum CallLogStore {
    static var url: URL { SharedConfig.containerURL.appendingPathComponent("ai-calls.json") }

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
