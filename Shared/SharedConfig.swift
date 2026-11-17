import Foundation

enum SharedConfig {
    static let appGroup: String = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String ?? "group.productium"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return url }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    enum Key {
        static let selection = "screen.selection"
        static let dailyLimit = "screen.dailyLimit"
        static let unlocksPerDay = "screen.unlocksPerDay"
        static let unlocksUsedPrefix = "screen.unlocks."
        static let usagePrefix = "screen.usage."
        static let shieldReason = "screen.shieldReason"
        static let focusTitle = "screen.focusTitle"
        static let focusEnds = "screen.focusEnds"
        static let widgetSnapshot = "widget.snapshot"
        static let pendingDeepLink = "app.pendingDeepLink"
        static let nudgeOnShield = "screen.nudgeOnShield"
        static let frictionGraceUntil = "friction.graceUntil"
        static let frictionPrefix = "friction.pauses."
        static let scrollLog = "friction.scrollLog"
        static let scrollCheckIns = "friction.checkIns"
        static let scrollCheckInIndex = "friction.checkInIndex"
        static let alarmIds = "alarm.nudgeIds"
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

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
