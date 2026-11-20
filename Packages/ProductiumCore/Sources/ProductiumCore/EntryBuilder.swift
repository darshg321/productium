import Foundation

/// Turns signals into `sensor` entries (v1.2 B2). Ids come from `Entry.sensorId`, so a rebuild replaces rather than duplicates.
public enum EntryBuilder {
    public struct PhoneUse: Hashable, Sendable {
        public var start: Date
        public var end: Date
        public init(start: Date, end: Date) { self.start = start; self.end = end }
        var key: String { "phone|\(Int(start.timeIntervalSince1970))" }
    }

    /// Phone use during planned Sleep (N, B2): each use becomes a `sensor` Scrolling entry, which outranks the plan, and
    /// the planned Sleep starts after the last pickup of the first half of the night. Staying up shows as what you were
    /// doing, not as sleep. Pickups in the second half are wake-ups: they cut the night but don't push bedtime.
    /// Returns the ids of the sensor entries written.
    @discardableResult
    public static func phoneAfterBedtime(_ uses: [PhoneUse], entries: inout [Entry], now: Date) -> [UUID] {
        var written: [UUID] = []
        let sleepIdx = entries.indices.filter { entries[$0].source == .plan && entries[$0].alert?.edge == .end && entries[$0].category == CategoryTree.sleep }
        for i in sleepIdx {
            guard let end = entries[i].end else { continue }
            let night = entries[i]
            let mid = night.start.addingTimeInterval(end.timeIntervalSince(night.start) / 2)
            let mine = uses.filter { $0.end <= now && $0.end > $0.start && $0.end > night.start && $0.start < end }
                .sorted { $0.start < $1.start }
            for u in mine {
                let id = Entry.sensorId(u.key)
                let e = Entry(id: id, title: "Phone", start: max(u.start, night.start), end: min(u.end, end),
                              category: CategoryTree.scrolling, source: .sensor, createdAt: now)
                if let j = entries.firstIndex(where: { $0.id == id }) {
                    let keep = entries[j].marks
                    entries[j] = e
                    entries[j].marks = keep
                } else {
                    entries.append(e)
                }
                written.append(id)
            }
            if let last = mine.last(where: { $0.start < mid }), last.end > night.start, last.end < end {
                if let k = entries.firstIndex(where: { $0.id == night.id }) { entries[k].start = max(entries[k].start, last.end) }
            }
        }
        return written
    }
}
