import Foundation

public struct PlannerInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var items: [WorkItem]
    public var commitments: [Commitment]
    public var events: [FixedEvent]
    public var preferences: Preferences
    public var learned: LearnedModel
    public var health: [HealthDay]
    public var moods: [MoodEntry]
    public var locked: [PlannedBlock]
    public var routines: [Routine]
    public var exceptions: [DayException]
    public var horizonDays: Int
    public var policy: BehaviourPolicy
    public var beliefs: Beliefs

    public init(now: Date, calendar: Calendar = .current, items: [WorkItem], commitments: [Commitment] = [],
                events: [FixedEvent] = [], preferences: Preferences = Preferences(),
                learned: LearnedModel = LearnedModel(), health: [HealthDay] = [], moods: [MoodEntry] = [],
                locked: [PlannedBlock] = [], routines: [Routine] = Routine.defaults,
                exceptions: [DayException] = [], horizonDays: Int = 14, policy: BehaviourPolicy = BehaviourPolicy(),
                beliefs: Beliefs = Beliefs()) {
        self.policy = policy
        self.beliefs = beliefs
        self.now = now
        self.calendar = calendar
        self.items = items
        self.commitments = commitments
        self.events = events
        self.preferences = preferences
        self.learned = learned
        self.health = health
        self.moods = moods
        self.locked = locked
        self.routines = routines
        self.exceptions = exceptions
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
        plan.blocks = Palette.paint(plan.blocks, items: input.items, commitments: input.commitments, events: input.events,
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
        var studyUsed = 0
        var consumed = 0
        var borrowed = 0
        var itemCounts: [UUID: Int] = [:]
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

        init(input: PlannerInput) {
            self.input = input
            self.cal = input.calendar
            self.prefs = input.preferences
            self.chronotype = input.learned.inferredChronotype ?? Chronotype.nearest(shiftHours: input.beliefs.value("sleep.chronotype"))
            let t = input.now.timeIntervalSinceReferenceDate
            self.nowRounded = Date(timeIntervalSinceReferenceDate: (t / Planner.step).rounded(.up) * Planner.step)
        }

        func at(_ day: Date, _ tod: TimeOfDay) -> Date {
            cal.date(bySettingHour: tod.hour, minute: tod.minute, second: 0, of: day) ?? day
        }

        func isSchoolDay(_ day: Date) -> Bool {
            SchoolDay.isSchoolDay(day, prefs: prefs, commitments: input.commitments, exceptions: input.exceptions, calendar: cal)
        }

        func wakePlan(on day: Date) -> WakePlan {
            WakePlanner.plan(for: day, commitments: input.commitments, events: input.events,
                             routines: input.routines, prefs: prefs, calendar: cal, exceptions: input.exceptions)
        }

        func capacity(_ school: Bool) -> Int {
            input.beliefs.minutes(school ? "study.schoolDayCapacity" : "study.freeDayCapacity")
        }

        var breakMinutes: Int { input.beliefs.minutes("study.breakMinutes") }

        func routine(_ id: String) -> Routine? { input.routines.first { $0.id == id && $0.enabled } }

        mutating func buildDays() {
            let today = cal.startOfDay(for: input.now)
            computeTodayModifiers(today: today)
            let loadFactor = input.learned.loadFactor

            for i in 0..<input.horizonDays {
                guard let day = cal.date(byAdding: .day, value: i, to: today),
                      let tomorrow = cal.date(byAdding: .day, value: 1, to: day) else { continue }
                let school = isSchoolDay(day)
                let wp = wakePlan(on: day)
                if i > 0 || wp.wake > input.now { wakePlans.append(wp) }
                let wakeT = wp.wake
                let nextWake = wakePlan(on: tomorrow).wake
                let bedtime = nextWake.addingTimeInterval(-Double(prefs.sleepNeedMinutes) * 60)
                let workEnd = bedtime.addingTimeInterval(-Double(prefs.windDownMinutes) * 60)
                let ready = routine("get_ready")?.minutes ?? Planner.morningRoutineMinutes
                var windowStart = wakeT.addingTimeInterval(Double(ready) * 60)
                if i == 0 { windowStart = max(windowStart, nowRounded) }

                var busy: [Interval] = []
                var fixed: [PlannedBlock] = []
                if let r = routine("get_ready") {
                    fixed.append(PlannedBlock(id: stableId("r", r.id, day), kind: .routine, start: wakeT,
                                              end: wakeT.addingTimeInterval(Double(r.minutes) * 60), title: r.name))
                }
                let todays = Commitment.occurrences(input.commitments, on: day, exceptions: input.exceptions, calendar: cal)
                for r in input.routines where r.enabled && r.anchor != .afterWake {
                    let anchored = todays.filter { r.anchorKind == nil || $0.commitment.kind == r.anchorKind }
                    var s: Date?, e: Date?
                    if r.anchor == .beforeFirstCommitment, let f = anchored.min(by: { $0.start < $1.start }) {
                        e = f.start; s = f.start.addingTimeInterval(-Double(r.minutes) * 60)
                    } else if r.anchor == .afterLastCommitment, let l = anchored.max(by: { $0.end < $1.end }) {
                        s = l.end; e = l.end.addingTimeInterval(Double(r.minutes) * 60)
                    }
                    if let s, let e {
                        busy.append(Interval(start: s, end: e))
                        fixed.append(PlannedBlock(id: stableId("r", r.id, day), kind: .routine, start: s, end: e, title: r.name))
                    }
                }
                for o in todays {
                    let c = o.commitment, s = o.start, e = o.end
                    let buf = Double(c.bufferMinutes) * 60
                    busy.append(Interval(start: s.addingTimeInterval(-buf), end: e.addingTimeInterval(buf)))
                    fixed.append(PlannedBlock(id: stableId("c", c.id.uuidString, day), kind: .commitment,
                                              start: s, end: e, title: c.title, sourceId: c.id.uuidString))
                }
                for ev in input.events where ev.end > day && ev.start < tomorrow {
                    busy.append(Interval(start: ev.start, end: ev.end))
                    fixed.append(PlannedBlock(id: stableId("e", ev.id, day), kind: .event,
                                              start: max(ev.start, day), end: min(ev.end, tomorrow), title: ev.title,
                                              sourceId: ev.id))
                }
                for b in input.locked where b.end > day && b.start < tomorrow {
                    busy.append(Interval(start: b.start, end: b.end))
                    fixed.append(b)
                }
                let beliefs = input.beliefs
                if beliefs.minutes("routines.dinnerMinutes") > 0 {
                    let dinner = TimeOfDay(minutes: beliefs.minutes("routines.dinnerTime"))
                    let s = at(day, dinner), e = s.addingTimeInterval(Double(beliefs.minutes("routines.dinnerMinutes")) * 60)
                    if !busy.contains(where: { $0.start < e && s < $0.end }) {
                        busy.append(Interval(start: s, end: e))
                        fixed.append(PlannedBlock(id: stableId("m", "dinner", day), kind: .meal,
                                                  start: s, end: e, title: "Dinner"))
                    }
                }

                let window = windowStart < workEnd ? [Interval(start: windowStart, end: workEnd)] : []
                let free = Planner.subtract(window, busy).filter { $0.minutes >= 5 }
                let freeTotal = free.reduce(0) { $0 + $1.minutes }

                var cap = Double(capacity(school)) * loadFactor
                    * input.policy.capacityMultiplier
                if i == 0 { cap *= todayFactor }
                let floor = Int(Double(input.beliefs.minutes(school ? "study.schoolDayFreeTime" : "study.freeDayFreeTime"))
                    * input.policy.freeTimeMultiplier)

                days.append(Day(index: i, start: day, isSchoolDay: school, wake: wakeT, workEnd: workEnd,
                                bedtime: bedtime, nextWake: nextWake, free: free, fixed: fixed,
                                studyCap: Int(cap), freeFloor: floor, freeTotal: freeTotal))
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

        func remainingMinutes(_ item: WorkItem) -> Int {
            let corrected = Int((Double(item.estimateMinutes) * input.learned.estimateFactor(for: item.kind)).rounded())
            let lockedMinutes = input.locked.filter { $0.itemId == item.id }
                .reduce(0) { $0 + Int(max(0, $1.end.timeIntervalSince(input.now)) / 60) }
            let left = corrected - item.completedMinutes - lockedMinutes
            return left > 0 ? max(left, 10) : (item.isDone ? 0 : 15)
        }

        func dayIndex(of date: Date) -> Int {
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: input.now), to: cal.startOfDay(for: date)).day ?? 0
            return d
        }

        func buildDemands() -> [Demand] {
            let parents = Set(input.items.filter { !$0.isDone }.compactMap(\.parentId))
            var out: [Demand] = []
            for item in input.items where !item.isDone && !parents.contains(item.id) {
                let left = remainingMinutes(item)
                guard left > 0 else { continue }
                if item.due <= input.now { continue }
                if item.kind.isMemoryBased {
                    out += spacedSessions(item, minutes: left)
                } else {
                    out += pacedChunks(item, minutes: left)
                }
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
                    hint = "Retrieval practice: questions or flashcards from memory first, notes only to check."
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
                guard day.studyUsed + length <= cap,
                      day.freeTotal - day.consumed - length >= minFree else { continue }
                for (ii, iv) in day.free.enumerated() {
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
            if !borrowsSleep {
                let iv = day.free[ii]
                var pieces: [Interval] = []
                if start > iv.start { pieces.append(Interval(start: iv.start, end: start)) }
                var after = end
                if iv.end.timeIntervalSince(end) >= Double(breakMinutes + 5) * 60 {
                    let bEnd = end.addingTimeInterval(Double(breakMinutes) * 60)
                    blocks.append(PlannedBlock(id: Planner.stableUUID("k|\(Int(end.timeIntervalSince1970))"),
                                               kind: .breakTime, start: end, end: bEnd, title: "Break",
                                               hint: "Stand up, water, look out a window. Not your feed: scrolling doesn't let attention rest."))
                    day.consumed += breakMinutes
                    after = bEnd
                }
                if iv.end > after { pieces.append(Interval(start: after, end: iv.end)) }
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
                    !$0.isDone && $0.kind.isMemoryBased && $0.due >= nextDayStart && $0.due < nextDayEnd
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
            let itemsByIdForTitles = Dictionary(uniqueKeysWithValues: input.items.map { ($0.id, $0) })
            let grouped = Dictionary(grouping: blocks.indices.filter { blocks[$0].kind == .work }, by: { blocks[$0].itemId })
            for (id, idxs) in grouped {
                guard let id, let item = itemsByIdForTitles[id] else { continue }
                let ordered = idxs.sorted { blocks[$0].start < blocks[$1].start }
                for (k, i) in ordered.enumerated() {
                    blocks[i].title = ordered.count > 1 ? "\(item.title) · \(k + 1)/\(ordered.count)" : item.title
                }
            }
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

            let itemsById = Dictionary(uniqueKeysWithValues: input.items.map { ($0.id, $0) })
            for (id, mins) in shortfalls.sorted(by: { $0.value > $1.value }) where mins > 0 {
                guard let item = itemsById[id] else { continue }
                let advice = item.kind.isMemoryBased
                    ? "Focus on practice questions for the highest-weight topics."
                    : "Aim for a complete, solid version rather than a perfect one, or ask for an extension now, not the night before."
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
            return Plan(generatedAt: input.now, blocks: all, warnings: warnings, shortfalls: shortfalls,
                        sleepTradeoffMinutes: borrowed, loadFactor: input.learned.loadFactor * todayFactor,
                        wakePlans: wakePlans)
        }

        func stableId(_ prefix: String, _ key: String, _ day: Date) -> UUID {
            Planner.stableUUID("\(prefix)|\(key)|\(Int(day.timeIntervalSince1970))")
        }
    }

    static func subtract(_ base: [Interval], _ busy: [Interval]) -> [Interval] {
        var result = base
        for b in busy {
            var next: [Interval] = []
            for r in result {
                if b.end <= r.start || b.start >= r.end { next.append(r); continue }
                if b.start > r.start { next.append(Interval(start: r.start, end: b.start)) }
                if b.end < r.end { next.append(Interval(start: b.end, end: r.end)) }
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
