import Foundation

/// v1.6 E3 / F1: something that's on but isn't working (a permission iOS took away or never gave after a reinstall,
/// an automation sending "App"). Today shows them first in Heads Up, once a day each, with a way to fix it.
public struct SetupProblem: Hashable, Identifiable, Sendable {
    public enum Fix: String, Sendable { case settings, shortcutsGuide, health }
    public var id: String
    public var title: String
    public var message: String
    public var fix: Fix
    public var fixTitle: String

    /// Dismissed for the day: the key in `AppState.dismissed`.
    public func dismissKey(on day: DayKey) -> String { "setup:\(id):\(day)" }
}

public enum SetupProblems {
    public struct Input: Sendable {
        public var locationWanted = false
        /// iOS's answer: "always", "whenInUse", "denied", "notDetermined".
        public var location = "notDetermined"
        public var notificationsWanted = false
        public var notificationsDenied = false
        /// When "Opened an App" last sent the word "App" (nil once fixed).
        public var appLiteralSeen: Date?
        public var healthWanted = false
        /// Health reads have worked but found nothing measured in the last 3 days.
        public var healthEmpty = false
        public var now: Date
        public init(now: Date) { self.now = now }
    }

    public static func find(_ x: Input) -> [SetupProblem] {
        var out: [SetupProblem] = []
        if x.locationWanted && x.location == "denied" {
            out.append(SetupProblem(id: "location", title: "Location Is Off",
                                    message: "Places, leave reminders and arriving home need Location set to Always.",
                                    fix: .settings, fixTitle: "Open Settings"))
        } else if x.locationWanted && x.location == "whenInUse" {
            out.append(SetupProblem(id: "location", title: "Location Is While Using",
                                    message: "Places like school and leave reminders need Always. In Settings, tap Location → Always.",
                                    fix: .settings, fixTitle: "Open Settings"))
        }
        if x.notificationsWanted && x.notificationsDenied {
            out.append(SetupProblem(id: "notifications", title: "Notifications Are Off",
                                    message: "Session starts, bedtime and questions can't reach you.", fix: .settings, fixTitle: "Open Settings"))
        }
        if let seen = x.appLiteralSeen, x.now.timeIntervalSince(seen) < 2 * 86400 {
            out.append(SetupProblem(id: "apps", title: "Screen Time Isn't Logging Apps",
                                    message: "The “Opened an App” automation sends the word “App” instead of the app's name, so app time isn't logged.",
                                    fix: .shortcutsGuide, fixTitle: "Fix It"))
        }
        if x.healthWanted && x.healthEmpty {
            out.append(SetupProblem(id: "health", title: "Productium Can't Read Health",
                                    message: "Nothing came from Health for 3 days. In Health, tap your picture → Apps → Productium and turn everything on.",
                                    fix: .health, fixTitle: "Open Health"))
        }
        return out
    }

    /// The ones not dismissed today.
    public static func showing(_ all: [SetupProblem], dismissed: Set<String>, today: DayKey) -> [SetupProblem] {
        all.filter { !dismissed.contains($0.dismissKey(on: today)) }
    }
}
