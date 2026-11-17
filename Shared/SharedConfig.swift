import Foundation

/// Values shared between the app and its extensions through the App Group.
enum SharedConfig {
    /// From Info.plist key `AppGroup`, set by the APP_GROUP build setting in project.yml.
    static let appGroup: String = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String ?? "group.productium"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    /// App Group container, or (free-account builds without an App Group) Application Support,
    /// which iOS doesn't create by default, so make sure it exists.
    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return url }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    enum Key {
        static let selection = "screen.selection"          // FamilyActivitySelection (JSON)
        static let dailyLimit = "screen.dailyLimit"        // Int minutes, 0 = monitor only
        static let unlocksPerDay = "screen.unlocksPerDay"
        static let unlocksUsedPrefix = "screen.unlocks."   // + yyyy-MM-dd
        static let usagePrefix = "screen.usage."           // + yyyy-MM-dd → Int minutes
        static let shieldReason = "screen.shieldReason"    // "focus" | "limit" | "winddown"
        static let focusTitle = "screen.focusTitle"
        static let focusEnds = "screen.focusEnds"          // Double timeIntervalSince1970
        static let widgetSnapshot = "widget.snapshot"      // WidgetSnapshot JSON
        static let pendingDeepLink = "app.pendingDeepLink"
        static let nudgeOnShield = "screen.nudgeOnShield"
        static let frictionGraceUntil = "friction.graceUntil"   // Double timeIntervalSince1970
        static let frictionPrefix = "friction.pauses."          // + yyyy-MM-dd → Int
        static let scrollLog = "friction.scrollLog"             // ScrollLog JSON (opens, closes, minutes)
        static let scrollCheckIns = "friction.checkIns"         // [Int] minutes after "go back anyway", [] = off
        static let alarmIds = "alarm.nudgeIds"                  // [key: AlarmKit UUID] for nudge alarms
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

/// What the widget / Live Activity shows. Written by the app after each replan.
struct WidgetSnapshot: Codable {
    struct Item: Codable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var kind: String
        var symbol: String
    }
    var generatedAt: Date
    var items: [Item]
    var studyMinutesToday: Int
    var doneMinutesToday: Int

    static func load() -> WidgetSnapshot? {
        guard let d = SharedConfig.defaults.data(forKey: SharedConfig.Key.widgetSnapshot) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { SharedConfig.defaults.set(d, forKey: SharedConfig.Key.widgetSnapshot) }
    }
}
