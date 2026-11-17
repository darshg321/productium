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

    static func input(now: Date, items: [WorkItem], prefs: Preferences = Preferences(), learned: LearnedModel = LearnedModel(),
                      moods: [MoodEntry] = [], health: [HealthDay] = [], routines: [Routine] = Routine.defaults,
                      horizon: Int = 14) -> PlannerInput {
        PlannerInput(now: now, calendar: cal, items: items, commitments: [school, soccer], preferences: prefs,
                     learned: learned, health: health, moods: moods, routines: routines, horizonDays: horizon)
    }
}

extension Plan {
    func study(for id: UUID) -> [PlannedBlock] { blocks.filter { $0.itemId == id && $0.isStudy } }
    func minutes(for id: UUID) -> Int { study(for: id).reduce(0) { $0 + $1.minutes } }
}
