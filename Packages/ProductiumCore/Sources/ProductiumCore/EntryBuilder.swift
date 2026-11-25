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
        let nights = entries.filter { $0.source == .plan && $0.alert?.edge == .end && $0.category == CategoryTree.sleep }
        for night in nights {
            guard let end = night.end else { continue }
            let mid = night.start.addingTimeInterval(end.timeIntervalSince(night.start) / 2)
            let mine = uses.filter { $0.end <= now && $0.end > $0.start && $0.end > night.start && $0.start < end }
                .sorted { $0.start < $1.start }
            // v1.6 E2: pickups under 15 min apart are one stretch, and one under 2 min isn't worth asking about.
            var spans: [PhoneUse] = []
            for u in mine {
                if let last = spans.last, u.start.timeIntervalSince(last.end) < 15 * 60 { spans[spans.count - 1].end = max(last.end, u.end) }
                else { spans.append(u) }
            }
            spans = spans.filter { $0.end.timeIntervalSince($0.start) >= 120 }
            let keep = Set(spans.map { Entry.sensorId($0.key) })
            let window = DateInterval(start: night.start, end: max(night.start, end))
            entries.removeAll { e in
                e.source == .sensor && e.title == "Phone" && e.marks.isEmpty && !keep.contains(e.id) && window.contains(e.start)
            }
            for u in spans {
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
    /// scrolling nor messaging). Back-to-back sessions of one app (under `mergeMinutes` apart) are one entry. Sensor
    /// entries are assumed until you say yes, and lose to anything you tracked. One you re-filed keeps your category;
    /// an unconfirmed one whose app no longer counts is removed.
    @discardableResult
    public static func apps(_ sessions: [ScrollSession], entries: inout [Entry], now: Date, since: Date,
                            category: (ScrollSession) -> CategoryID?) -> [UUID] {
        func drop(_ id: UUID) {
            if let j = entries.firstIndex(where: { $0.id == id }), !entries[j].filedByYou, entries[j].marks.isEmpty { entries.remove(at: j) }
        }
        var runs: [(first: ScrollSession, end: Date, merged: [ScrollSession])] = []
        for s in sessions.filter({ $0.openedAt >= since }).sorted(by: { $0.openedAt < $1.openedAt }) {
            guard let end = s.endedAt, end > s.openedAt, end <= now else { continue }
            if let last = runs.last, last.first.app.plainKey == s.app.plainKey,
               s.openedAt.timeIntervalSince(last.end) < Double(mergeMinutes) * 60 {
                runs[runs.count - 1].end = max(last.end, end)
                runs[runs.count - 1].merged.append(s)
            } else {
                runs.append((s, end, []))
            }
        }
        var out: [UUID] = []
        for r in runs {
            let s = r.first
            r.merged.forEach { drop(Entry.sensorId("scroll|\($0.id.uuidString)")) }
            let id = Entry.sensorId("scroll|\(s.id.uuidString)")
            guard r.end.timeIntervalSince(s.openedAt) >= 60, let cat = category(s) else { drop(id); continue }
            let estimated = (r.merged.last ?? s).endSource?.observed == false
            let e = Entry(id: id, title: s.app, start: s.openedAt, end: r.end, category: cat,
                          note: estimated ? "estimated end" : nil, source: .sensor, createdAt: r.end)
            if let j = entries.firstIndex(where: { $0.id == id }) {
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

    /// Sessions of one app this close together are one stretch of using it.
    public static let mergeMinutes = 5
}
