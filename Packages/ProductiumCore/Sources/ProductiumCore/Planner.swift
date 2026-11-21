import Foundation

public struct PlannerInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var items: [WorkItem]
    public var preferences: Preferences
    public var learned: LearnedModel
    public var health: [HealthDay]
    public var moods: [MoodEntry]
    public var locked: [PlannedBlock]
    public var routines: [Routine]
    public var horizonDays: Int
    public var policy: BehaviourPolicy
    public var beliefs: Beliefs
    public var dayRules: DayRuleBook
    /// v1.2 O3: fixed Entries (classes, events, pinned task sessions) the plan works around, and past entries with a
    /// `taskId` (finished sessions, for numbering). `plan` entries are ignored: the plan is what this makes.
    public var entries: [Entry]
    /// v1.2: rules whose `limits` change the planner on their days.
    public var rules: [Rule]
    public var categories: CategoryTree
    /// v1.2 D7: things done on most days at a similar time get their slot (`Habits.detect`).
    public var habits: [Habit] = []
    /// v1.2 H3: tasks like ones you usually drop (`TaskHistory.atRisk`): a starter session first, early, and weighted up.
    public var atRisk: Set<UUID> = []

    public init(now: Date, calendar: Calendar = .current, items: [WorkItem],
                preferences: Preferences = Preferences(),
                learned: LearnedModel = LearnedModel(), health: [HealthDay] = [], moods: [MoodEntry] = [],
                locked: [PlannedBlock] = [], routines: [Routine] = Routine.defaults,
                horizonDays: Int = 14, policy: BehaviourPolicy = BehaviourPolicy(),
                beliefs: Beliefs = Beliefs(), dayRules: DayRuleBook = DayRuleBook(),
                entries: [Entry] = [], rules: [Rule] = [], categories: CategoryTree = CategoryTree()) {
        self.entries = entries
        self.rules = rules
        self.categories = categories
        self.dayRules = dayRules
        self.policy = policy
        self.beliefs = beliefs
        self.now = now
        self.calendar = calendar
        self.items = items
        self.preferences = preferences
        self.learned = learned
        self.health = health
        self.moods = moods
        self.locked = locked
        self.routines = routines
        self.horizonDays = max(1, min(42, horizonDays))
    }
}

public enum Planner {
    static let step: TimeInterval = 5 * 60
    static let morningRoutineMinutes = 40
    static let minChunk = 15

    public static func plan(_ input: PlannerInput) -> Plan {
        var ctx = Context(input: input)
        ctx.buildDays()
        let demands = ctx.buildDemands()
        ctx.allocate(demands)
        var plan = ctx.finish()
        plan.blocks = Palette.paint(plan.blocks, items: input.items,
                                    colors: input.preferences.colors)
        return plan
    }

    public static func merge(previous: Plan, new: Plan, now: Date, calendar: Calendar) -> Plan {
        let keep = previous.blocks.filter { $0.end <= now && calendar.isDate($0.start, inSameDayAs: now) }
        let keptIds = Set(keep.map(\.id))
        var merged = new
        merged.blocks = (keep + new.blocks.filter { !keptIds.contains($0.id) && $0.end > now })
            .sorted { $0.start < $1.start }
        return merged
    }

    struct Interval: Hashable {
        var start: Date
        var end: Date
        /// Inside open time (a spare, lunch): only light tasks go here.
        var light = false
        var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
    }

    struct Day {
        let index: Int
        let start: Date
        let isSchoolDay: Bool
        let wake: Date
        var workEnd: Date
        let bedtime: Date
        let nextWake: Date
        var free: [Interval]
        var fixed: [PlannedBlock]
        let studyCap: Int
        let freeFloor: Int
        let freeTotal: Int
        var maxBlock = Int.max
        var studyUsed = 0
        var consumed = 0
        var borrowed = 0
        var itemCounts: [UUID: Int] = [:]
        var itemMinutes: [UUID: Int] = [:]
    }

    struct Demand {
        var item: WorkItem
        var minutes: Int
        var earliest: Date
        var latest: Date
        var preferredDay: Int?
        var isReview: Bool
        var title: String
        var hint: String
        var value: Double { Double(item.importance) * (1 + 0.15 * Double(item.difficulty)) }
    }

    enum Mode { case normal(span: Int), wide, crunch }

    struct Context {
        let input: PlannerInput
        let cal: Calendar
        let prefs: Preferences
        let chronotype: Chronotype
        let nowRounded: Date
        var days: [Day] = []
        var blocks: [PlannedBlock] = []
        var warnings: [PlanWarning] = []
        var shortfalls: [UUID: Int] = [:]
        var lastNightDebt = 0
        var todayFactor = 1.0
        var wakePlans: [WakePlan] = []
        let evaluator: DayRuleEvaluator
        /// Occurrences of the non-plan entries over the horizon, by day key.
        let entryDays: [DayKey: [DayEntry]]
        let timetableInEntries: Bool

        init(input: PlannerInput) {
            self.input = input
            let ev = DayRuleEvaluator(book: input.dayRules, calendar: input.calendar)
            self.evaluator = ev
            let today = input.calendar.startOfDay(for: input.now)
            let end = input.calendar.date(byAdding: .day, value: input.horizonDays + 1, to: today) ?? today
            let occ = Days.expand(input.entries.filter { $0.source != .plan }, in: DateInterval(start: today, end: end),
                                  now: input.now, book: input.dayRules, calendar: input.calendar, evaluator: ev)
            self.entryDays = Dictionary(grouping: occ, by: { DayKeys.key($0.start, input.calendar) })
            self.timetableInEntries = Days.hasTimetable(input.entries, tree: input.categories)
            self.cal = input.calendar
            self.prefs = input.preferences
            self.chronotype = input.learned.inferredChronotype ?? Chronotype.nearest(shiftHours: input.beliefs.value("sleep.chronotype"))
            let t = input.now.timeIntervalSinceReferenceDate
            self.nowRounded = Date(timeIntervalSinceReferenceDate: (t / Planner.step).rounded(.up) * Planner.step)
        }

        func at(_ day: Date, _ tod: TimeOfDay) -> Date {
            cal.date(bySettingHour: tod.hour, minute: tod.minute, second: 0, of: day) ?? day
        }

        func routines(on day: Date) -> [Routine] { input.routines }

        func entries(on day: Date) -> [DayEntry] { entryDays[DayKeys.key(day, cal)] ?? [] }

        /// What the plan works around that day: everything that isn't the plan's own or open time, including task
        /// sessions you put at a time.
        func fixedEntries(on day: Date) -> [DayEntry] {
            entries(on: day).filter { $0.busy && !$0.running && $0.end > input.now }
        }

        /// Open time (spares, lunch): light work only.
        func openEntries(on day: Date) -> [DayEntry] {
            entries(on: day).filter { $0.entry.open && $0.source != .plan && $0.end > input.now }
        }

        func limits(_ day: Date) -> PlannerLimits { Rules.limits(input.rules, on: day, evaluator) }

        func isSchoolDay(_ day: Date) -> Bool {
            if timetableInEntries {
                return entries(on: day).contains { input.categories.isUnder($0.category, CategoryTree.school) }
            }
            return prefs.schoolDays.contains(cal.component(.weekday, from: day))
        }

        func wakePlan(on day: Date) -> WakePlan {
            let fromEntries = fixedEntries(on: day).filter { $0.taskId == nil }.map {
                FixedEvent(id: $0.id, title: $0.title, start: $0.start, end: $0.end,
                           kind: input.categories.isUnder($0.category, CategoryTree.school) ? .school : .other)
            }
            var base = WakePlanner.plan(for: day, events: fromEntries,
                                        routines: routines(on: day), prefs: prefs, calendar: cal,
                                        isSchoolDay: timetableInEntries ? isSchoolDay(day) : nil)
            if let w = limits(day).wake {
                let wake = at(day, w)
                base = WakePlan(day: base.day, wake: wake, leaveBy: base.leaveBy.flatMap { $0 > wake ? $0 : nil },
                                firstCommitment: base.firstCommitment, reason: "A rule you set")
            }
            return base
        }

        func capacity(_ school: Bool) -> Int {
            input.beliefs.minutes(school ? "study.schoolDayCapacity" : "study.freeDayCapacity")
        }

        var breakMinutes: Int { input.beliefs.minutes("study.breakMinutes") }

        func routine(_ id: String, on day: Date) -> Routine? { routines(on: day).first { $0.id == id && $0.enabled } }

        mutating func buildDays() {
            let today = cal.startOfDay(for: input.now)
            computeTodayModifiers(today: today)
            let loadFactor = input.learned.loadFactor

            for i in 0..<input.horizonDays {
                guard let day = cal.date(byAdding: .day, value: i, to: today),
                      let tomorrow = cal.date(byAdding: .day, value: 1, to: day) else { continue }
                let school = isSchoolDay(day)
                let dayRoutines = routines(on: day)
                let wp = wakePlan(on: day)
                if i > 0 || wp.wake > input.now { wakePlans.append(wp) }
                let wakeT = wp.wake
                let nextWake = wakePlan(on: tomorrow).wake
                let bedtime = nextWake.addingTimeInterval(-Double(prefs.sleepNeedMinutes) * 60)
                let lim = limits(day)
                let windDown = lim.windDownMinutes ?? prefs.windDownMinutes
                let workEnd = bedtime.addingTimeInterval(-Double(windDown) * 60)
                let ready = routine("get_ready", on: day)?.minutes ?? Planner.morningRoutineMinutes
                var windowStart = wakeT.addingTimeInterval(Double(ready) * 60)
                if i == 0 { windowStart = max(windowStart, nowRounded) }

                var busy: [Interval] = []
                var fixed: [PlannedBlock] = []
                if let r = routine("get_ready", on: day) {
                    fixed.append(PlannedBlock(id: stableId("r", r.id, day), kind: .routine, start: wakeT,
                                              end: wakeT.addingTimeInterval(Double(r.minutes) * 60), title: r.name,
                                              sourceId: "routine:\(r.id)"))
                }
                let todays = fixedEntries(on: day).filter { $0.taskId == nil }.map {
                    (start: $0.start, end: $0.end,
                     kind: input.categories.isUnder($0.category, CategoryTree.school) ? CommitmentKind.school : .other)
                }
                for r in dayRoutines where r.enabled && r.anchor != .afterWake {
                    let anchored = todays.filter { r.anchorKind == nil || $0.kind == r.anchorKind }
                    var s: Date?, e: Date?
                    if r.anchor == .beforeFirstCommitment, let f = anchored.min(by: { $0.start < $1.start }) {
                        e = f.start; s = f.start.addingTimeInterval(-Double(r.minutes) * 60)
                    } else if r.anchor == .afterLastCommitment, let l = anchored.max(by: { $0.end < $1.end }) {
                        s = l.end; e = l.end.addingTimeInterval(Double(r.minutes) * 60)
                    }
                    if let s, let e {
                        busy.append(Interval(start: s, end: e))
                        fixed.append(PlannedBlock(id: stableId("r", r.id, day), kind: .routine, start: s, end: e, title: r.name,
                                                  sourceId: "routine:\(r.id)"))
                    }
                }
                for de in fixedEntries(on: day) {
                    busy.append(Interval(start: de.start, end: de.end))
                    fixed.append(PlannedBlock(id: Planner.stableUUID("entry|\(de.id)"), kind: de.taskId != nil ? .work : .commitment,
                                              start: de.start, end: de.end, title: de.title, itemId: de.taskId,
                                              hint: de.taskId != nil ? "You chose this time" : nil, sourceId: "entry:\(de.id)"))
                }
                for b in input.locked where b.end > day && b.start < tomorrow {
                    busy.append(Interval(start: b.start, end: b.end))
                    fixed.append(b)
                }
                let beliefs = input.beliefs
                let dinnerMinutes = beliefs.minutes("routines.dinnerMinutes")
                // "Dinner 7:30" said as an entry is your dinner: the learned one steps aside.
                let ownMeal = fixedEntries(on: day).contains { input.categories.isUnder($0.category, CategoryTree.meals) }
                if dinnerMinutes > 0 && !ownMeal {
                    let dinner = TimeOfDay(minutes: beliefs.minutes("routines.dinnerTime"))
                    let s = at(day, dinner), e = s.addingTimeInterval(Double(dinnerMinutes) * 60)
                    if !busy.contains(where: { $0.start < e && s < $0.end }) {
                        busy.append(Interval(start: s, end: e))
                        fixed.append(PlannedBlock(id: stableId("m", "dinner", day), kind: .meal,
                                                  start: s, end: e, title: "Dinner"))
                    }
                }

                // D7: habits keep their usual slot when it's free (planned and assumed, like any routine).
                for h in input.habits {
                    let s = at(day, h.start), e = s.addingTimeInterval(Double(h.minutes) * 60)
                    guard s >= wakeT, e <= bedtime, !busy.contains(where: { $0.start < e && s < $0.end }) else { continue }
                    busy.append(Interval(start: s, end: e))
                    fixed.append(PlannedBlock(id: stableId("h", h.key, day), kind: .routine, start: s, end: e, title: h.title,
                                              hint: Habits.note, sourceId: "habit:\(h.category)"))
                }

                let studyFrom = windowStart
                let studyTo = min(workEnd, lim.noStudyAfter.map { at(day, $0) } ?? workEnd)
                let window = studyFrom < studyTo ? [Interval(start: studyFrom, end: studyTo)] : []
                let opens = openEntries(on: day).map { Interval(start: $0.start, end: $0.end) }
                let free = Planner.markLight(Planner.subtract(window, busy), opens).filter { $0.minutes >= 5 }
                let freeTotal = free.reduce(0) { $0 + $1.minutes }

                var cap = Double(capacity(school)) * loadFactor
                    * input.policy.capacityMultiplier * (lim.capacityFactor ?? 1)
                if i == 0 { cap *= todayFactor }
                let floor = Int(Double(input.beliefs.minutes(school ? "study.schoolDayFreeTime" : "study.freeDayFreeTime"))
                    * input.policy.freeTimeMultiplier)

                var d = Day(index: i, start: day, isSchoolDay: school, wake: wakeT, workEnd: workEnd,
                            bedtime: bedtime, nextWake: nextWake, free: free, fixed: fixed,
                            studyCap: Int(cap), freeFloor: floor, freeTotal: freeTotal)
                d.maxBlock = lim.maxBlockMinutes ?? Int.max
                days.append(d)
            }
        }

        mutating func computeTodayModifiers(today: Date) {
            if let h = input.health.first(where: { cal.isDate($0.day, inSameDayAs: today) }),
               let slept = h.sleepMinutes {
                lastNightDebt = max(0, prefs.sleepNeedMinutes - slept)
                if lastNightDebt >= 120 {
                    todayFactor *= 0.8
                    warnings.append(PlanWarning(level: .info, message: "Short night (\(slept / 60)h \(slept % 60)m). Today's plan is lighter. No late studying, and bed on time beats catching up."))
                } else if lastNightDebt >= 60 {
                    todayFactor *= 0.9
                }
            }
            if let mood = input.moods.filter({ cal.isDate($0.at, inSameDayAs: today) }).max(by: { $0.at < $1.at }) {
                switch mood.mood {
                case ...2:
                    todayFactor *= 0.75
                    warnings.append(PlanWarning(level: .info, message: "Rough day, so today asks for less. Start with something small. A few minutes of progress usually lifts mood more than waiting until you feel like it."))
                case 3: todayFactor *= 0.95
                default: break
                }
                if let e = mood.energy, e <= 2 { todayFactor *= 0.9 }
            }
        }

        /// Minutes a situation has already placed for a task (they count toward it, so it isn't scheduled twice).
        func placedMinutes(_ item: UUID) -> Int {
            var total = 0
            for i in 0..<max(1, input.horizonDays) {
                guard let d = cal.date(byAdding: .day, value: i, to: cal.startOfDay(for: input.now)) else { continue }
            }
            for list in entryDays.values {
                for de in list where de.taskId == item && de.source == .you && !de.running && de.end > input.now {
                    total += Int(de.end.timeIntervalSince(max(de.start, input.now)) / 60)
                }
            }
            return total
        }

        func remainingMinutes(_ item: WorkItem) -> Int {
            let corrected = Int((Double(item.estimateMinutes) * input.learned.estimateFactor(for: item.kind)).rounded())
            let lockedMinutes = input.locked.filter { $0.itemId == item.id }
                .reduce(0) { $0 + Int(max(0, $1.end.timeIntervalSince(input.now)) / 60) } + placedMinutes(item.id)
            let left = corrected - item.completedMinutes - lockedMinutes
            return left > 0 ? max(left, 10) : (item.isOpen ? 15 : 0)
        }

        func dayIndex(of date: Date) -> Int {
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: input.now), to: cal.startOfDay(for: date)).day ?? 0
            return d
        }

        func buildDemands() -> [Demand] {
            let parents = Set(input.items.filter { $0.isOpen }.compactMap(\.parentId))
            var out: [Demand] = []
            for item in input.items where item.isOpen && !parents.contains(item.id) {
                let left = remainingMinutes(item)
                guard left > 0 else { continue }
                if item.due <= input.now { continue }
                var ds = item.kind.isMemoryBased ? spacedSessions(item, minutes: left) : pacedChunks(item, minutes: left)
                // "Not today" / "start Thursday" (A2): nothing before notBefore.
                if let nb = item.notBefore, nb > input.now {
                    guard nb < item.due else { continue }
                    for k in ds.indices {
                        ds[k].earliest = max(ds[k].earliest, nb)
                        if ds[k].latest <= ds[k].earliest { ds[k].latest = item.due }
                        if ds[k].preferredDay.map({ $0 < dayIndex(of: nb) }) == true { ds[k].preferredDay = dayIndex(of: nb) }
                    }
                }
                // H3: a kind you usually drop gets a short starter as soon as possible (the first step named), and
                // the rest of it weighs more when slots are handed out.
                if input.atRisk.contains(item.id), !item.kind.isMemoryBased, let first = ds.first {
                    var boosted = item
                    boosted.importance = min(5, item.importance + 1)
                    for k in ds.indices { ds[k].item = boosted }
                    if ds[0].minutes >= Planner.minChunk * 2 { ds[0].minutes -= Planner.minChunk } else { ds.removeFirst() }
                    let from = max(input.now, item.notBefore ?? input.now)
                    let endOfTomorrow = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: from)) ?? item.due
                    let starter = Demand(item: boosted, minutes: Planner.minChunk, earliest: from, latest: min(item.due, endOfTomorrow),
                                         preferredDay: dayIndex(of: from), isReview: false, title: item.title,
                                         hint: "Starter: " + (item.firstStep ?? "just open it and do the first small part"))
                    _ = first
                    ds.insert(starter, at: 0)
                }
                out += ds
            }
            return out
        }

        func spacedSessions(_ item: WorkItem, minutes: Int) -> [Demand] {
            let dueDay = dayIndex(of: item.due)
            let latest = item.due.addingTimeInterval(-30 * 60)
            let session = item.kind == .quiz ? 30 : 45
            var n = Int((Double(minutes) / Double(session)).rounded(.up))
            let offsets = [1, 2, 3, 5, 7, 10, 14, 21].filter { $0 <= dueDay }
            if offsets.isEmpty {
                return [Demand(item: item, minutes: min(minutes, 45), earliest: input.now, latest: latest,
                               preferredDay: 0, isReview: true, title: item.title,
                               hint: "Quick self-test: answer practice questions from memory, then check only the ones you missed.")]
            }
            n = max(1, n)
            let per = max(Planner.minChunk, Int((Double(minutes) / Double(n)).rounded(.up)))
            var picked: [Int] = []
            if n >= offsets.count {
                picked = offsets
            } else {
                for k in 0..<n {
                    let idx = n == 1 ? 0 : Int((Double(k) * Double(offsets.count - 1) / Double(n - 1)).rounded())
                    picked.append(offsets[idx])
                }
            }
            picked = Array(Set(picked)).sorted(by: >)
            let sessionsMinutes = distribute(minutes, over: picked.count, maxEach: max(per, 75))
            var out: [Demand] = []
            for (k, off) in picked.enumerated() {
                let target = dueDay - off
                guard target < input.horizonDays else { continue }
                guard let dayDate = cal.date(byAdding: .day, value: target, to: cal.startOfDay(for: input.now)) else { continue }
                let windowStart = cal.date(byAdding: .day, value: -1, to: dayDate) ?? dayDate
                let windowEnd = min(latest, cal.date(byAdding: .day, value: 2, to: dayDate) ?? latest)
                let first = k == 0, last = k == picked.count - 1
                let hint: String
                if first && picked.count > 1 {
                    hint = "Organise the material, then close your notes and write down everything you remember. The gaps tell you what to study."
                } else if last {
                    hint = "Do a timed practice test, mark it, and fix only what you missed. Then sleep: it's when today's studying gets stored."
                } else {
                    hint = "Retrieval practice: answer questions from memory first, notes only to check."
                }
                for chunk in split(sessionsMinutes[k], focus: min(50, input.policy.maxBlockMinutes)) {
                    out.append(Demand(item: item, minutes: chunk, earliest: max(input.now, windowStart),
                                      latest: max(windowEnd, input.now.addingTimeInterval(60)), preferredDay: target,
                                      isReview: true, title: item.title, hint: hint))
                }
            }
            return out
        }

        func pacedChunks(_ item: WorkItem, minutes: Int) -> [Demand] {
            let focus = Int(input.learned.focusMinutes.rounded())
            let chunks = split(minutes, focus: max(20, min(60, input.policy.maxBlockMinutes, focus)))
            let bufferDays = minutes > 240 ? 2 : (minutes > 90 ? 1 : 0)
            var target = cal.date(byAdding: .day, value: -bufferDays, to: item.due) ?? item.due
            if target.timeIntervalSince(input.now) < Double(minutes) * 60 * 3 { target = item.due }
            let span = max(0, dayIndex(of: target))
            let hint: String
            switch item.kind {
            case .essay, .application:
                hint = "Write first, edit later. Don't polish this draft."
            case .project:
                hint = "Pick one concrete deliverable for this block before you start."
            default:
                hint = "Phone in another room. Start with the easiest part to get going."
            }
            return chunks.enumerated().compactMap { i, len in
                let releaseDay = span >= 2 && chunks.count >= 2 ? (i * span) / chunks.count : 0
                guard releaseDay < input.horizonDays else { return nil }
                let earliest = releaseDay == 0 ? input.now
                    : (cal.date(byAdding: .day, value: releaseDay, to: cal.startOfDay(for: input.now)) ?? input.now)
                let title = chunks.count > 1 ? "\(item.title) · \(i + 1)/\(chunks.count)" : item.title
                return Demand(item: item, minutes: len, earliest: earliest, latest: target,
                              preferredDay: nil, isReview: false, title: title, hint: hint)
            }
        }

        func split(_ minutes: Int, focus: Int) -> [Int] {
            guard minutes > 0 else { return [] }
            let longest = max(Planner.minChunk, min(focus + 15, input.policy.maxBlockMinutes))
            let n = max(1, Int((Double(minutes) / Double(longest)).rounded(.up)))
            let base = minutes / n
            return (0..<n).map { i in
                let m = base + (i < minutes - base * n ? 1 : 0)
                return max(Planner.minChunk, Int((Double(m) / 5).rounded(.up)) * 5)
            }
        }

        func distribute(_ minutes: Int, over n: Int, maxEach: Int) -> [Int] {
            guard n > 0 else { return [] }
            let base = minutes / n
            var arr = Array(repeating: base, count: n)
            arr[n - 1] += minutes - base * n
            return arr
        }

        mutating func allocate(_ demandsIn: [Demand]) {
            let demands = demandsIn.sorted {
                if $0.latest != $1.latest { return $0.latest < $1.latest }
                return $0.value > $1.value
            }
            var unplaced: [Demand] = []
            for d in demands {
                if let leftover = placeWithFallbacks(d, modes: [.normal(span: 3), .wide]) {
                    unplaced.append(leftover)
                }
            }
            var stillUnplaced: [Demand] = []
            for d in unplaced.sorted(by: { $0.value > $1.value }) {
                if let leftover = placeWithFallbacks(d, modes: [.crunch]) { stillUnplaced.append(leftover) }
            }
            var afterSleep: [Demand] = []
            for d in stillUnplaced {
                if let leftover = borrowSleep(for: d) { afterSleep.append(leftover) }
            }
            let horizonEnd = days.last.flatMap { cal.date(byAdding: .day, value: 1, to: $0.start) } ?? input.now
            for d in afterSleep {
                if d.latest >= horizonEnd { continue }
                if let leftover = displace(for: d) {
                    shortfalls[leftover.item.id, default: 0] += leftover.minutes
                }
            }
        }

        mutating func placeWithFallbacks(_ d: Demand, modes: [Mode]) -> Demand? {
            var demand = d
            if demand.minutes < Planner.minChunk { demand.minutes = Planner.minChunk }
            for mode in modes {
                while demand.minutes > 0 {
                    if demand.minutes < Planner.minChunk { demand.minutes = Planner.minChunk }
                    if place(&demand, length: demand.minutes, mode: mode) { return nil }
                    let half = max(Planner.minChunk, demand.minutes / 2)
                    if half < demand.minutes, place(&demand, length: half, mode: mode) { continue }
                    break
                }
            }
            return demand.minutes > 0 ? demand : nil
        }

        mutating func place(_ d: inout Demand, length: Int, mode: Mode) -> Bool {
            let earliestDay = max(0, dayIndex(of: d.earliest))
            let latestDay = min(days.count - 1, dayIndex(of: d.latest))
            guard earliestDay <= latestDay else { return false }
            var lastDay = latestDay
            if case .normal(let span) = mode { lastDay = min(latestDay, earliestDay + span) }

            var best: (score: Double, day: Int, interval: Int, start: Date)?
            let len = Double(length) * 60
            for di in earliestDay...lastDay {
                let day = days[di]
                let (cap, minFree): (Int, Int)
                switch mode {
                case .crunch: (cap, minFree) = (Int(Double(day.studyCap) * 1.35) + 30, min(30, day.freeFloor))
                default: (cap, minFree) = (day.studyCap, day.freeFloor)
                }
                if let maxDay = d.item.maxMinutesPerDay, (day.itemMinutes[d.item.id] ?? 0) + length > maxDay { continue }
                guard day.studyUsed + length <= cap, length <= day.maxBlock,
                      day.freeTotal - day.consumed - length >= minFree else { continue }
                for (ii, iv) in day.free.enumerated() {
                    if iv.light && !d.item.isLight { continue }
                    var s = max(iv.start, d.earliest)
                    let hardEnd = min(iv.end, d.latest)
                    var tries = 0
                    while s.addingTimeInterval(len) <= hardEnd && tries < 24 {
                        let sc = score(start: s, length: length, day: day, demand: d, earliestDay: earliestDay,
                                       atIntervalStart: s == iv.start, intervalEnd: iv.end)
                        if best == nil || sc > best!.score { best = (sc, di, ii, s) }
                        let t = s.timeIntervalSinceReferenceDate
                        s = Date(timeIntervalSinceReferenceDate: (floor(t / 900) + 1) * 900)
                        tries += 1
                    }
                }
            }
            guard let b = best else { return false }
            commit(demand: d, length: length, dayIndex: b.day, intervalIndex: b.interval, start: b.start,
                   usesFreeTime: { if case .crunch = mode { return true } else { return false } }(), borrowsSleep: false)
            d.minutes -= length
            return true
        }

        func score(start: Date, length: Int, day: Day, demand: Demand, earliestDay: Int,
                   atIntervalStart: Bool, intervalEnd: Date) -> Double {
            let hour = cal.component(.hour, from: start.addingTimeInterval(Double(length) * 30))
            let alert = EnergyModel.alertness(hour: hour, chronotype: chronotype, learned: input.learned)
            let difficulty = Double(demand.item.difficulty) / 3.0
            var s = alert * (0.4 + difficulty)
            if let p = demand.preferredDay {
                s -= Double(abs(day.index - p)) * 0.7
            } else {
                s -= Double(day.index - earliestDay) * 0.12
            }
            s -= Double(day.itemCounts[demand.item.id] ?? 0) * 0.45
            s -= Double(day.studyUsed) / Double(max(1, day.studyCap)) * 0.35
            if day.workEnd.timeIntervalSince(start.addingTimeInterval(Double(length) * 60)) < 45 * 60 { s -= 0.15 }
            if atIntervalStart { s += 0.05 }
            if intervalEnd.timeIntervalSince(start) / 60 - Double(length) < 10 { s += 0.03 }
            return s
        }

        mutating func commit(demand d: Demand, length: Int, dayIndex di: Int, intervalIndex ii: Int,
                             start: Date, usesFreeTime: Bool, borrowsSleep: Bool) {
            let end = start.addingTimeInterval(Double(length) * 60)
            let block = PlannedBlock(id: Planner.stableUUID("b|\(d.item.id)|\(Int(start.timeIntervalSince1970))"),
                                     kind: d.isReview ? .review : .work, start: start, end: end, title: d.title,
                                     itemId: d.item.id, hint: d.hint, borrowsSleep: borrowsSleep, usesFreeTime: usesFreeTime)
            blocks.append(block)
            var day = days[di]
            day.studyUsed += length
            day.consumed += length
            day.itemCounts[d.item.id, default: 0] += 1
            day.itemMinutes[d.item.id, default: 0] += length
            if !borrowsSleep {
                let iv = day.free[ii]
                var pieces: [Interval] = []
                if start > iv.start { pieces.append(Interval(start: iv.start, end: start, light: iv.light)) }
                var after = end
                if iv.end.timeIntervalSince(end) >= Double(breakMinutes + 5) * 60 {
                    let bEnd = end.addingTimeInterval(Double(breakMinutes) * 60)
                    blocks.append(PlannedBlock(id: Planner.stableUUID("k|\(Int(end.timeIntervalSince1970))"),
                                               kind: .breakTime, start: end, end: bEnd, title: "Break",
                                               hint: "Stand up, water, look out a window. Not your feed: scrolling doesn't let attention rest."))
                    day.consumed += breakMinutes
                    after = bEnd
                }
                if iv.end > after { pieces.append(Interval(start: after, end: iv.end, light: iv.light)) }
                day.free.replaceSubrange(ii...ii, with: pieces.filter { $0.minutes >= 5 })
            }
            days[di] = day
        }

        mutating func borrowSleep(for d: Demand) -> Demand? {
            var demand = d
            let latestDay = min(days.count - 1, dayIndex(of: d.latest))
            let earliestDay = max(0, dayIndex(of: d.earliest))
            guard earliestDay <= latestDay else { return demand }
            for di in stride(from: latestDay, through: earliestDay, by: -1) where demand.minutes > 0 {
                let day = days[di]
                let borrowedNights = Set(days.filter { $0.borrowed > 0 }.map(\.index))
                let nextDayStart = cal.date(byAdding: .day, value: 1, to: day.start) ?? day.start
                let nextDayEnd = cal.date(byAdding: .day, value: 2, to: day.start) ?? day.start
                let memoryNext = input.items.contains {
                    $0.isOpen && $0.kind.isMemoryBased && $0.due >= nextDayStart && $0.due < nextDayEnd
                }
                let night = SleepPolicy.NightContext(dayIndex: di, workEnd: day.workEnd, alreadyBorrowed: day.borrowed,
                                                     memoryDueNextDay: memoryNext, borrowedNightIndices: borrowedNights,
                                                     lastNightDebtMinutes: lastNightDebt)
                let allow = SleepPolicy.allowance(item: d.item, now: input.now, night: night, prefs: prefs)
                let take = min(allow, demand.minutes)
                guard take >= Planner.minChunk else { continue }
                let start = day.workEnd
                guard start.addingTimeInterval(Double(take) * 60) <= d.item.due else { continue }
                var copy = demand
                copy.hint = SleepPolicy.recoveryAdvice(minutes: take)
                commit(demand: copy, length: take, dayIndex: di, intervalIndex: 0, start: start,
                       usesFreeTime: false, borrowsSleep: true)
                days[di].borrowed += take
                days[di].workEnd = start.addingTimeInterval(Double(take) * 60)
                demand.minutes -= take
            }
            return demand.minutes > 0 ? demand : nil
        }

        mutating func displace(for d: Demand) -> Demand? {
            var demand = d
            let itemsById = Dictionary(uniqueKeysWithValues: input.items.map { ($0.id, $0) })
            while demand.minutes >= Planner.minChunk {
                guard let idx = blocks.indices.filter({ i in
                    let b = blocks[i]
                    guard b.isStudy, let id = b.itemId, id != d.item.id, let other = itemsById[id] else { return false }
                    return other.importance <= d.item.importance - 2 && b.start >= d.earliest && b.end <= d.latest
                        && b.minutes >= Planner.minChunk
                }).min(by: { (itemsById[blocks[$0].itemId!]?.importance ?? 0) < (itemsById[blocks[$1].itemId!]?.importance ?? 0) })
                else { break }
                let old = blocks[idx]
                let take = min(old.minutes, demand.minutes)
                shortfalls[old.itemId!, default: 0] += take
                blocks[idx].itemId = d.item.id
                blocks[idx].title = d.title
                blocks[idx].hint = d.hint
                blocks[idx].kind = d.isReview ? .review : .work
                if take < old.minutes {
                    blocks[idx].end = old.start.addingTimeInterval(Double(take) * 60)
                    var rest = old
                    rest.id = Planner.stableUUID("r|\(old.id)")
                    rest.start = blocks[idx].end
                    blocks.append(rest)
                }
                demand.minutes -= take
                if let low = itemsById[old.itemId!] {
                    warnings.append(PlanWarning(level: .caution,
                        message: "Moved \(take) min from “\(low.title)” to “\(d.item.title)” because it matters more. Do a quick, good-enough version of \(low.title).",
                        itemId: low.id))
                }
            }
            return demand.minutes > 0 ? demand : nil
        }

        mutating func finish() -> Plan {
            var all = blocks
            for day in days {
                all += day.fixed
                let windStart = day.workEnd
                let sleepStart = day.bedtime.addingTimeInterval(Double(day.borrowed) * 60)
                if sleepStart > windStart {
                    all.append(PlannedBlock(id: stableId("w", "wind", day.start), kind: .windDown, start: windStart, end: sleepStart,
                                            title: "Wind down", hint: "Screens off, lights low. Phone stays out of the bedroom."))
                }
                all.append(PlannedBlock(id: stableId("s", "sleep", day.start), kind: .sleep, start: sleepStart, end: day.nextWake,
                                        title: "Sleep", hint: "\(minutesLabel(Int(day.nextWake.timeIntervalSince(sleepStart) / 60))) of sleep"))
                for iv in day.free {
                    if iv.minutes >= 25 {
                        all.append(PlannedBlock(kind: .free, start: iv.start, end: iv.end, title: "Free"))
                    } else if iv.minutes >= 5 {
                        all.append(PlannedBlock(kind: .gap, start: iv.start, end: iv.end, title: "Short window",
                                                hint: "A few minutes. Quick review or a short read instead of scrolling."))
                    }
                }
            }
            all = all.filter { $0.end > input.now }.sorted { $0.start < $1.start }
            Planner.number(&all, items: input.items, entries: input.entries, now: input.now)

            let itemsById = Dictionary(uniqueKeysWithValues: input.items.map { ($0.id, $0) })
            for (id, mins) in shortfalls.sorted(by: { $0.value > $1.value }) where mins > 0 {
                guard let item = itemsById[id] else { continue }
                let advice = item.kind.isMemoryBased
                    ? "Focus on practice questions for the highest-weight topics."
                    : "Aim for a complete, solid version rather than a perfect one, or ask for an extension now, not the night before."
                let mins = Planner.shownMinutes(mins, for: item, learned: input.learned)
                warnings.append(PlanWarning(level: item.importance >= 4 ? .critical : .caution,
                                            message: "≈\(mins) min of “\(item.title)” doesn't fit before it's due. \(advice)", itemId: id))
            }
            let borrowed = days.reduce(0) { $0 + $1.borrowed }
            if borrowed > 0 {
                warnings.append(PlanWarning(level: .caution, message: "This plan borrows \(borrowed) min of sleep. It's limited to deadline-critical writing, never study for a test."))
            }
            for day in days where day.studyUsed > Int(Double(capacity(day.isSchoolDay)) * 1.1) {
                let f = DateFormatter.local("EEEE", cal)
                warnings.append(PlanWarning(level: .caution, message: "\(f.string(from: day.start)) is heavy (\(minutesLabel(day.studyUsed)) of work). Starting earlier this week makes it lighter."))
            }
            var mutes: [NudgeMute] = []
            for day in days {
                let lim = limits(day.start)
                if lim.muteAll == true { mutes.append(NudgeMute(day: day.start, kind: nil)) }
                let kinds = lim.mute ?? []
                for k in kinds.sorted(by: { $0.rawValue < $1.rawValue }) { mutes.append(NudgeMute(day: day.start, kind: k)) }
            }
            return Plan(generatedAt: input.now, blocks: all, warnings: warnings, shortfalls: shortfalls,
                        sleepTradeoffMinutes: borrowed, loadFactor: input.learned.loadFactor * todayFactor,
                        wakePlans: wakePlans, mutes: input.rules.isEmpty ? nil : mutes)
        }

        func stableId(_ prefix: String, _ key: String, _ day: Date) -> UUID {
            Planner.stableUUID("\(prefix)|\(key)|\(Int(day.timeIntervalSince1970))")
        }
    }

    /// v1.2 A2: "Reading · 2 of 5". Every session of a task, planned or pinned, numbered in time order after the
    /// sessions already done (past entries with its `taskId`), so the earliest remaining one always has the lowest
    /// remaining number and moving one never reorders the rest.
    static func number(_ blocks: inout [PlannedBlock], items: [WorkItem], entries: [Entry], now: Date) {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let done = Dictionary(grouping: entries.filter { $0.taskId != nil && $0.source != .plan && $0.repeats == nil && ($0.end ?? now) <= now },
                              by: { $0.taskId! }).mapValues(\.count)
        let grouped = Dictionary(grouping: blocks.indices.filter { blocks[$0].isStudy && blocks[$0].itemId != nil },
                                 by: { blocks[$0].itemId! })
        for (id, idxs) in grouped {
            guard let item = byId[id] else { continue }
            let ordered = idxs.sorted { (blocks[$0].start, blocks[$0].id.uuidString) < (blocks[$1].start, blocks[$1].id.uuidString) }
            let before = done[id] ?? 0
            let total = before + ordered.count
            for (k, i) in ordered.enumerated() {
                blocks[i].title = total > 1 ? "\(item.title) · \(before + k + 1) of \(total)" : item.title
            }
        }
    }

    /// The planner works in corrected, chunk-rounded minutes; the warning speaks in yours.
    static func shownMinutes(_ planned: Int, for item: WorkItem, learned: LearnedModel) -> Int {
        let factor = max(0.5, learned.estimateFactor(for: item.kind))
        let left = max(5, item.estimateMinutes - item.completedMinutes)
        return max(5, min(left, Int((Double(planned) / factor).rounded())))
    }

    /// Fixed blocks with the freed ranges taken out (a block split in two keeps its id on the first part).
    static func cut(_ blocks: [PlannedBlock], _ frees: [Interval]) -> [PlannedBlock] {
        blocks.flatMap { b -> [PlannedBlock] in
            let parts = subtract([Interval(start: b.start, end: b.end)], frees).filter { $0.minutes >= 1 }
            return parts.enumerated().map { i, iv in
                var p = b
                if i > 0 { p.id = stableUUID("cut|\(b.id)|\(i)") }
                p.start = iv.start
                p.end = iv.end
                return p
            }
        }
    }

    /// Splits free intervals at open time and marks the parts inside it light.
    static func markLight(_ free: [Interval], _ opens: [Interval]) -> [Interval] {
        guard !opens.isEmpty else { return free }
        return free.flatMap { f -> [Interval] in
            var cuts = Set([f.start, f.end])
            for o in opens where o.start < f.end && o.end > f.start { cuts.insert(max(f.start, o.start)); cuts.insert(min(f.end, o.end)) }
            let pts = cuts.sorted()
            return zip(pts, pts.dropFirst()).map { a, b in
                Interval(start: a, end: b, light: f.light || opens.contains { $0.start <= a && $0.end >= b })
            }
        }
    }

    static func subtract(_ base: [Interval], _ busy: [Interval]) -> [Interval] {
        var result = base
        for b in busy {
            var next: [Interval] = []
            for r in result {
                if b.end <= r.start || b.start >= r.end { next.append(r); continue }
                if b.start > r.start { next.append(Interval(start: r.start, end: b.start, light: r.light)) }
                if b.end < r.end { next.append(Interval(start: b.end, end: r.end, light: r.light)) }
            }
            result = next
        }
        return result.sorted { $0.start < $1.start }
    }

    public static func stableUUID(_ s: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for b in s.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100000001b3
            h2 = (h2 ^ UInt64(b)) &* 0x100000001b3 ^ (h2 >> 7)
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((h1 >> (8 * UInt64(i))) & 0xff); bytes[8 + i] = UInt8((h2 >> (8 * UInt64(i))) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public func minutesLabel(_ m: Int) -> String {
    if m < 60 { return "\(m)m" }
    return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
}
