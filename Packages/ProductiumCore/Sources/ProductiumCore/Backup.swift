import Foundation

// v1.3 H1: a daily backup file in a folder outside the app (iOS deletes the app's container on uninstall). The
// newest 3 are kept. The folder's bookmark lives in the Keychain and LocalStore (device-only), not here.

public struct BackupState: Codable, Hashable, Sendable {
    /// What the folder is called, for Settings → Backup ("Productium Backups in iCloud Drive").
    public var folderName: String?
    public var lastWrite: Date?
    public var lastFile: String?
    public var lastError: String?
    public var lastErrorAt: Date?

    public init(folderName: String? = nil, lastWrite: Date? = nil, lastFile: String? = nil, lastError: String? = nil,
                lastErrorAt: Date? = nil) {
        self.folderName = folderName
        self.lastWrite = lastWrite
        self.lastFile = lastFile
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folderName = try? c.decodeIfPresent(String.self, forKey: .folderName)
        lastWrite = try? c.decodeIfPresent(Date.self, forKey: .lastWrite)
        lastFile = try? c.decodeIfPresent(String.self, forKey: .lastFile)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        lastErrorAt = try? c.decodeIfPresent(Date.self, forKey: .lastErrorAt)
    }

    enum CodingKeys: String, CodingKey { case folderName, lastWrite, lastFile, lastError, lastErrorAt }

    /// A failure newer than the last good write (shown in Settings → Backup and as a Quiet prompt on Home).
    public var failing: Bool { lastError != nil && (lastErrorAt ?? .distantPast) >= (lastWrite ?? .distantPast) }
}

public enum BackupFiles {
    public static let keep = 3
    public static let prefix = "Productium-"

    public static func name(for d: Date, calendar cal: Calendar) -> String { "\(prefix)\(DayKeys.key(d, cal)).json" }

    /// The day a backup file is from (nil: not one of ours).
    public static func day(of name: String) -> String? {
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let k = String(name.dropFirst(prefix.count).dropLast(5))
        let parts = k.split(separator: "-")
        guard parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return k
    }

    /// v1.6.1: twice a day: on the first refresh or launch 12 h after the last good write (the day's file is replaced).
    public static let interval: TimeInterval = 12 * 3600

    public static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || now < last
    }

    /// Ours, newest first. Other files in the folder are never touched.
    public static func ours(_ names: [String]) -> [String] {
        names.filter { day(of: $0) != nil }.sorted { day(of: $0)! > day(of: $1)! }
    }

    /// What to delete after writing: everything of ours older than the newest `keep`.
    public static func toDelete(_ names: [String], keep: Int = keep) -> [String] { Array(ours(names).dropFirst(keep)) }

    /// "Restore from Friday's backup (2,140 entries)" (`kind` "server backup" for the server's copy).
    public static func offer(_ b: ExportBundle, now: Date, calendar cal: Calendar, kind: String = "backup") -> String {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: b.exportedAt), to: cal.startOfDay(for: now)).day ?? 0
        let f = DateFormatter.local(days < 7 ? "EEEE" : "MMM d", cal)
        let when = days == 0 ? "today's" : days == 1 ? "yesterday's" : "\(f.string(from: b.exportedAt))'s"
        let n = NumberFormatter.localizedString(from: NSNumber(value: b.state.entries.count), number: .decimal)
        return "Restore from \(when) \(kind) (\(n) entries)"
    }
}
