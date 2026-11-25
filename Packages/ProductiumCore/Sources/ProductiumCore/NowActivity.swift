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
    /// v1.5 D1: a task session's planned end; the timer counts down to it.
    public var ends: Date?
    /// v1.6 C2: a task's first step and due day ("First: outline · due Thu Nov 26").
    public var detail: String?

    public init(kind: NowKind, title: String, subtitle: String? = nil, since: Date? = nil, buttons: [NowButton] = [], other: Bool = false,
                ends: Date? = nil) {
        self.ends = ends
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
    /// v1.6 C1: a paused session, and a resumed session's countdown end.
    public var paused: PausedSession?
    public var resumedEnds: Date?

    public init(now: Date, calendar: Calendar, entries: [Entry], plan: Plan, items: [WorkItem], book: DayRuleBook = DayRuleBook(),
                tree: CategoryTree, question: Inference? = nil, tiles: [QuickStart] = [], prompts: PromptSettings = PromptSettings(),
                goalLine: String? = nil, paused: PausedSession? = nil, resumedEnds: Date? = nil) {
        self.paused = paused
        self.resumedEnds = resumedEnds
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
            if let task = r.taskId, x.items.contains(where: { $0.id == task && $0.isOpen }) {
                var s = session(r, task: task, x, hm)
                if let e = x.resumedEnds, e > x.now { s.card.ends = e }
                return s
            }
            var buttons = [NowButton("stop", "Stop", "stop.fill")]
            if let t = x.tiles.first(where: { $0.key != CategoryRules.key(r.title) }) {
                buttons.append(NowButton("start:\(t.title)", t.title, t.symbol))
            }
            return NowState(card: NowCard(kind: .running, title: r.title, subtitle: x.goalLine ?? x.tree.pathText(r.category),
                                          since: r.start, buttons: buttons, other: true))
        }
        if let p = x.paused {
            return NowState(card: NowCard(kind: .running, title: "Paused: \(p.title)", subtitle: "Paused at \(hm.string(from: p.pausedAt))",
                                          since: p.pausedAt, buttons: [NowButton("resume", "Resume", "play.fill"),
                                                                       NowButton("stop", "Stop", "stop.fill")]))
        }
        if on(.questions), let q = x.question, let text = q.question {
            let buttons = q.answers.prefix(3).map { NowButton("answer:\(q.id):\($0)", $0) }
            return NowState(card: NowCard(kind: .question, title: text, subtitle: q.evidence.first, buttons: Array(buttons), other: true))
        }
        let urgent = nextTask(x, besides: upNext(x)?.itemId)
        let untracked = { (since: Date) in
            NowCard(kind: .untracked, title: "What are you doing?", subtitle: "Untracked since \(hm.string(from: since))", since: since,
                    buttons: (urgent.map { [taskButton($0)] } ?? [])
                        + x.tiles.prefix(QuickStarts.topSize - (urgent == nil ? 0 : 1)).map { NowButton("start:\($0.title)", $0.title, $0.symbol) },
                    other: true)
        }
        let assumed = currentAssumed(x)
        if on(.untracked), let since = untrackedSince(x), assumed == nil {
            return NowState(card: untracked(since))
        }
        if on(.assumed), let a = assumed {
            // v1.6 E4: fixed time (classes, calendar events) counts as happened; it's shown, not asked about.
            let fixed = TimeLog.isFixed(a, tree: x.tree)
            let card = fixed
                ? NowCard(kind: .assumed, title: "\(a.title) until \(hm.string(from: a.end))", subtitle: x.tree.pathText(a.category),
                          buttons: urgent.map { [taskButton($0)] } ?? [])
                : NowCard(kind: .assumed, title: "Still at \(a.title) until \(hm.string(from: a.end))?", subtitle: x.tree.pathText(a.category),
                          buttons: [NowButton("yes:\(a.ref)", "Yes", "checkmark"), NowButton("no:\(a.ref)", "No", "xmark")])
            return NowState(card: card, then: on(.untracked) && !quiet(a.end, x) ? untracked(a.end) : nil, until: a.end)
        }
        // v1.6 C3: in the 30 minutes before leaving for school, the card counts down to it (instead of notifications).
        if let leave = x.plan.wakePlans.compactMap(\.leaveBy).filter({ $0 > x.now && $0.timeIntervalSince(x.now) <= 30 * 60 }).min() {
            let card = NowCard(kind: .upNext, title: "Leave at \(hm.string(from: leave))", subtitle: "Time to go to school",
                               buttons: x.tiles.first { $0.category == CategoryTree.travel || x.tree.isUnder($0.category, CategoryTree.travel) }
                                   .map { [NowButton("start:\($0.title)", $0.title, $0.symbol)] } ?? [], ends: leave)
            return NowState(card: card, until: leave)
        }
        if let b = upNext(x) {
            let title = b.itemId.flatMap { id in x.items.first { $0.id == id }?.title } ?? b.title
            // v1.6 C5: the planned session, or the next most urgent task instead.
            let instead = nextTask(x, besides: b.itemId).map { [taskButton($0)] } ?? []
            let card = NowCard(kind: .upNext, title: "\(title) · \(minutesLabel(b.minutes)) at \(hm.string(from: b.start))",
                               subtitle: "Up next",
                               buttons: (b.itemId.map { [NowButton("task:\($0.uuidString)", "Start", "play.fill")] } ?? []) + instead)
            return NowState(card: card, until: b.end)
        }
        return nil
    }

    /// The open task that needs work soonest (it has planned time ahead), other than `besides`.
    static func nextTask(_ x: NowInput, besides: UUID?) -> WorkItem? {
        let planned = Set(x.plan.blocks.filter { $0.isStudy && $0.end > x.now }.compactMap(\.itemId))
        return x.items.filter { $0.isOpen && $0.id != besides && planned.contains($0.id) }.min { $0.due < $1.due }
    }

    static func taskButton(_ t: WorkItem) -> NowButton {
        let short = t.title.count > 18 ? String(t.title.prefix(17)).trimmingCharacters(in: .whitespaces) + "…" : t.title
        return NowButton("task:\(t.id.uuidString)", short, "play")
    }

    /// v1.5 D1: a task session carries its countdown, what's next, and Done / +15 / Stop.
    static func session(_ r: Entry, task: UUID, _ x: NowInput, _ hm: DateFormatter) -> NowState {
        let block = x.plan.blocks.filter { $0.itemId == task && $0.isStudy && $0.end > x.now && $0.start <= x.now.addingTimeInterval(15 * 60) }
            .min { $0.start < $1.start }
        let next = x.plan.blocks.filter { $0.isStudy && $0.itemId != task && $0.start >= (block?.end ?? x.now) }.min { $0.start < $1.start }
        let nextTitle = next.map { n in (n.itemId.flatMap { id in x.items.first { $0.id == id }?.title } ?? n.title) + " at " + hm.string(from: n.start) }
        // v1.6 C2: how much of today's ask is done ("45 of 80 min").
        let today = Days.dayInterval(x.now, x.calendar)
        let done = x.entries.filter { $0.taskId == task && $0.source == .you && $0.start >= today.start && $0.start <= x.now && !Sessions.isUnworkedPlan($0) }
            .reduce(0) { $0 + Int((($1.end ?? x.now).timeIntervalSince($1.start)) / 60) }
        let ahead = x.plan.blocks.filter { $0.itemId == task && $0.isStudy && $0.end > x.now && $0.start < today.end }
            .reduce(0) { $0 + Int($1.end.timeIntervalSince(max($1.start, x.now)) / 60) }
        let progress = ahead > 0 ? "\(done) of \(done + ahead) min" : nil
        let subtitle = [progress, block.map { "until \(hm.string(from: $0.end))" }, nextTitle.map { "then \($0)" }].compactMap { $0 }
            .joined(separator: " · ")
        let buttons = [NowButton("pause", "Pause", "pause.fill"), NowButton("extend:\(task.uuidString):15", "+15", "plus"),
                       NowButton("done:\(task.uuidString)", "Done", "checkmark"), NowButton("stop", "Stop", "stop.fill")]
        var card = NowCard(kind: .running, title: r.title, subtitle: subtitle.isEmpty ? x.goalLine : subtitle,
                           since: r.start, buttons: buttons, ends: block?.end)
        if let item = x.items.first(where: { $0.id == task }) {
            let due = DateFormatter.local("EEE MMM d", x.calendar).string(from: item.due)
            card.detail = [item.firstStep.map { "First: \($0)" }, "due \(due)"].compactMap { $0 }.joined(separator: " · ")
        }
        return NowState(card: card)
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
