import Foundation

/// Which apps count as scrolling. The student's list decides, never the model's guess.
public enum ScrollingApps {
    static let social = ["instagram", "tiktok", "snapchat", "facebook", "twitter", "reddit", "threads", "bereal", "pinterest",
                         "tumblr", "weibo", "lemon8", "x formerly twitter"]
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

    /// Onboarding's list: the apps people most often lose time in, to tick.
    public static let common = ["Instagram", "TikTok", "YouTube", "Snapchat", "Reddit", "X", "Facebook", "Pinterest", "Threads",
                                "BeReal", "Twitch", "Netflix", "Roblox", "Safari", "Chrome"]

    /// Lists every app seen so far, with a default for the new ones.
    public static func register(_ apps: [(name: String, category: String?)], into list: inout [String: Bool]) {
        for a in apps where !list.contains(where: { $0.key.plainKey == a.name.plainKey }) {
            list[a.name] = defaultIsScrolling(a.name, category: a.category)
        }
    }
}

/// v1.3: what an app's time is in the log. Your scrolling list first (Scrolling › the app), then messaging apps.
/// Anything else has no entry (it still counts in Screen Time). Either way it's sensor time: assumed until you say
/// yes, and anything you track yourself wins over it.
public enum AppKinds {
    static let messaging = ["messages", "imessage", "whatsapp", "discord", "messenger", "telegram", "signal", "wechat", "line",
                            "kakaotalk", "groupme", "viber", "facetime", "phone", "slack", "microsoft teams", "teams", "mail", "gmail",
                            "outlook"]

    public static func isMessaging(_ app: String) -> Bool {
        let k = app.plainKey
        return messaging.contains { k == $0.plainKey || k.hasPrefix($0.plainKey + " ") }
    }

    /// The category for an app's session, adding Scrolling › <app> when it's new. Your own filing of that title wins.
    public static func category(for app: String, list: [String: Bool], rules: CategoryRules, tree: inout CategoryTree) -> CategoryID? {
        if let r = rules.learned[CategoryRules.key(app)], r.byYou, tree.node(r.category) != nil { return r.category }
        if ScrollingApps.isScrolling(app, list) {
            if let n = tree.children(CategoryTree.scrolling).first(where: { $0.name.plainKey == app.plainKey }) { return n.id }
            guard tree.node(CategoryTree.scrolling) != nil else { return CategoryTree.scrolling }
            return tree.add(app, under: CategoryTree.scrolling)?.id ?? CategoryTree.scrolling
        }
        if isMessaging(app) { return tree.node(CategoryTree.messaging) != nil ? CategoryTree.messaging : CategoryTree.free }
        return nil
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
        out.pickups = [pickups, other.pickups].compactMap { $0 }.max()
        out.notifications = [notifications, other.notifications].compactMap { $0 }.max()
        out.firstPickup = [firstPickup, other.firstPickup].compactMap { $0 }.min()
        return out.recomputed(list)
    }
}

public enum ScreenReceipt {
    static func clock(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }

    /// "6:42 AM", "06:42", "18:05" → minutes after midnight. Nil if it isn't a time.
    public static func parseClock(_ raw: String?) -> Int? {
        guard var t = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return nil }
        var pm: Bool?
        if t.hasSuffix("pm") { pm = true; t = String(t.dropLast(2)) } else if t.hasSuffix("am") { pm = false; t = String(t.dropLast(2)) }
        let parts = t.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard parts.count >= 1, parts.count <= 2, var h = parts[0], let m = parts.count == 2 ? parts[1] : 0 else { return nil }
        if let pm { guard (1...12).contains(h) else { return nil }; h = h % 12 + (pm ? 12 : 0) }
        guard (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

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
        var extras: [String] = []
        if let p = d.pickups { extras.append("\(p) pickups") }
        if let f = d.firstPickup { extras.append("first at \(clock(f))") }
        if let n = d.notifications { extras.append("\(n) notifications") }
        if !extras.isEmpty { s += "; " + extras.joined(separator: ", ") }
        return s
    }
}

/// Which day a Screen Time screenshot shows. The label on screen ("Today", "Yesterday", "Monday", "Mon 16 Nov")
/// beats the model's `date`, and a screenshot can never show a day after today.
public enum ScreenDates {
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func resolve(label: String?, date: Date?, now: Date, calendar cal: Calendar) -> Date {
        let today = cal.startOfDay(for: now)
        if let l = label?.lowercased(), let d = fromLabel(l, today: today, cal) { return d }
        if let date {
            let d = cal.startOfDay(for: date)
            // A future date is a year slip ("16 Nov" read as next year) or a wrong guess: fall back a year, then to today.
            if d <= today { return d }
            if let back = cal.date(byAdding: .year, value: -1, to: d), back <= today,
               today.timeIntervalSince(back) < 60 * 86400 { return back }
        }
        return today
    }

    static func fromLabel(_ l: String, today: Date, _ cal: Calendar) -> Date? {
        if l.contains("today") { return today }
        if l.contains("yesterday") { return cal.date(byAdding: .day, value: -1, to: today) }
        let words = l.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let dayNumber = words.compactMap { Int($0) }.first { (1...31).contains($0) }
        let month = words.lazy.compactMap { w in months.firstIndex { w.hasPrefix($0) } }.first
        if let dayNumber, let month {
            let y = cal.component(.year, from: today)
            for year in [y, y - 1] {
                if let d = cal.date(from: DateComponents(year: year, month: month + 1, day: dayNumber)), d <= today { return d }
            }
        }
        if let wd = words.lazy.compactMap({ w in w.count >= 3 ? weekdays.firstIndex { $0.hasPrefix(w) } : nil }).first {
            // Most recent such day, today included ("Monday" on a Monday is today's screen).
            let todayWd = cal.component(.weekday, from: today) - 1
            let back = (todayWd - wd + 7) % 7
            return cal.date(byAdding: .day, value: -back, to: today)
        }
        return nil
    }
}

/// Where a day's scrolling number came from, best first.
public enum ScreenSource: String, Codable, Sendable {
    case screenshot, shortcuts, average

    public init(_ d: ScreenDay) {
        switch d.source {
        case "shortcuts": self = .shortcuts
        case "screenshot-average": self = .average
        default: self = .screenshot
        }
    }

    public var label: String {
        switch self {
        case .screenshot: return "from Screen Time"
        case .shortcuts: return "estimated from Shortcuts"
        case .average: return "daily average from Screen Time"
        }
    }
}

public struct ScreenPoint: Hashable, Sendable {
    public var day: Date
    public var scrolling: Int
    public var total: Int?
    public var source: ScreenSource
}

/// One read model for every place that shows screen time (Review Highlights, Your Week, Metrics), so a screenshot
/// shows up wherever screen time is shown. Day screenshots win; Shortcuts estimates fill other days; a week-view
/// (daily average) screenshot covers the 7 days up to the day it was sent, but only days with nothing better.
public enum ScreenSeries {
    public static let averageCovers = 7

    public static func daily(screen: [ScreenDay], averages: [ScreenDay], days: [Date], calendar cal: Calendar) -> [ScreenPoint?] {
        let byDay = Dictionary(screen.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { a, b in
            ScreenSource(a) == .screenshot ? a : b
        })
        let avgs = averages.sorted { $0.day > $1.day }
        return days.map { raw in
            let d = cal.startOfDay(for: raw)
            if let s = byDay[d] {
                return ScreenPoint(day: d, scrolling: s.distractingMinutes, total: s.totalMinutes, source: ScreenSource(s))
            }
            let a = avgs.first { a in
                let start = cal.startOfDay(for: a.day)
                let from = cal.date(byAdding: .day, value: -(averageCovers - 1), to: start) ?? start
                return d >= from && d <= start
            }
            return a.map { ScreenPoint(day: d, scrolling: $0.distractingMinutes, total: $0.totalMinutes, source: .average) }
        }
    }

    public struct Summary: Hashable, Sendable {
        /// Average scrolling a day over the days that have a number.
        public var scrolling: Int
        /// Average total screen time a day, where screenshots gave a total.
        public var total: Int?
        public var daysCovered: Int
        public var sources: Set<ScreenSource>

        /// "1h 10m of scrolling a day (3h 22m total), daily average from Screen Time".
        public var line: String {
            var s = "\(minutesLabel(scrolling)) of scrolling a day"
            if let total { s += " (\(minutesLabel(total)) total)" }
            if sources.count == 1, let only = sources.first { s += ", \(only.label)" }
            return s
        }
    }

    public static func summary(_ points: [ScreenPoint?]) -> Summary? {
        let xs = points.compactMap { $0 }
        guard !xs.isEmpty else { return nil }
        let totals = xs.compactMap(\.total)
        return Summary(scrolling: xs.reduce(0) { $0 + $1.scrolling } / xs.count,
                       total: totals.isEmpty ? nil : totals.reduce(0, +) / totals.count,
                       daysCovered: xs.count, sources: Set(xs.map(\.source)))
    }
}

extension Array where Element == ScreenDay {
    /// Scrolling minutes always follow the apps × your list; run on load so old saved numbers are corrected.
    public func recomputed(_ list: [String: Bool]) -> [ScreenDay] { map { $0.recomputed(list) } }
}
