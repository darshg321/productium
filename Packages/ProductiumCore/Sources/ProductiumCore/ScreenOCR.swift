import Foundation

// v1.2 M5 / M6: Screen Time screenshots read on the phone. Vision's OCR gives lines of text; this decides whether it's
// a Screen Time screen and reads it (day or week view: total, apps, pickups, first pickup, notifications). The box
// only gets the image if this can't read it. M9: the Reminders mirror's diff. M2: start / stop toggles.

public struct ScreenReading: Hashable, Sendable {
    public var period: String
    public var dateLabel: String?
    public var minutes: Int?
    /// A week view's "Total Screen Time" (its apps are totals for the week).
    public var totalMinutes: Int?
    public var apps: [BoxScreen.App]
    public var pickups: Int?
    public var firstPickup: String?
    public var notifications: Int?

    public var box: BoxScreen {
        var b = BoxScreen()
        b.minutes = minutes
        b.totalMinutes = totalMinutes
        b.period = period
        b.dateLabelShown = dateLabel
        b.pickups = pickups
        b.firstPickup = firstPickup
        b.notifications = notifications
        b.apps = apps.isEmpty ? nil : apps
        return b
    }
}

public enum ScreenOCR {
    static let markers = ["screen time", "daily average", "most used", "pickups", "first pickup", "notifications", "show categories",
                          "see all app & website activity", "see all activity"]

    /// A Screen Time screen: at least two of its section words.
    public static func isScreenTime(_ text: String) -> Bool {
        let t = text.lowercased()
        return markers.filter { t.contains($0) }.count >= 2
    }

    /// Something that looks like homework to offer as a task: a due word and a date or weekday.
    public static func looksLikeAssignment(_ text: String) -> Bool {
        let t = text.lowercased()
        let due = ["due", "assignment", "submit", "deadline", "quiz", "test on", "homework"].contains { t.contains($0) }
        let when = t.range(of: #"\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|\b\d{1,2}/\d{1,2}\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \d{1,2}"#,
                           options: .regularExpression) != nil
        return due && when && !isScreenTime(text)
    }

    /// "3h 22m", "1 hr 5 min", "48m", "22 min", "2h" → minutes.
    public static func duration(_ s: String) -> Int? {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"^(?:(\d{1,2})\s*(?:h|hr|hrs|hours?))?\s*(?:(\d{1,2})\s*(?:m|min|mins|minutes?))?$"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func g(_ i: Int) -> Int? { Range(m.range(at: i), in: t).flatMap { Int(t[$0]) } }
        let h = g(1), mi = g(2)
        guard h != nil || mi != nil else { return nil }
        return (h ?? 0) * 60 + (mi ?? 0)
    }

    static let notApps: Set<String> = ["screen time", "daily average", "most used", "show categories", "show apps & websites", "pickups",
                                       "notifications", "first pickup", "total screen time", "today", "yesterday", "week", "day",
                                       "limits", "see all app & website activity", "see all activity", "updated today", "social",
                                       "entertainment", "productivity & finance", "creativity", "information & reading", "games",
                                       "education", "other", "utilities", "health & fitness", "shopping & food", "travel"]

    /// A duration at the start of a line: "6h 33min 18% from last week" → 393.
    static func leadingDuration(_ s: String) -> Int? {
        let t = s.lowercased()
        guard let r = t.range(of: #"^\d{1,2}\s*(?:h|hr|hrs|hours?)(?:\s*\d{1,2}\s*(?:m|min|mins|minutes?))?(?=\s|$)|^\d{1,2}\s*(?:m|min|mins|minutes?)(?=\s|$)"#,
                              options: .regularExpression) else { return nil }
        return duration(String(t[r]))
    }

    /// A whole number at the start of a line: "108 5% from last week" → 108, "Daily Average 72" → 72.
    static func leadingNumber(_ s: String) -> Int? {
        let t = s.lowercased().replacingOccurrences(of: "daily average", with: "")
            .replacingOccurrences(of: #"^(?:last|this) week'?s average"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^\d[\d,]*(?=\s|$)"#, options: .regularExpression) else { return nil }
        return Int(t[r].replacingOccurrences(of: ",", with: ""))
    }

    public static func parse(_ text: String) -> ScreenReading? {
        guard isScreenTime(text) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lower = lines.map { $0.lowercased() }
        // iOS 18: "Daily Average"; iOS 26: "Last Week's Average" / "This Week's Average".
        let week = lower.contains { $0.contains("daily average") || $0.contains("week's average") || $0.contains("weeks average") }
            && !lower.contains { $0.hasPrefix("today at") || $0.hasPrefix("today,") }
        var r = ScreenReading(period: week ? "week" : "day", dateLabel: nil, minutes: nil, apps: [], pickups: nil, firstPickup: nil,
                              notifications: nil)
        if week {
            if lower.contains(where: { $0 == "last week" || $0.hasPrefix("last week's average") || $0.hasPrefix("last weeks average") }) {
                r.dateLabel = "Last Week"
            }
        } else if let d = lines.first(where: { $0.range(of: #"^(today|yesterday|(mon|tue|wed|thu|fri|sat|sun)[a-z]*,? [a-z]{3,9} \d{1,2})"#,
                                                         options: [.regularExpression, .caseInsensitive]) != nil }) {
            // Date label: "Today", "Yesterday", or "Wednesday, Nov 19" / "Wed, Nov 19".
            r.dateLabel = d.split(separator: ",").count > 1 && !d.lowercased().hasPrefix("today") ? d : String(d.split(separator: " ").first ?? "")
            if r.dateLabel?.lowercased().hasPrefix("today") == true { r.dateLabel = "Today" }
        }
        enum Section { case screen, pickups, notifications }
        var section = Section.screen
        func next(_ i: Int, _ f: (String) -> Int?) -> Int? {
            for j in (i + 1)..<min(lines.count, i + 4) { if let n = f(lines[j]) { return n } }
            return nil
        }
        for (i, l) in lower.enumerated() {
            if l.hasPrefix("pickups") { section = .pickups }
            if l.hasPrefix("notifications") { section = .notifications }
            if l.hasPrefix("total screen time") {
                if let rr = l.range(of: #"\d{1,2}\s*h.*$|\d{1,2}\s*m.*$"#, options: .regularExpression) {
                    r.totalMinutes = leadingDuration(String(l[rr]))
                }
                continue
            }
            switch section {
            case .screen:
                if r.minutes == nil, l.contains("average") || l.hasPrefix("screen time") || l.hasPrefix("today at") {
                    let own = l.replacingOccurrences(of: #"^.*average"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                    r.minutes = leadingDuration(own) ?? next(i, leadingDuration)
                }
            case .pickups:
                if r.pickups == nil, l.hasPrefix("pickups") || l.contains("average") {
                    r.pickups = leadingNumber(l.replacingOccurrences(of: "pickups", with: "")) ?? next(i, leadingNumber)
                }
            case .notifications:
                if r.notifications == nil, l.hasPrefix("notifications") || l.contains("average") {
                    r.notifications = leadingNumber(l.replacingOccurrences(of: "notifications", with: "")) ?? next(i, leadingNumber)
                }
            }
            if l.contains("first pickup") {
                let joined = ([lines[i]] + (i + 1 < lines.count ? [lines[i + 1]] : [])).joined(separator: " ")
                if let rr = joined.range(of: #"\d{1,2}:\d{2}\s*[AaPp][Mm]"#, options: .regularExpression) { r.firstPickup = String(joined[rr]) }
            }
        }
        if r.minutes == nil, !week { r.minutes = lines.lazy.compactMap(duration).first }
        // Apps: a name line followed by a duration line, after "Most Used", until the next section.
        // (A screen showing categories, "Show Apps & Websites", has no apps on it.)
        if let start = lower.firstIndex(where: { $0.hasPrefix("most used") }), !lower.contains(where: { $0.contains("show apps & websites") }) {
            var i = start + 1
            let end = lower.indices.first { $0 > start && (lower[$0].hasPrefix("pickups") || lower[$0].hasPrefix("show more")
                                                           || lower[$0].hasPrefix("notifications")) } ?? lines.count
            while i < end {
                let name = lines[i], next = i + 1 < end ? lines[i + 1] : ""
                if !notApps.contains(name.lowercased()), duration(name) == nil, name.count <= 40, let m = duration(next) {
                    r.apps.append(BoxScreen.App(name: name, minutes: m))
                    i += 2
                } else if let (n, m) = inline(name), !notApps.contains(n.lowercased()) {
                    r.apps.append(BoxScreen.App(name: n, minutes: m))
                    i += 1
                } else {
                    i += 1
                }
            }
        }
        guard r.minutes != nil || !r.apps.isEmpty || r.pickups != nil else { return nil }
        return r
    }

    /// "Instagram 1h 36m" on one line.
    static func inline(_ s: String) -> (String, Int)? {
        guard let rr = s.range(of: #"\s(\d{1,2}\s*h(?:r|rs)?\s*)?(\d{1,2}\s*m(?:in)?)?$"#, options: .regularExpression),
              let m = duration(String(s[rr])), m > 0 else { return nil }
        let name = s[..<rr.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (name, m)
    }
}

// MARK: - M9: the Reminders mirror

public struct ReminderItem: Hashable, Sendable {
    public var id: String
    public var title: String
    public var completed: Bool
    /// The task it mirrors (kept in the reminder's URL, productium://task/<id>).
    public var taskId: UUID?
    public init(id: String, title: String, completed: Bool, taskId: UUID?) {
        self.id = id
        self.title = title
        self.completed = completed
        self.taskId = taskId
    }
}

public struct ReminderDiff: Hashable, Sendable {
    public var create: [(UUID, String)]
    public var retitle: [(String, String)]
    public var delete: [String]
    /// Ticked off in Reminders: complete these tasks here.
    public var completeTasks: [UUID]

    public static func == (a: ReminderDiff, b: ReminderDiff) -> Bool {
        a.create.map(\.0) == b.create.map(\.0) && a.retitle.map(\.0) == b.retitle.map(\.0) && a.delete == b.delete && a.completeTasks == b.completeTasks
    }
    public func hash(into h: inout Hasher) { h.combine(delete); h.combine(completeTasks) }
}

public enum ReminderMirror {
    /// "Gatsby essay · next Tue 16:00" (the next planned session), else "· due Fri".
    public static func title(_ t: WorkItem, next: Date?, calendar cal: Calendar) -> String {
        if let n = next { return "\(t.title) · next \(DateFormatter.local("EEE HH:mm", cal).string(from: n))" }
        return "\(t.title) · due \(DateFormatter.local("EEE", cal).string(from: t.due))"
    }

    /// Open tasks ↔ the "Productium" list: missing ones are made, titles follow the plan, deleted or finished tasks'
    /// reminders go, and a reminder ticked off in Reminders completes its task here.
    public static func diff(tasks: [WorkItem], reminders: [ReminderItem], next: [UUID: Date], calendar cal: Calendar) -> ReminderDiff {
        var d = ReminderDiff(create: [], retitle: [], delete: [], completeTasks: [])
        let open = tasks.filter { $0.isOpen && $0.parentId == nil }
        let byTask = Dictionary(reminders.compactMap { r in r.taskId.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        for t in open {
            let want = title(t, next: next[t.id], calendar: cal)
            if let r = byTask[t.id] {
                if r.completed { d.completeTasks.append(t.id) } else if r.title != want { d.retitle.append((r.id, want)) }
            } else {
                d.create.append((t.id, want))
            }
        }
        let openIds = Set(open.map(\.id))
        for r in reminders where r.taskId.map({ !openIds.contains($0) }) ?? true {
            if let tid = r.taskId, r.completed, tasks.contains(where: { $0.id == tid && $0.isOpen }) { continue }
            d.delete.append(r.id)
        }
        return d
    }
}

// MARK: - M2: toggles

public enum ActivityToggle {
    /// "Toggle Shower" (an NFC sticker): stops it if it's what's running, otherwise starts it.
    public static func ops(_ title: String, running: Entry?) -> [BoxOp] {
        if let r = running, CategoryRules.key(r.title) == CategoryRules.key(title) { return [BoxOp(.entry, .stop)] }
        return [BoxOp(.entry, .start, BoxFields(title: title))]
    }
}
