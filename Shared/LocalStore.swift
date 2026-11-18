import Foundation

/// Where the app keeps its small settings and its files: the standard defaults and Application Support.
/// (Was `SharedConfig` with an App Group; v1.1 has a single app, so no group is needed.)
enum LocalStore {
    static var defaults: UserDefaults { .standard }

    static var containerURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    enum Key {
        static let pendingDeepLink = "app.pendingDeepLink"
        static let frictionGraceUntil = "friction.graceUntil"
        static let frictionPrefix = "friction.pauses."
        static let scrollLog = "friction.scrollLog"
        static let scrollCheckIns = "friction.checkIns"
        static let scrollCheckInIndex = "friction.checkInIndex"
        /// When the charger was connected (from the "Probably Stopped Scrolling" automation), newest last; a sleep-start signal.
        static let chargingTimes = "sleep.chargingTimes"
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
