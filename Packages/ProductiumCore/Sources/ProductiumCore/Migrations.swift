import Foundation

// v1.6 H: schema 8 is the first of the new line; older data (1.5 and before) is refused, not converted. Adding a
// stored change: bump `AppState.schema`, add a step below, and extend `MigrationTests` (the `state-1.6.json` fixture
// must lose nothing). state.json, restores and backups all go through `upgrade`.

public enum Migrations {
    /// The oldest schema that can be read. Anything older is from before 1.6.
    public static let oldest = 8

    struct Step {
        var from: Int
        var run: (inout AppState, Date) -> Void
    }

    static let steps: [Step] = []

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

/// Stored data from before 1.6 (schema < `Migrations.oldest`).
public struct BeforeBaseline: Error, CustomStringConvertible {
    public var schema: Int
    public var description: String { "This backup is from before 1.6. Restore it with 1.5, or start fresh." }
}
