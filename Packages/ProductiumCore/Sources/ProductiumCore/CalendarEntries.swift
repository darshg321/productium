import Foundation

/// Calendar import as Entries (v1.2 step 7). Each event is a `calendar` entry with `Entry.calendarId(eventKitId)`, so a
/// re-import finds it again: your marks (skipped, confirmed) and any filing of yours stay, events that vanished from the
/// window are removed, and past ones (outside the window) are left alone. Calendar itself is never written.
public enum CalendarEntries {
    /// Imports `events` seen in `window`. An event that is one of your own entries (CS club in Calendar and in your
    /// timetable) is marked skipped for that day, so it counts once, as yours.
    /// v1.5 G1: `classify` files an event by its title (your corrections and learned rules), instead of Other.
    public static func merge(_ events: [FixedEvent], into entries: inout [Entry], window: DateInterval, book: DayRuleBook = DayRuleBook(),
                             now: Date, calendar cal: Calendar, classify: (String) -> CategoryID = { _ in CategoryTree.other }) {
        let yours = entries.filter { $0.source == .you && $0.repeats != nil || $0.source == .you && $0.taskId == nil }
        var seen = Set<UUID>()
        for ev in events {
            let id = Entry.calendarId(ev.id)
            seen.insert(id)
            var e = Entry(id: id, title: ev.title, start: ev.start, end: ev.end, category: classify(ev.title), source: .calendar, createdAt: now)
            var idx = entries.firstIndex { $0.id == id }
            if let i = idx {
                e.marks = entries[i].marks
                e.createdAt = entries[i].createdAt
                if entries[i].filedByYou { e.category = entries[i].category; e.filedByYou = true; e.topics = entries[i].topics }
                entries[i] = e
            } else {
                entries.append(e)
                idx = entries.count - 1
            }
            let day = DayKeys.key(ev.start, cal)
            if entries[idx!].marks[day] == nil, isTwin(ev, of: yours, book: book, now: now, calendar: cal) {
                entries[idx!].marks[day] = .skipped
            }
        }
        entries.removeAll { $0.source == .calendar && !seen.contains($0.id) && $0.start >= window.start && $0.start < window.end }
    }

    /// Words that make an event something happening in the class, not the class itself ("Data Test" in Data Management).
    static let assessment: Set<String> = ["test", "quiz", "exam", "midterm", "final", "presentation", "presentations", "due",
                                          "write", "analysis", "lab", "assessment", "evaluation", "deadline"]

    static func isTwin(_ ev: FixedEvent, of yours: [Entry], book: DayRuleBook, now: Date, calendar cal: Calendar) -> Bool {
        if TaskMatch.words(ev.title).contains(where: assessment.contains) { return false }
        let day = cal.startOfDay(for: ev.start)
        return Days.on(day, yours, now: now, book: book, calendar: cal).contains { o in
            cal.isDate(o.start, inSameDayAs: ev.start) && o.end > o.start
                && EventMatch.overlap((ev.start, ev.end), (o.start, o.end)) >= 0.8 && EventMatch.similarTitles(ev.title, o.title)
        }
    }

    /// v1.6 B4: an event Productium can't file by its title goes with the class or task it names ("Data" → the
    /// Data Management class, "Hamlet" → the task's subject), else Other.
    public static func classifier(rules: CategoryRules, tree: CategoryTree, entries: [Entry], items: [WorkItem],
                                  scrollingApps: [String: Bool] = [:]) -> (String) -> CategoryID {
        let classes = entries.filter { $0.repeats != nil && tree.isUnder($0.category, CategoryTree.school) && $0.category != CategoryTree.school }
        let tasks = items.filter { $0.isOpen && $0.category != nil }
        func school(_ id: CategoryID) -> CategoryID {
            guard let name = tree.path(id).last?.name, !tree.isUnder(id, CategoryTree.school) else { return id }
            return tree.find(name, under: CategoryTree.school)?.id ?? id
        }
        return { title in
            let filed = rules.category(for: title, tree: tree, scrollingApps: scrollingApps)
            guard filed == CategoryTree.other else { return filed }
            let w = TaskMatch.words(title).filter { $0.count >= 4 && !assessment.contains($0) }
            guard !w.isEmpty else { return filed }
            func hits(_ s: String) -> Bool { TaskMatch.words(s).contains { t in w.contains { TaskMatch.same($0, t) } } }
            let byClass = Set(classes.filter { hits($0.title) || hits(tree.node($0.category)?.name ?? "") }.map(\.category))
            if byClass.count == 1, let c = byClass.first { return c }
            let byTask = Set(tasks.filter { hits($0.title) }.compactMap(\.category).map(school))
            if byTask.count == 1, let c = byTask.first { return c }
            return filed
        }
    }
}
