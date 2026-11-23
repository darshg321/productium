import Foundation

// v1.3 Part M: stored data migrates from v1.2.2 (schema 4) on. `AppState.init(from:)` decodes leniently and then runs
// every step from the stored schema up, so state.json, restores and backups all go through here. Adding a stored
// change: bump `AppState.schema`, add a step below, and extend `MigrationTests` (the 1.2.2 fixture must lose nothing).

public enum Migrations {
    /// The oldest schema with real data. Anything older decodes as a fresh state (the v1.2 clean break).
    public static let oldest = 4

    struct Step {
        var from: Int
        var run: (inout AppState, Date) -> Void
    }

    static let steps: [Step] = [
        // 4 → 5 (v1.3): the activity grid's templates (A1), prompt severities from the v1.2 toggles (E). The backup
        // status (H1) and the tiles' origin / pin / aliases start at their defaults.
        Step(from: 4) { s, now in
            s.quickStarts.seedTemplates(at: now)
            s.prefs.prompts = PromptSettings.migrated(from: s.prefs.nudges, wakeAlarms: s.prefs.wakeAlarms)
        },
        // 5 → 6: gray seed categories get colours; Transition and Messaging are added. Feedback starts empty.
        Step(from: 5) { s, _ in
            s.categories.refreshSeeds()
        },
        // 6 → 7 (v1.5): entries can carry a focus rating (starts empty). Walking, Homework and Class buttons fold into
        // Commute and Studying; each class subject gets a study button.
        Step(from: 6) { s, now in
            s.quickStarts.retireTemplates()
            s.quickStarts.seedSubjects(tree: &s.categories, at: now)
        },
    ]

    /// The schema stored data was written with (0: unreadable), read without decoding the rest.
    public static func storedSchema(_ data: Data) -> Int {
        struct Head: Decodable { var schema: Int? }
        return (try? JSONDecoder().decode(Head.self, from: data))?.schema ?? 0
    }

    /// Runs the steps from `stored` up to the current schema. Returns the schemas it migrated through.
    @discardableResult
    public static func upgrade(_ s: inout AppState, from stored: Int, now: Date = Date()) -> [Int] {
        var done: [Int] = []
        var v = stored
        while v < AppState.schema, let step = steps.first(where: { $0.from == v }) {
            step.run(&s, now)
            done.append(v)
            v += 1
        }
        s.schema = AppState.schema
        return done
    }
}
