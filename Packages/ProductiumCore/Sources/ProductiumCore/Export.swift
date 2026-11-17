import Foundation

public struct ExportBundle: Codable, Sendable {
    public static let formatID = "productium-export"
    public static let currentVersion = 3

    public struct Device: Codable, Hashable, Sendable {
        public var appVersion: String?
        public var appBuild: String?
        public var systemVersion: String?
        public var model: String?
        public var timeZone: String
        public init(appVersion: String? = nil, appBuild: String? = nil, systemVersion: String? = nil, model: String? = nil,
                    timeZone: String = TimeZone.current.identifier) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.systemVersion = systemVersion
            self.model = model
            self.timeZone = timeZone
        }
    }

    public struct Notification: Codable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var body: String
        public var at: Date?
        public var category: String?
        public var userInfo: JSONValue?
        public init(id: String, title: String, body: String, at: Date? = nil, category: String? = nil, userInfo: JSONValue? = nil) {
            self.id = id
            self.title = title
            self.body = body
            self.at = at
            self.category = category
            self.userInfo = userInfo
        }
    }

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var device: Device

    public var state: AppState
    public var aboutMe: String
    public var callLog: AICallLog
    public var sharedDefaults: [String: JSONValue]
    public var appDefaults: [String: JSONValue]
    public var files: [String: String]

    public var pendingNotifications: [Notification]
    public var deliveredNotifications: [Notification]
    public var permissions: [String: String]
    public var serverSnapshots: [String: JSONValue]

    public init(exportedAt: Date, device: Device, state: AppState, aboutMe: String = "", callLog: AICallLog = AICallLog(),
                sharedDefaults: [String: JSONValue] = [:], appDefaults: [String: JSONValue] = [:], files: [String: String] = [:],
                pendingNotifications: [Notification] = [], deliveredNotifications: [Notification] = [],
                permissions: [String: String] = [:], serverSnapshots: [String: JSONValue] = [:]) {
        self.format = ExportBundle.formatID
        self.version = ExportBundle.currentVersion
        self.exportedAt = exportedAt
        self.device = device
        self.state = state
        self.aboutMe = aboutMe
        self.callLog = callLog
        self.sharedDefaults = sharedDefaults
        self.appDefaults = appDefaults
        self.files = files
        self.pendingNotifications = pendingNotifications
        self.deliveredNotifications = deliveredNotifications
        self.permissions = permissions
        self.serverSnapshots = serverSnapshots
    }

    public static let nonStateStores = ["aboutMe", "callLog", "sharedDefaults", "appDefaults", "files"]

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public enum ReadError: Error, CustomStringConvertible {
        case notAnExport, oldFormat(Int)
        public var description: String {
            switch self {
            case .notAnExport: return "That file isn't a Productium export."
            case .oldFormat(let v): return "That export is format \(v), from an older Productium. Only format 3 and later can be imported."
            }
        }
    }

    public static func read(_ data: Data) throws -> ExportBundle {
        struct Head: Decodable { var format: String?; var version: Int? }
        let head = try? decoder().decode(Head.self, from: data)
        guard let head, head.format == formatID || head.format == "productium-backup" else { throw ReadError.notAnExport }
        guard (head.version ?? 0) >= currentVersion, head.format == formatID else { throw ReadError.oldFormat(head.version ?? 0) }
        return try decoder().decode(ExportBundle.self, from: data)
    }

    public var summary: String {
        let s = state
        let prompts = s.conversation.turns.count + s.archive.conversations.reduce(0) { $0 + $1.turns.count }
        return "\(s.items.count) tasks, \(s.commitments.count) activities, \(s.markers.count) check-ins, "
            + "\(s.outcomes.count) study sessions, \(prompts) prompts, \(callLog.calls.count) AI calls and all settings."
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
}
