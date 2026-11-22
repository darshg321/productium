import Foundation

/// Which build this is. Release and dev builds install side by side (different bundle id, name, icon and URL scheme),
/// so everything that leaves the app (links, the Reminders list, the calendar, Health) goes through here.
enum AppInfo {
    /// "productium" in release builds, "productium-dev" in dev builds (Info.plist `ProductiumURLScheme`).
    static var scheme: String { Bundle.main.object(forInfoDictionaryKey: "ProductiumURLScheme") as? String ?? "productium" }
    static var isDev: Bool { scheme != "productium" }
    /// "Productium" or "Productium Dev": the Reminders list and calendar are named after it.
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Productium" }

    /// A link iOS opens in this build: `url("today")` → productium-dev://today in a dev build.
    static func url(_ path: String) -> URL? { URL(string: "\(scheme)://\(path)") }

    /// Inside the app every link is written productium://…; links arriving in this build's own scheme are mapped to it.
    static func normalised(_ url: URL) -> String {
        let s = url.absoluteString
        let mine = "\(scheme)://"
        return s.hasPrefix(mine) ? "productium://" + s.dropFirst(mine.count) : s
    }
}
