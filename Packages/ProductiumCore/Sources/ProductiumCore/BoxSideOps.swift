import Foundation

/// A Screen Time reading the box read off a screenshot (`screen_time add`).
public struct BoxScreen: Codable, Hashable, Sendable {
    public struct App: Codable, Hashable, Sendable {
        public var name: String
        public var minutes: Int
        public var category: String?
        public var pickups: Int?
        public var notifications: Int?
        public init(name: String, minutes: Int, category: String? = nil, pickups: Int? = nil, notifications: Int? = nil) {
            self.name = name; self.minutes = minutes; self.category = category; self.pickups = pickups; self.notifications = notifications
        }
    }
    /// Total screen minutes for the day.
    public var minutes: Int?
    /// "day" (default) or "week" / "average" (the daily average).
    public var period: String?
    /// The date label shown on the screenshot ("Today", "Wed, Nov 19").
    public var dateLabelShown: String?
    public var date: String?
    public var partial: Bool?
    public var pickups: Int?
    public var firstPickup: String?
    public var notifications: Int?
    public var apps: [App]?
    public init() {}
}

/// The box's ops that touch `AppState` outside `BoxState` (O6): `setting` (a knob), `mood`, `screen_time`.
/// `BoxApplier` reports them as "isn't handled here", so the App filters them out with `split`, applies the rest with
/// `BoxApplier`, and applies these with `apply`.
public enum BoxSideOps {
    public static func isSide(_ op: BoxOp) -> Bool { op.noun == .setting || op.noun == .mood || op.noun == .screen_time }

    public static func split(_ ops: [BoxOp]) -> (box: [BoxOp], side: [BoxOp]) {
        (ops.filter { !isSide($0) }, ops.filter(isSide))
    }

    public struct Result: Hashable, Sendable {
        public var lines: [String] = []
        public var problems: [String] = []
    }

    public static func apply(_ ops: [BoxOp], to s: inout AppState, aboutMe: inout AboutMe, now: Date,
                             calendar cal: Calendar, writer: Writer = .box) -> Result {
        var r = Result()
        for op in ops {
            switch op.noun {
            case .setting: setting(op.fields, &s, &aboutMe, writer, &r)
            case .mood: mood(op.fields, &s, now, &r)
            case .screen_time: screenTime(op.fields.screen, &s, now, cal, &r)
            default: break
            }
        }
        return r
    }

    /// `title` = the knob, `text` = the value ("nudgeLevel" / "gentle").
    static func setting(_ f: BoxFields, _ s: inout AppState, _ me: inout AboutMe, _ writer: Writer, _ r: inout Result) {
        guard let key = f.title?.trimmingCharacters(in: .whitespaces), !key.isEmpty,
              let value = f.text?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            r.problems.append("A setting needs a name (title) and a value (text)"); return
        }
        var ds = s.dumpState
        ds.aboutMe = me
        switch Knobs.set(key, value, by: writer, in: &ds) {
        case .changed(let line): r.lines.append("Setting: \(line)")
        case .refused(let why): r.problems.append(why)
        }
        s.dumpState = ds
        me = ds.aboutMe
    }

    static func mood(_ f: BoxFields, _ s: inout AppState, _ now: Date, _ r: inout Result) {
        guard let m = f.mood, (1...5).contains(m) else { r.problems.append("A mood needs a number 1-5"); return }
        let energy = f.energy.flatMap { (1...5).contains($0) ? $0 : nil }
        s.moods.append(MoodEntry(at: now, mood: m, energy: energy, note: f.note))
        r.lines.append("Mood \(m)/5" + (energy.map { ", energy \($0)/5" } ?? ""))
    }

    static func screenTime(_ sc: BoxScreen?, _ s: inout AppState, _ now: Date, _ cal: Calendar, _ r: inout Result) {
        guard let sc else { r.problems.append("A screen_time op needs a screen reading"); return }
        let rawApps = (sc.apps ?? []).filter { !$0.name.isEmpty }
        ScrollingApps.register(rawApps.map { ($0.name, $0.category) }, into: &s.scrollingApps)
        let apps = rawApps.map {
            AppUsage(name: $0.name, minutes: max(0, $0.minutes), distracting: false,
                     pickups: $0.pickups.map { max(0, $0) }, notifications: $0.notifications.map { max(0, $0) })
        }
        var entry = ScreenDay(day: .distantPast, distractingMinutes: 0, totalMinutes: sc.minutes.map { max(0, $0) },
                              apps: apps.isEmpty ? nil : apps, source: "screenshot", partial: sc.partial == true ? true : nil,
                              pickups: sc.pickups.map { max(0, $0) }, firstPickup: ScreenReceipt.parseClock(sc.firstPickup),
                              notifications: sc.notifications.map { max(0, $0) })
        entry = entry.recomputed(s.scrollingApps)
        if apps.isEmpty { r.problems.append("That screenshot shows no apps, so I can't tell how much of it was scrolling") }
        let period = (sc.period ?? "day").lowercased()
        if period.contains("week") || period.contains("average") || period.contains("avg") {
            entry.day = cal.startOfDay(for: now)
            entry.source = "screenshot-average"
            s.screenAverages.removeAll { cal.isDate($0.day, inSameDayAs: entry.day) }
            s.screenAverages.append(entry)
            s.screenAverages = Array(s.screenAverages.sorted { $0.day < $1.day }.suffix(12))
            r.lines.append(ScreenReceipt.line(entry, label: "Daily average"))
            if let m = entry.mismatch { r.problems.append("Daily average doesn't add up: \(m). Which is right?") }
            return
        }
        let d = ScreenDates.resolve(label: sc.dateLabelShown, date: sc.date.flatMap { AIMapper.parseDate($0, timeZone: cal.timeZone) },
                                    now: now, calendar: cal)
        entry.day = d
        if let existing = s.screen.first(where: { cal.isDate($0.day, inSameDayAs: d) }), existing.source == "screenshot" {
            entry = existing.merged(with: entry, s.scrollingApps)
        }
        s.screen.removeAll { cal.isDate($0.day, inSameDayAs: d) }
        s.screen.append(entry)
        s.screen.sort { $0.day < $1.day }
        let label = DateFormatter.local("EEE d MMM", cal).string(from: d)
        r.lines.append(ScreenReceipt.line(entry, label: label))
        if let m = entry.mismatch { r.problems.append("Screen Time for \(label) doesn't add up: \(m). Tell me which number is right.") }
    }
}
