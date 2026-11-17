import Foundation

// MARK: - Brain dump: one box for everything
//
// The student types (or pastes a screenshot of) anything: new deadlines, what they did,
// what changed, how they feel, a question. Claude returns a list of actions plus a reply.
// `DumpApplier` turns them into state changes on the device, deterministically and
// testably, and reports what it changed so the UI can show it with an Undo.

public struct DumpApp: Codable, Hashable, Sendable {
    public var name: String
    public var minutes: Int
    public var distracting: Bool?
}

/// One piece of a `split_activity`: "Period 1 8:30-9:20".
public struct DumpPart: Codable, Hashable, Sendable {
    public var title: String
    public var start: String
    public var end: String
    public var weekdays: [Int]?
    public var color: String?

    public init(title: String, start: String, end: String, weekdays: [Int]? = nil, color: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.weekdays = weekdays
        self.color = color
    }
}

/// One flat action record. Only the fields relevant to `type` are set.
public struct DumpAction: Codable, Hashable, Sendable {
    public var type: String
    /// A reference from the context ("t3f9a2", "a81c0d", "e…", "d…"): exact, so nothing gets duplicated.
    public var id: String?
    /// The existing thing's name, when there's no id.
    public var target: String?
    public var title: String?
    public var kind: String?
    public var subject: String?
    public var due: String?
    public var estimateMinutes: Int?
    public var importance: Int?
    public var difficulty: Int?
    public var progressMinutes: Int?
    public var doneMinutes: Int?
    public var topics: [String]?
    public var notes: String?
    /// The task a new task is a step of (an id).
    public var parent: String?
    public var color: String?
    public var weekdays: [Int]?
    public var start: String?
    public var end: String?
    public var bufferMinutes: Int?
    public var validFrom: String?
    public var validUntil: String?
    public var parts: [DumpPart]?
    public var date: String?
    public var cancelled: Bool?
    public var wake: String?
    public var activity: String?
    public var category: String?
    public var phase: String?
    public var at: String?
    public var routine: String?
    public var minutes: Int?
    public var enabled: Bool?
    public var mood: Int?
    public var energy: Int?
    public var note: String?
    public var screenMinutes: Int?
    public var distractingMinutes: Int?
    public var apps: [DumpApp]?
    /// settings: which setting (see `DumpSettings.keys`) and its new value, as text.
    public var key: String?
    public var value: String?
    // Older settings fields, still applied if a reply uses them.
    public var sleepNeedMinutes: Int?
    public var freeDayWake: String?
    public var maxStudyMinutesSchoolDay: Int?
    public var minFreeMinutesSchoolDay: Int?
    public var interests: [String]?

    public init(type: String) { self.type = type }
}

public struct DumpResult: Codable, Hashable, Sendable {
    public var actions: [DumpAction]
    public var reply: String
    public init(actions: [DumpAction], reply: String) { self.actions = actions; self.reply = reply }

    /// Lenient: a reply with no actions, or actions with no reply, still counts. One malformed
    /// action is dropped rather than losing the whole message.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = (try? c.decodeIfPresent(String.self, forKey: .reply)) ?? ""
        let raw = (try? c.decodeIfPresent([JSONValue].self, forKey: .actions)) ?? []
        actions = raw.compactMap { try? $0.decode(DumpAction.self) }
        guard !reply.isEmpty || !raw.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no actions and no reply"))
        }
    }
}

extension DumpResult {
    /// Reads the Inbox answer out of a reply, whatever shape it came back in: the schema's
    /// `{actions, reply}`, a list of actions, one action on its own, the reply under another name,
    /// or plain prose (shown as the reply, changing nothing). Nil only when there's nothing to
    /// show and nothing to do.
    public static func read(_ res: AIResponse) -> DumpResult? {
        for c in res.candidates {
            let fitted = StructuredRepair.coerce(normalise(c), to: Schemas.dump)
            if var r = try? fitted.decode(DumpResult.self) {
                r.reply = r.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                return r
            }
        }
        // No JSON at all, just sentences: the model answered in words. That's a reply.
        let prose = res.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard res.candidates.isEmpty, prose.filter(\.isLetter).count >= 3, !prose.contains("{"), !prose.contains("```"),
              !["null", "none", "undefined"].contains(prose.lowercased()) else { return nil }
        return DumpResult(actions: [], reply: String(prose.prefix(600)))
    }

    static func normalise(_ v: JSONValue) -> JSONValue {
        guard case .object(var o) = v else { return v }
        let plain = Dictionary(o.keys.map { (StructuredRepair.plain($0), $0) }, uniquingKeysWith: { a, _ in a })
        func value(_ names: [String]) -> JSONValue? { names.lazy.compactMap { plain[$0].flatMap { o[$0] } }.first }
        if plain["reply"] == nil,
           let r = value(["message", "response", "answer", "text", "summary", "content", "output"]), case .string = r {
            o["reply"] = r
        }
        if plain["actions"] == nil {
            if let a = value(["action", "changes", "items", "tasks"]) {
                o["actions"] = a
            } else if case .string(let t)? = value(["type"]), DumpActionType(loose: t) != nil {
                // One action on its own, with the reply (if any) beside its fields.
                var action = o
                action["reply"] = nil
                o = ["actions": .array([.object(action)]), "reply": o["reply"] ?? .string("")]
            }
        }
        return .object(o)
    }
}

public enum DumpActionType: String, CaseIterable, Sendable {
    case addTask = "add_task", updateTask = "update_task", completeTask = "complete_task", reopenTask = "reopen_task"
    case deleteTask = "delete_task"
    case addActivity = "add_activity", updateActivity = "update_activity", deleteActivity = "delete_activity"
    case splitActivity = "split_activity"
    case addEvent = "add_event", updateEvent = "update_event", deleteEvent = "delete_event"
    case changeDay = "change_day", deleteDayChange = "delete_day_change"
    case log, routine, mood
    case screenTime = "screen_time", settings, setColor = "set_color"

    /// The schema's names, plus the near misses a model can produce: "addTask", "create_task",
    /// "mark_done", "remove_activity", "screentime", "preferences", "colour", "split_school".
    public init?(loose raw: String) {
        if let exact = DumpActionType(rawValue: raw) { self = exact; return }
        let words = raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).lowercased()
            .split(whereSeparator: { !$0.isLetter }).map(String.init)
        let joined = words.joined(separator: "_")
        if let exact = DumpActionType(rawValue: joined) { self = exact; return }
        func has(_ options: String...) -> Bool { words.contains { options.contains($0) } }
        let activity = has("activity", "activities", "commitment", "class", "classes", "club", "practice")
        let remove = has("delete", "remove", "cancel", "drop", "clear")
        let change = has("update", "change", "edit", "move", "reschedule", "modify", "rename", "set")
        if has("screen", "screentime") { self = .screenTime }
        else if has("color", "colour", "colors", "colours", "paint", "tint") { self = .setColor }
        else if has("setting", "settings", "preference", "preferences", "prefs") { self = .settings }
        else if has("mood", "feeling", "energy") { self = .mood }
        else if has("routine") { self = .routine }
        else if has("split", "divide", "periods") { self = .splitActivity }
        else if has("day", "exception") { self = remove ? .deleteDayChange : .changeDay }
        else if has("event", "appointment") { self = remove ? .deleteEvent : change ? .updateEvent : .addEvent }
        else if has("log", "checkin", "marker", "happened") { self = .log }
        else if has("reopen", "undone", "uncomplete", "incomplete", "unfinish", "undo") { self = .reopenTask }
        else if has("complete", "completed", "done", "finish", "finished") { self = .completeTask }
        else if remove { self = activity ? .deleteActivity : .deleteTask }
        else if change { self = activity ? .updateActivity : .updateTask }
        else if has("add", "create", "new") { self = activity ? .addActivity : .addTask }
        else { return nil }
    }
}

/// The slice of app state the brain dump may change.
public struct DumpState: Sendable {
    public var items: [WorkItem]
    public var commitments: [Commitment]
    public var exceptions: [DayException]
    public var oneOffs: [FixedEvent]
    public var markers: [TimelineEvent]
    public var routines: [Routine]
    public var moods: [MoodEntry]
    public var screen: [ScreenDay]
    public var prefs: Preferences

    public init(items: [WorkItem], commitments: [Commitment], exceptions: [DayException], oneOffs: [FixedEvent],
                markers: [TimelineEvent], routines: [Routine], moods: [MoodEntry], screen: [ScreenDay], prefs: Preferences) {
        self.items = items
        self.commitments = commitments
        self.exceptions = exceptions
        self.oneOffs = oneOffs
        self.markers = markers
        self.routines = routines
        self.moods = moods
        self.screen = screen
        self.prefs = prefs
    }
}

