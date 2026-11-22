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

    /// A5 / B2: nights and naps as Sleep entries. Measured by Health = `health` (outranks the planned Sleep and
    /// anything assumed); estimated from the phone (stillness, first pickup, the charger) = `sensor`. Nights from your
    /// own check-ins are already entries. Ids come from the morning's day, so a re-read replaces the night in place and
    /// keeps your marks. Returns the ids written.
    @discardableResult
    public static func sleep(_ days: [HealthDay], entries: inout [Entry], now: Date, calendar cal: Calendar) -> [UUID] {
        var written: [UUID] = []
        func put(_ e: Entry) {
            if let j = entries.firstIndex(where: { $0.id == e.id }) {
                var x = e
                x.marks = entries[j].marks
                if entries[j] != x { entries[j] = x }
            } else {
                entries.append(e)
            }
            written.append(e.id)
        }
        for d in days {
            guard let bed = d.bedtime, let wake = d.wake, wake > bed, wake <= now.addingTimeInterval(3600),
                  let src = d.sleepSource ?? (d.sleepMinutes != nil ? .health : nil), src == .health || src == .motion else { continue }
            let key = DayKeys.key(d.day, cal)
            put(Entry(id: Entry.sensorId("sleep|\(key)"), title: "Sleep", start: bed, end: min(wake, now), category: CategoryTree.sleep,
                      note: d.sleepDevice ?? (src == .motion ? "estimated from the phone" : nil),
                      source: src == .health ? .health : .sensor, createdAt: wake))
            for n in d.naps ?? [] where n.end <= now {
                put(Entry(id: Entry.sensorId("nap|\(Int(n.start.timeIntervalSince1970))"), title: "Nap", start: n.start, end: n.end,
                          category: CategoryTree.sleep, note: d.sleepDevice, source: .health, createdAt: n.end))
            }
        }
        return written
    }

    /// B2 / N: scrolling sessions (the Shortcuts open / close automations) as `sensor` Scrolling entries; one counted
    /// only from its check-in or an estimate is still Scrolling, just less sure. Ids from the session, so rebuilds replace.
    @discardableResult
    public static func scrolling(_ sessions: [ScrollSession], entries: inout [Entry], now: Date, since: Date) -> [UUID] {
        apps(sessions, entries: &entries, now: now, since: since) { _ in CategoryTree.scrolling }
    }

    /// v1.3: every app session the automations logged, filed by `category` (nil: no entry, e.g. an app that's neither
    /// scrolling nor messaging). Sensor entries are assumed until you say yes, and lose to anything you tracked. One you
    /// re-filed keeps your category; an unconfirmed one whose app no longer counts is removed.
    @discardableResult
    public static func apps(_ sessions: [ScrollSession], entries: inout [Entry], now: Date, since: Date,
                            category: (String) -> CategoryID?) -> [UUID] {
        var out: [UUID] = []
        for s in sessions where s.openedAt >= since {
            guard let end = s.endedAt, end > s.openedAt, end <= now, end.timeIntervalSince(s.openedAt) >= 60 else { continue }
            let id = Entry.sensorId("scroll|\(s.id.uuidString)")
            let j = entries.firstIndex { $0.id == id }
            guard let cat = category(s.app) else {
                if let j, !entries[j].filedByYou, entries[j].marks.isEmpty { entries.remove(at: j) }
                continue
            }
            let e = Entry(id: id, title: s.app, start: s.openedAt, end: end, category: cat,
                          note: s.endSource?.observed == false ? "estimated end" : nil, source: .sensor, createdAt: end)
            if let j {
                var x = e
                x.marks = entries[j].marks
                if entries[j].filedByYou { x.category = entries[j].category }
                x.filedByYou = entries[j].filedByYou
                if entries[j] != x { entries[j] = x }
            } else {
                entries.append(e)
            }
            out.append(id)
        }
        return out
    }
}
