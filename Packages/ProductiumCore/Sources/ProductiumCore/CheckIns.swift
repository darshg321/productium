import Foundation

/// Check-ins ("left home", "starting homework", "woke up") as the log (v1.2 step 9). A `CheckIn` is what a phrase,
/// a geofence or a notification answer says happened at an instant; it is never stored. `apply` turns it into
/// entries: a start begins a running entry (closing the one before), an end finishes it. `derive` goes the other
/// way for the estimators that work on instants (sleep, meals, routine lengths).
public enum CheckIns {
    static func source(_ s: MarkerSource) -> EntrySource {
        switch s {
        case .manual, .voice, .notification: return .you
        case .geofence, .inferred: return .sensor
        case .health: return .health
        }
    }

    static func markerSource(_ s: EntrySource) -> MarkerSource {
        switch s {
        case .you, .calendar, .plan: return .manual
        case .sensor: return .inferred
        case .health: return .health
        }
    }

    /// Where a check-in's time is filed: a known class or activity under its own node, else the closest group.
    static func category(_ activity: String, _ tc: TimeCategory, tree: inout CategoryTree) -> CategoryID {
        let name = TimelineBuilder.display(activity)
        switch tc {
        case .sleep: return CategoryTree.sleep
        case .school:
            return ["school", "to_school", "from_school"].contains(activity) ? CategoryTree.school
                : tree.add(name, under: CategoryTree.school)?.id ?? CategoryTree.school
        case .activities: return tree.add(name, under: CategoryTree.extracurricular)?.id ?? CategoryTree.extracurricular
        case .study: return CategoryTree.studying
        case .commute: return CategoryTree.travel
        case .routine: return ["dinner", "meal"].contains(activity) ? CategoryTree.meals : CategoryTree.gettingReady
        case .screen: return CategoryTree.scrolling
        case .free: return ["dinner", "meal"].contains(activity) ? CategoryTree.meals : CategoryTree.free
        }
    }

    /// Writes check-ins into the log. Returns the ids of entries started, ended or created.
    @discardableResult
    public static func apply(_ events: [CheckIn], to entries: inout [Entry], tree: inout CategoryTree, now: Date,
                             calendar cal: Calendar) -> [UUID] {
        var touched: [UUID] = []
        for m in events.sorted(by: { $0.at < $1.at }) where m.phase != .point {
            let running = entries.indices.first { entries[$0].isRunning && entries[$0].topics.contains(m.activity) }
            switch m.phase {
            case .start:
                // The same transition twice within 3 minutes (a voice and a geofence) is one.
                if let i = running, abs(entries[i].start.timeIntervalSince(m.at)) <= 180 {
                    if m.at < entries[i].start { entries[i].start = m.at }
                    touched.append(entries[i].id)
                    continue
                }
                if entries.contains(where: { $0.topics.contains(m.activity) && $0.repeats == nil && $0.source != .plan
                                             && abs($0.start.timeIntervalSince(m.at)) <= 180 }) { continue }
                let e = Entry(title: TimelineBuilder.display(m.activity), start: m.at, end: nil,
                              category: category(m.activity, m.category, tree: &tree), topics: [m.activity],
                              source: source(m.source), createdAt: m.at)
                TimeLog.start(e, at: m.at, now: max(m.at, now), entries: &entries, calendar: cal)
                touched.append(e.id)
            case .end:
                if let i = running {
                    if m.at > entries[i].start { entries[i].end = m.at; touched.append(entries[i].id) }
                    else { entries.remove(at: i) }
                } else if ["wake", "sleep"].contains(m.activity) {
                    if let i = entries.indices.first(where: { entries[$0].isRunning && entries[$0].category == CategoryTree.sleep }) {
                        if m.at > entries[i].start { entries[i].end = m.at; touched.append(entries[i].id) }
                    } else if cal.component(.hour, from: m.at) < 12 {
                        // Woke up with no bedtime logged: the night so far, from midnight.
                        let start = cal.startOfDay(for: m.at)
                        if m.at > start {
                            let e = Entry(title: "Sleep", start: start, end: m.at, category: CategoryTree.sleep, topics: ["sleep"],
                                          source: source(m.source), createdAt: m.at)
                            TimeLog.insert(e, now: now, entries: &entries, calendar: cal)
                            touched.append(e.id)
                        }
                    }
                } else if let i = entries.indices.first(where: {
                    entries[$0].source == .you && entries[$0].repeats != nil
                        && MarkerParser.normalise(entries[$0].title) == MarkerParser.normalise(m.activity.replacingOccurrences(of: "_", with: " "))
                }) {
                    // "Finished math": today's class ended when you said, and it happened.
                    let key = DayKeys.key(m.at, cal)
                    if var one = Days.detach(&entries[i], occurrence: key, calendar: cal, now: now), m.at > one.start {
                        one.end = m.at
                        one.marks = [DayKeys.key(one.start, cal): .confirmed]
                        entries.append(one)
                        touched.append(one.id)
                    }
                }
            case .point: break
            }
        }
        return touched
    }

    /// The log as instants in `range`: a start at each entry's start and an end at its end (a running entry has no
    /// end yet). Only what happened: assumed time (classes, planned routines) is left out.
    public static func derive(_ entries: [Entry], tree: CategoryTree, in range: DateInterval, now: Date,
                              book: DayRuleBook = DayRuleBook(), calendar cal: Calendar) -> [CheckIn] {
        var out: [CheckIn] = []
        for d in Days.expand(entries.filter { $0.source != .plan }, in: range, now: now, book: book, calendar: cal)
        where !d.assumed && !d.isPlannedSession {
            let activity = d.entry.topics.first ?? MarkerParser.normalise(d.title).replacingOccurrences(of: " ", with: "_")
            let tc = tree.legacy(d.category)
            let src = markerSource(d.source)
            out.append(CheckIn(id: d.entry.id, at: d.start, phrase: d.title, activity: activity, category: tc, phase: .start, source: src))
            if !d.running { out.append(CheckIn(id: d.entry.id, at: d.end, phrase: d.title, activity: activity, category: tc, phase: .end, source: src)) }
        }
        return out.sorted { $0.at < $1.at }
    }
}

/// Planned study vs what you actually worked on (v1.2 step 9): the log is the answer, so a block is "worked" when
/// time of yours with that task was tracked around it, in any order.
public enum Sessions {
    public static func isWorked(_ b: PlannedBlock, entries: [Entry], now: Date) -> Bool {
        guard let task = b.itemId else { return false }
        return entries.contains { e in
            e.taskId == task && e.source != .plan && e.repeats == nil
                && !(e.source == .you && e.createdAt < e.start.addingTimeInterval(-60) && !e.marks.values.contains(.confirmed))
                && e.start < b.end.addingTimeInterval(2 * 3600) && (e.end ?? now) > b.start.addingTimeInterval(-30 * 60)
                && e.start <= now
        }
    }

    /// Study blocks that ended in the last 36 hours and weren't worked on.
    public static func pending(plan: Plan, entries: [Entry], now: Date) -> [PlannedBlock] {
        plan.blocks.filter { $0.isStudy && $0.end <= now && $0.end > now.addingTimeInterval(-36 * 3600) && !isWorked($0, entries: entries, now: now) }
    }

    /// Blocks in the last two days that have time tracked on them (so no "how did it go?" nudge for them).
    public static func worked(plan: Plan, entries: [Entry], now: Date) -> Set<UUID> {
        Set(plan.blocks.filter { $0.isStudy && $0.start > now.addingTimeInterval(-2 * 86400) && isWorked($0, entries: entries, now: now) }.map(\.id))
    }

    /// The study block a running task session is on: the one for that task around now (or the next within 90 minutes).
    public static func block(for running: Entry?, in plan: Plan, now: Date) -> PlannedBlock? {
        guard let task = running?.taskId else { return nil }
        return plan.blocks.first { $0.itemId == task && $0.isStudy && $0.start <= now && $0.end > now }
            ?? plan.blocks.first { $0.itemId == task && $0.isStudy && $0.start > now && $0.start < now.addingTimeInterval(90 * 60) }
    }
}
