import Foundation

/// Which apps count as scrolling. The student's list decides, never the model's guess.
public enum ScrollingApps {
    static let social = ["instagram", "tiktok", "snapchat", "facebook", "twitter", "reddit", "threads", "bereal", "pinterest",
                         "tumblr", "discord", "wechat", "weibo", "lemon8", "x formerly twitter"]
    static let video = ["youtube", "netflix", "twitch", "prime video", "disney", "hulu", "crunchyroll", "vimeo", "max"]
    static let games = ["roblox", "fortnite", "minecraft", "genshin", "clash", "brawl", "among us", "candy crush", "pokemon",
                        "subway surfers", "supercell", "valorant", "league of legends", "steam"]

    /// Social, video and games start on. Browsers and tools start off: that's the student's call.
    public static func defaultIsScrolling(_ name: String, category: String? = nil) -> Bool {
        let n = name.lowercased()
        if let c = category?.lowercased() {
            if ["social", "game", "entertainment", "video"].contains(where: c.contains) { return true }
            if ["productivity", "utilities", "education", "reference", "health"].contains(where: c.contains) { return false }
        }
        return (social + video + games).contains { n == $0 || n.contains($0) }
    }

    public static func isScrolling(_ name: String, _ list: [String: Bool], category: String? = nil) -> Bool {
        if let hit = list.first(where: { $0.key.plainKey == name.plainKey }) { return hit.value }
        return defaultIsScrolling(name, category: category)
    }

    /// Lists every app seen so far, with a default for the new ones.
    public static func register(_ apps: [(name: String, category: String?)], into list: inout [String: Bool]) {
        for a in apps where !list.contains(where: { $0.key.plainKey == a.name.plainKey }) {
            list[a.name] = defaultIsScrolling(a.name, category: a.category)
        }
    }
}

extension ScreenDay {
    public var appsTotal: Int { (apps ?? []).reduce(0) { $0 + $1.minutes } }

    /// Scrolling minutes are always the apps, counted with the student's list.
    public func recomputed(_ list: [String: Bool]) -> ScreenDay {
        guard var apps, !apps.isEmpty else { return self }
        for i in apps.indices { apps[i].distracting = ScrollingApps.isScrolling(apps[i].name, list) }
        var out = self
        out.apps = apps
        out.distractingMinutes = apps.filter(\.distracting).reduce(0) { $0 + $1.minutes }
        return out
    }

    public var addsUp: Bool {
        guard let total = totalMinutes, !(apps ?? []).isEmpty else { return true }
        return Double(appsTotal) <= Double(total) * 1.02 + 1
    }

    public var mismatch: String? {
        guard !addsUp, let total = totalMinutes else { return nil }
        return "the apps add up to \(ScreenReceipt.hm(appsTotal)) but the total says \(ScreenReceipt.hm(total))"
    }

    /// Two screenshots of one day: the larger figure per app wins.
    public func merged(with other: ScreenDay, _ list: [String: Bool]) -> ScreenDay {
        var byApp: [String: AppUsage] = [:]
        for a in (apps ?? []) + (other.apps ?? []) {
            let k = a.name.plainKey
            if let e = byApp[k] { byApp[k] = e.minutes >= a.minutes ? e : a } else { byApp[k] = a }
        }
        var out = other
        out.apps = byApp.isEmpty ? nil : byApp.values.sorted { $0.minutes > $1.minutes }
        out.totalMinutes = [totalMinutes, other.totalMinutes].compactMap { $0 }.max()
        out.partial = (partial ?? false) && (other.partial ?? false) ? true : nil
        return out.recomputed(list)
    }
}

public enum ScreenReceipt {
    public static func hm(_ m: Int) -> String {
        m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60)") : "\(m) min"
    }

    public static func line(_ d: ScreenDay, label: String) -> String {
        var s = label + ":"
        if let t = d.totalMinutes { s += " \(hm(t)) total," }
        let scrolling = (d.apps ?? []).filter(\.distracting).sorted { $0.minutes > $1.minutes }
        s += " scrolling \(hm(d.distractingMinutes))"
        if !scrolling.isEmpty { s += " (" + scrolling.map { "\($0.name) \(hm($0.minutes))" }.joined(separator: ", ") + ")" }
        if d.partial == true { s += ", list cut off" }
        return s
    }
}
