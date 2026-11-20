import Foundation
@testable import ProductiumCore

enum Fx {
    static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!
        c.firstWeekday = 2
        return c
    }()

    static func mon(_ h: Int, _ m: Int = 0, plusDays d: Int = 0) -> Date {
        let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: h, minute: m))!
        return cal.date(byAdding: .day, value: d, to: base)!
    }

    static let school = Commitment(title: "School", kind: .school, weekdays: [2, 3, 4, 5, 6],
                                   start: TimeOfDay(8, 30), end: TimeOfDay(15, 0))
    static let soccer = Commitment(title: "Soccer practice", kind: .extracurricular, weekdays: [2, 4],
                                   start: TimeOfDay(16, 0), end: TimeOfDay(17, 30))

    /// The same week as `school` + `soccer`, as v1.2 entries (Mon–Fri school 8:30–15:00, Mon / Wed soccer 16:00–17:30).
    static var timetable: [Entry] { timetable(in: cal) }

    /// The same, with its clock times in another calendar (a phone in another time zone).
    static func timetable(in c: Calendar) -> [Entry] {
        func at(_ h: Int, _ m: Int = 0) -> Date { c.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: h, minute: m))! }
        return [Entry(title: "School", start: at(8, 30), end: at(15), category: CategoryTree.school,
                      repeats: .weekly([2, 3, 4, 5, 6]), source: .you),
                Entry(title: "Soccer practice", start: at(16), end: at(17, 30), category: CategoryTree.extracurricular,
                      repeats: .weekly([2, 4]), source: .you)]
    }

    /// Check-ins written into a log (the timetable by default), as the app writes them.
    static func log(_ checkIns: [CheckIn], over base: [Entry] = schoolEntries, now: Date? = nil) -> [Entry] {
        var entries = base, tree = CategoryTree()
        CheckIns.apply(checkIns, to: &entries, tree: &tree, now: now ?? checkIns.map(\.at).max() ?? mon(12), calendar: cal)
        return entries
    }

    static var schoolEntries: [Entry] { [timetable[0]] }

    /// Planner input driven by entries and rules (no commitments).
    static func input(now: Date, items: [WorkItem], entries: [Entry], rules: [Rule] = [], categories: CategoryTree? = nil,
                      prefs: Preferences = Preferences(), learned: LearnedModel = LearnedModel(),
                      moods: [MoodEntry] = [], health: [HealthDay] = [], routines: [Routine] = [],
                      horizon: Int = 7) -> PlannerInput {
        var i = PlannerInput(now: now, calendar: cal, items: items, preferences: prefs, learned: learned, health: health,
                             moods: moods, routines: routines, horizonDays: horizon, entries: entries, rules: rules)
        if let categories { i.categories = categories }
        return i
    }

    static func input(now: Date, items: [WorkItem], prefs: Preferences = Preferences(), learned: LearnedModel = LearnedModel(),
                      moods: [MoodEntry] = [], health: [HealthDay] = [], routines: [Routine] = Routine.defaults,
                      horizon: Int = 14) -> PlannerInput {
        PlannerInput(now: now, calendar: cal, items: items, preferences: prefs,
                     learned: learned, health: health, moods: moods, routines: routines, horizonDays: horizon,
                     entries: timetable)
    }
}

extension Plan {
    func study(for id: UUID) -> [PlannedBlock] { blocks.filter { $0.itemId == id && $0.isStudy } }
    func minutes(for id: UUID) -> Int { study(for: id).reduce(0) { $0 + $1.minutes } }
}
