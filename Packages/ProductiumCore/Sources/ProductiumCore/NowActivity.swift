import Foundation

// v1.3 Part B: one "Now" Live Activity, always there, as the main prompt. Its state is one of running > question >
// untracked > assumed > up next (the first that applies wins). A prompt kind shows here only when its severity is
// Live Activity (Part E); otherwise it's a notification. Buttons are actions the app's LiveActivityIntent runs.
// A Live Activity can't update itself without a push, so a card that ends at a known time (assumed School until 15:00,
// a session at 19:00) carries the card to show after it (`then`, shown once the content is stale).

public enum NowKind: String, Codable, Sendable {
    case running, question, untracked, assumed, upNext
}

public struct NowButton: Codable, Hashable, Sendable {
    /// What the intent does: `stop`, `start:<title>`, `answer:<inference id>:<answer>`, `yes:<ref>`, `no:<ref>`, `task:<id>`.
    public var action: String
    public var label: String
    public var symbol: String?

    public init(_ action: String, _ label: String, _ symbol: String? = nil) {
        self.action = action
        self.label = label
        self.symbol = symbol
    }
}

public struct NowCard: Codable, Hashable, Sendable {
    public var kind: NowKind
    public var title: String
    public var subtitle: String?
    /// The timer's start: the running entry, or the start of the untracked stretch.
    public var since: Date?
    public var buttons: [NowButton]
    /// "Other" opens the box (untracked) or the app.
    public var other: Bool

    public init(kind: NowKind, title: String, subtitle: String? = nil, since: Date? = nil, buttons: [NowButton] = [], other: Bool = false) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.since = since
        self.buttons = buttons
        self.other = other
    }
}

public struct NowState: Hashable, Sendable {
    public var card: NowCard
    public var then: NowCard?
    /// When `card` stops being true and `then` shows.
    public var until: Date?
}

public struct NowInput {
    public var now: Date
    public var calendar: Calendar
    public var entries: [Entry]
    public var plan: Plan
    public var items: [WorkItem]
    public var book: DayRuleBook
    public var tree: CategoryTree
    public var question: Inference?
    /// The likeliest tiles now (A3), for "What are you doing?".
    public var tiles: [QuickStart]
    public var prompts: PromptSettings
    public var goalLine: String?

    public init(now: Date, calendar: Calendar, entries: [Entry], plan: Plan, items: [WorkItem], book: DayRuleBook = DayRuleBook(),
                tree: CategoryTree, question: Inference? = nil, tiles: [QuickStart] = [], prompts: PromptSettings = PromptSettings(),
                goalLine: String? = nil) {
        self.now = now
        self.calendar = calendar
        self.entries = entries
        self.plan = plan
        self.items = items
        self.book = book
        self.tree = tree
        self.question = question
        self.tiles = tiles
        self.prompts = prompts
        self.goalLine = goalLine
    }
}

public enum NowActivity {
    /// The shortest untracked stretch worth asking about live.
    public static let untrackedAfter = 10

    /// The state that wins now (nil: nothing to show, e.g. asleep with nothing planned).
    public static func make(_ x: NowInput) -> NowState? {
        let hm = DateFormatter.local("H:mm", x.calendar)
        let on = { (k: PromptKind) in x.prompts[k] == .liveActivity }
        if let r = TimeLog.running(x.entries) {
            var buttons = [NowButton("stop", "Stop", "stop.fill")]
            if let t = x.tiles.first(where: { $0.key != CategoryRules.key(r.title) }) {
                buttons.append(NowButton("start:\(t.title)", t.title, t.symbol))
            }
            return NowState(card: NowCard(kind: .running, title: r.title, subtitle: x.goalLine ?? x.tree.pathText(r.category),
                                          since: r.start, buttons: buttons, other: true))
        }
        if on(.questions), let q = x.question, let text = q.question {
            let buttons = q.answers.prefix(3).map { NowButton("answer:\(q.id):\($0)", $0) }
            return NowState(card: NowCard(kind: .question, title: text, subtitle: q.evidence.first, buttons: Array(buttons), other: true))
        }
        let untracked = { (since: Date) in
            NowCard(kind: .untracked, title: "What are you doing?", subtitle: "Untracked since \(hm.string(from: since))", since: since,
                    buttons: x.tiles.prefix(QuickStarts.topSize).map { NowButton("start:\($0.title)", $0.title, $0.symbol) }, other: true)
        }
        let assumed = currentAssumed(x)
        if on(.untracked), let since = untrackedSince(x), assumed == nil {
            return NowState(card: untracked(since))
        }
        if on(.assumed), let a = assumed {
            let card = NowCard(kind: .assumed, title: "Still at \(a.title) until \(hm.string(from: a.end))?", subtitle: x.tree.pathText(a.category),
                               buttons: [NowButton("yes:\(a.ref)", "Yes", "checkmark"), NowButton("no:\(a.ref)", "No", "xmark")])
            return NowState(card: card, then: on(.untracked) && !quiet(a.end, x) ? untracked(a.end) : nil, until: a.end)
        }
        if let b = upNext(x) {
            let title = b.itemId.flatMap { id in x.items.first { $0.id == id }?.title } ?? TaskCopy.plainTitle(b.title)
            let card = NowCard(kind: .upNext, title: "\(title) · \(minutesLabel(b.minutes)) at \(hm.string(from: b.start))",
                               subtitle: "Up next",
                               buttons: b.itemId.map { [NowButton("task:\($0.uuidString)", "Start", "play.fill")] } ?? [])
            return NowState(card: card, until: b.end)
        }
        return nil
    }

    /// The start of the untracked stretch that runs up to now (≥ `untrackedAfter` minutes, awake, nothing planned to cover it).
    public static func untrackedSince(_ x: NowInput) -> Date? {
        guard !quiet(x.now, x) else { return nil }
        let today = Days.dayInterval(x.now, x.calendar)
        let slices = TimeLog.past(x.entries, in: DateInterval(start: today.start, end: x.now), now: x.now, book: x.book, calendar: x.calendar)
        guard let last = slices.last, last.entry == nil, last.end >= x.now.addingTimeInterval(-60),
              last.minutes >= untrackedAfter else { return nil }
        let wake = x.plan.wakePlans.first { x.calendar.isDate($0.wake, inSameDayAs: x.now) }?.wake
        return max(last.start, wake ?? last.start)
    }

    /// An assumed occurrence of a series covering now (a class, School): "Still at School until 15:00?".
    static func currentAssumed(_ x: NowInput) -> DayEntry? {
        let window = DateInterval(start: x.now, duration: 60)
        return Days.expand(x.entries, in: window, now: x.now, book: x.book, calendar: x.calendar)
            .filter { $0.assumed && $0.entry.repeats != nil && $0.source != .plan && $0.start <= x.now && $0.end > x.now }
            .max { $0.end < $1.end }
    }

    static func upNext(_ x: NowInput) -> PlannedBlock? {
        let end = Days.dayInterval(x.now, x.calendar).end
        return x.plan.blocks.filter { $0.isStudy && $0.end > x.now && $0.start < end }.min { $0.start < $1.start }
    }

    /// Asleep, winding down, or before the planned wake: nothing asks.
    static func quiet(_ t: Date, _ x: NowInput) -> Bool {
        if let b = x.plan.blocks.first(where: { $0.start <= t && t < $0.end }), b.kind == .sleep || b.kind == .windDown { return true }
        if let w = x.plan.wakePlans.first(where: { x.calendar.isDate($0.wake, inSameDayAs: t) }), t < w.wake { return true }
        let h = x.calendar.component(.hour, from: t)
        return h < 6 || h >= 23
    }
}
