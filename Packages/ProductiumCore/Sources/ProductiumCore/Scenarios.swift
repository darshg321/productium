import Foundation

// Seeded states for testing dev builds (the `scenario` test command). Built around `now`, deterministic for a given
// `now`, every integration off so no permission prompt interrupts a run. A typical student: school Mon–Fri
// 8:30–15:00, soccer Mon / Wed, three open tasks (one a usually-dropped reading), a study goal.

public enum Scenario: String, CaseIterable, Sendable {
    /// Not onboarded: the onboarding screens.
    case fresh
    /// Today so far: the morning logged, a reading session running, school assumed.
    case today
    /// Three weeks of logged days, planned sessions (kept at 16:30, usually skipped at 19:00, done at 21:00 instead),
    /// moods, sleep, dropped readings: fills Review, the score, How You Work and the task warnings.
    case history
    /// 21:30 on a history day with nothing running, untracked gaps and assumed school to confirm (the end-of-day review).
    case evening
    /// Things that need you: a box change waiting for Approve, a question about your day, a task that can't fit.
    case alerts
    /// History plus a leaderboard group with four friends (cached; the server is unreachable on purpose).
    case leaderboard

    public var summary: String {
        switch self {
        case .fresh: return "not onboarded"
        case .today: return "morning logged, a reading running, school assumed"
        case .history: return "3 weeks of days, sessions, moods, sleep, dropped readings"
        case .evening: return "21:30, untracked gaps and assumed time to confirm"
        case .alerts: return "an approval, a question and a task that can't fit"
        case .leaderboard: return "history + a group of four friends"
        }
    }
}

public enum Scenarios {
    public static let essay = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
    public static let math = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    public static let reading = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    public static let you = "scenario-you-0001"

    public static func make(_ s: Scenario, now: Date, calendar cal: Calendar) -> AppState {
        switch s {
        case .fresh: return AppState()
        case .today: return today(now: now, cal: cal, history: false)
        case .history: return today(now: now, cal: cal, history: true)
        case .evening:
            let evening = cal.date(bySettingHour: 21, minute: 30, second: 0, of: now) ?? now
            var st = today(now: min(now, evening), cal: cal, history: true, running: false)
            // Today's school stays assumed (no marks) and two stretches stay untracked: the review has work to do.
            let day = DayKeys.key(now, cal)
            for i in st.entries.indices where st.entries[i].repeats != nil { st.entries[i].marks[day] = nil }
            return st
        case .alerts:
            var st = today(now: now, cal: cal, history: false)
            let schoolSeries = st.entries.first { $0.title == "School" }!
            st.approvals = [Approval(ops: [BoxOp(.entry, .remove, ref: EntryRef.entry(schoolSeries.id))],
                                     why: "Removes “School” every time it repeats", source: .box, at: now)]
            let walk = DateInterval(start: now.addingTimeInterval(-95 * 60), end: now.addingTimeInterval(-70 * 60))
            st.inference.pending = [Inference(id: "walk@scenario", kind: .walk, interval: walk,
                                              evidence: ["motion: walking 25 min"], confidence: 0.6,
                                              proposal: [BoxOp(.entry, .add, BoxFields(title: "Walk", start: stamp(walk.start, cal),
                                                                                       end: stamp(walk.end, cal), category: CategoryTree.travel))],
                                              question: "Were you out for a walk?", answers: ["Yes, a walk", "No"], band: .ask)]
            st.items.append(WorkItem(title: "Lab report", kind: .assignment, due: now.addingTimeInterval(90 * 60),
                                     estimateMinutes: 300, importance: 4, createdAt: now.addingTimeInterval(-86400)))
            return st
        case .leaderboard:
            var st = today(now: now, cal: cal, history: true)
            let g = BoardGroup(id: "scenariogroup0001", name: "Study crew", server: "https://leaderboard.invalid",
                               memberId: you, memberKey: "scenariokey00001", joinedAt: now.addingTimeInterval(-7 * 86400))
            st.leaderboard.displayName = "You"
            st.leaderboard.groups = [g]
            func friend(_ id: String, _ name: String, usual: Int?, base: Int, work: Int, scroll: Int, days: Int = 7) -> BoardMember {
                BoardMember(id: id, name: name, usual: usual, days: (0..<days).compactMap { i in
                    cal.date(byAdding: .day, value: -i, to: now).map { d in
                        BoardDay(d: DayKeys.key(d, cal), score: min(100, base + (i * 7) % 11 - 5), tracked: 70 + (i * 5) % 25,
                                 work: work + (i * 13) % 40, met: i % 3 == 0 ? 1 : 0, missed: i == 4 ? 1 : 0, scroll: scroll + (i * 11) % 30)
                    }
                })
            }
            st.leaderboard.boards[g.id] = Board(members: [
                friend("friend-ana-0001", "Ana", usual: 78, base: 82, work: 150, scroll: 20),
                friend("friend-ben-0001", "Ben", usual: 55, base: 64, work: 80, scroll: 70),
                friend("friend-cyd-0001", "Cyd", usual: nil, base: 70, work: 110, scroll: 45, days: 3),
                friend("friend-dev-0001", "Dev", usual: 60, base: 58, work: 60, scroll: 110),
            ])
            return st
        }
    }

    // MARK: Building blocks

    static func stamp(_ d: Date, _ cal: Calendar) -> String { QuickParse.stamp(d, cal) }

    /// A small deterministic generator (the same day gets the same numbers on every run).
    struct Dice {
        var x: UInt64
        init(_ seed: Int) { x = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next(_ n: Int) -> Int {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Int((x >> 33) % UInt64(max(1, n)))
        }
    }

    static func today(now: Date, cal: Calendar, history: Bool, running: Bool = true) -> AppState {
        var st = AppState()
        st.onboarded = true
        st.integrations = Integrations()
        let today = cal.startOfDay(for: now)
        func at(_ day: Date, _ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day }
        func day(_ back: Int) -> Date { cal.date(byAdding: .day, value: -back, to: today) ?? today }
        let start = day(35)
        let schoolDays: Set<Int> = [2, 3, 4, 5, 6]
        let school = Entry(title: "School", start: at(start, 8, 30), end: at(start, 15), category: CategoryTree.school,
                           repeats: .weekly(schoolDays), source: .you, createdAt: start)
        let soccer = Entry(title: "Soccer practice", start: at(start, 16), end: at(start, 17, 30), category: CategoryTree.extracurricular,
                           repeats: .weekly([2, 4]), source: .you, createdAt: start)
        let dinner = Entry(title: "Dinner", start: at(start, 18, 30), end: at(start, 19), category: CategoryTree.meals,
                           repeats: Repeat(.weekdays(Set(1...7))), source: .you, createdAt: start)
        st.entries = [school, soccer, dinner]
        st.items = [
            WorkItem(id: essay, title: "History essay", kind: .essay, subject: "History", due: at(day(-4), 23, 59),
                     estimateMinutes: 180, completedMinutes: 40, importance: 4, createdAt: day(6)),
            WorkItem(id: math, title: "Math unit test", kind: .test, subject: "Math", due: at(day(-2), 8, 30),
                     estimateMinutes: 120, importance: 5, topics: ["derivatives", "chain rule"], createdAt: day(5)),
            WorkItem(id: reading, title: "Read Gatsby ch. 7–8", kind: .reading, subject: "English", due: at(day(-1), 23, 59),
                     estimateMinutes: 40, importance: 3, createdAt: day(2)),
        ]
        st.goals = [Goal(title: "Study 5h a week", measure: .category(CategoryTree.studying), period: .week, target: 300,
                         origin: .you, createdAt: start)]
        st.prefs = Preferences()

        // Today: up and ready, a commute, then whatever's running.
        let wake = at(today, 7)
        var log: [Entry] = []
        func add(_ title: String, _ s: Date, _ e: Date?, _ c: CategoryID, task: UUID? = nil, source: EntrySource = .you) {
            guard s < now else { return }
            log.append(Entry(title: title, start: s, end: e.map { min($0, now) }, category: c, taskId: task, source: source,
                             createdAt: min(e ?? now, now)))
        }
        add("Sleep", at(day(1), 23, 10), wake, CategoryTree.sleep, source: .health)
        add("Getting ready", wake, at(today, 7, 40), CategoryTree.gettingReady)
        add("Bus to school", at(today, 7, 45), at(today, 8, 20), CategoryTree.travel)
        if running, now > at(today, 7, 50) {
            add("Read Gatsby ch. 7–8", now.addingTimeInterval(-25 * 60), nil, CategoryTree.studying, task: reading)
        }
        st.moods = [MoodEntry(at: at(today, 7, 35), mood: 3)].filter { $0.at < now }

        if history {
            var plans: [String: [PlannedBlock]] = [:]
            for back in 1...21 {
                let d = day(back)
                var dice = Dice(back * 31 + cal.component(.day, from: d))
                let weekday = cal.component(.weekday, from: d)
                let k = DayKeys.key(d, cal)
                let bed = at(day(back + 1), 22, 40 + dice.next(50))
                add("Sleep", bed, at(d, 6, 50 + dice.next(25)), CategoryTree.sleep, source: .health)
                add("Getting ready", at(d, 7, 5), at(d, 7, 35 + dice.next(10)), CategoryTree.gettingReady)
                if schoolDays.contains(weekday) {
                    add("Bus to school", at(d, 7, 45), at(d, 8, 20), CategoryTree.travel)
                    add("Bus home", at(d, 15, 5), at(d, 15, 40), CategoryTree.travel)
                }
                // The plan asked for two sessions; the 16:30 one mostly happens, the 19:00 one moves to 21:00 or doesn't.
                let first = back % 2 == 0 ? essay : math
                plans[k] = [PlannedBlock(kind: .work, start: at(d, 16, 30), end: at(d, 17, 30), title: "Study", itemId: first),
                            PlannedBlock(kind: .work, start: at(d, 19), end: at(d, 20), title: "Study", itemId: reading)]
                if dice.next(10) < 8 { add("Study", at(d, 16, 30 + dice.next(10)), at(d, 17, 30), CategoryTree.studying, task: first) }
                switch dice.next(10) {
                case 0..<2: add("Reading", at(d, 19, 5), at(d, 19, 55), CategoryTree.studying, task: reading)
                case 2..<6: add("Reading", at(d, 21, 10), at(d, 21, 55), CategoryTree.studying, task: reading)
                default: break
                }
                add("Scrolling", at(d, 20, 0), at(d, 20, 20 + dice.next(70)), CategoryTree.scrolling)
                add("Free time", at(d, 17, 45), at(d, 18, 25), CategoryTree.free)
                st.moods.append(MoodEntry(at: at(d, 20, 30), mood: 2 + dice.next(4)))
                st.health.append(HealthDay(day: d, steps: 4000 + dice.next(7000), sleepMinutes: 420 + dice.next(90)))
                st.dayPlans[k] = [first: 60, reading: 60]
                for i in st.entries.indices where st.entries[i].repeats != nil { st.entries[i].marks[k] = .confirmed }
            }
            st.planHistory = plans
            // Four dropped readings and one finished: the track record warns on new readings (H2).
            for i in 0..<5 {
                var t = WorkItem(title: "Reading \(i + 1)", kind: .reading, subject: "English", due: day(20 - i * 3),
                                 estimateMinutes: 40, createdAt: day(25 - i * 3))
                if i == 2 { t.isDone = true; t.doneAt = day(20 - i * 3); t.completedMinutes = 40 }
                st.taskHistory.add(TaskHistory.record(t, cleared: i != 2, entries: [], now: day(19 - i * 3), calendar: cal))
            }
        }
        st.entries += log
        for e in log where e.source == .you && e.taskId == nil { st.quickStarts.noteStart(e, at: e.start) }
        return st
    }
}
