import Foundation

/// Full local backup. The student owns their data: export, restore, delete.
public struct Backup: Codable, Sendable {
    public var version: Int
    public var exportedAt: Date
    public var preferences: Preferences
    public var items: [WorkItem]
    public var commitments: [Commitment]
    public var routines: [Routine]
    public var markers: [TimelineEvent]
    public var outcomes: [BlockOutcome]
    public var moods: [MoodEntry]
    public var health: [HealthDay]
    public var screen: [ScreenDay]
    public var learned: LearnedModel
    public var taper: ScreenTaper
    public var flashcards: [Flashcard]

    public init(version: Int = 1, exportedAt: Date, preferences: Preferences, items: [WorkItem], commitments: [Commitment],
                routines: [Routine], markers: [TimelineEvent], outcomes: [BlockOutcome], moods: [MoodEntry],
                health: [HealthDay], screen: [ScreenDay], learned: LearnedModel, taper: ScreenTaper, flashcards: [Flashcard]) {
        self.version = version
        self.exportedAt = exportedAt
        self.preferences = preferences
        self.items = items
        self.commitments = commitments
        self.routines = routines
        self.markers = markers
        self.outcomes = outcomes
        self.moods = moods
        self.health = health
        self.screen = screen
        self.learned = learned
        self.taper = taper
        self.flashcards = flashcards
    }
}

public enum Exporter {
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func iso(_ d: Date?) -> String { d.map { iso($0) } ?? "" }

    public static func csv(_ header: [String], _ rows: [[String]]) -> String {
        func esc(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return ([header] + rows).map { $0.map(esc).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    public static func segmentsCSV(_ segs: [Segment]) -> String {
        csv(["start", "end", "minutes", "category", "label", "inferred"],
            segs.map { [iso($0.start), iso($0.end), "\($0.minutes)", $0.category.rawValue, $0.label, $0.inferred ? "1" : "0"] })
    }

    public static func dailyCSV(_ days: [DayTotals]) -> String {
        let cats = TimeCategory.allCases
        let header: [String] = ["date"] + cats.map(\.rawValue)
            + ["planned_study", "done_study", "mood", "sleep_min", "screen_min", "screen_target", "steps"]
        var rows: [[String]] = []
        for d in days {
            var row: [String] = [String(iso(d.day).prefix(10))]
            for c in cats { row.append(String(d.minutes[c] ?? 0)) }
            row.append(String(d.plannedStudy))
            row.append(String(d.doneStudy))
            row.append(d.mood.map { String(format: "%.1f", $0) } ?? "")
            row.append(d.sleep.map { String($0) } ?? "")
            row.append(d.screen.map { String($0) } ?? "")
            row.append(d.screenTarget.map { String($0) } ?? "")
            row.append(d.steps.map { String($0) } ?? "")
            rows.append(row)
        }
        return csv(header, rows)
    }

    public static func itemsCSV(_ items: [WorkItem]) -> String {
        csv(["title", "kind", "subject", "due", "estimate_min", "completed_min", "importance", "difficulty", "done", "done_at", "source"],
            items.map { [$0.title, $0.kind.rawValue, $0.subject ?? "", iso($0.due), "\($0.estimateMinutes)", "\($0.completedMinutes)",
                         "\($0.importance)", "\($0.difficulty)", $0.isDone ? "1" : "0", iso($0.doneAt), $0.source.rawValue] })
    }

    public static func outcomesCSV(_ o: [BlockOutcome]) -> String {
        csv(["planned_start", "planned_min", "actual_min", "status", "kind"],
            o.map { [iso($0.plannedStart), "\($0.plannedMinutes)", "\($0.actualMinutes)", $0.status.rawValue, $0.kind?.rawValue ?? ""] })
    }

    public static func moodsCSV(_ m: [MoodEntry]) -> String {
        csv(["at", "mood", "energy", "note"], m.map { [iso($0.at), "\($0.mood)", $0.energy.map(String.init) ?? "", $0.note ?? ""] })
    }

    public static func markersCSV(_ m: [TimelineEvent]) -> String {
        csv(["at", "phrase", "activity", "category", "phase", "source"],
            m.map { [iso($0.at), $0.phrase, $0.activity, $0.category.rawValue, $0.phase.rawValue, $0.source.rawValue] })
    }

    /// The plan as an .ics file (import into Google Calendar, etc.).
    public static func ics(_ plan: Plan, includeKinds: Set<BlockKind> = [.work, .review, .windDown]) -> String {
        func stamp(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return f.string(from: d)
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Productium//Plan//EN", "CALSCALE:GREGORIAN"]
        for b in plan.blocks where includeKinds.contains(b.kind) {
            lines += ["BEGIN:VEVENT", "UID:\(b.id.uuidString)@productium", "DTSTAMP:\(stamp(plan.generatedAt))",
                      "DTSTART:\(stamp(b.start))", "DTEND:\(stamp(b.end))", "SUMMARY:\(esc(b.title))"]
            if let h = b.hint { lines.append("DESCRIPTION:\(esc(h))") }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func json<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(value)
    }

    public static func decodeBackup(_ data: Data) throws -> Backup {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Backup.self, from: data)
    }
}
