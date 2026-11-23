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

    static func isTwin(_ ev: FixedEvent, of yours: [Entry], book: DayRuleBook, now: Date, calendar cal: Calendar) -> Bool {
        let day = cal.startOfDay(for: ev.start)
        return Days.on(day, yours, now: now, book: book, calendar: cal).contains { o in
            cal.isDate(o.start, inSameDayAs: ev.start) && o.end > o.start
                && EventMatch.overlap((ev.start, ev.end), (o.start, o.end)) >= 0.8 && EventMatch.similarTitles(ev.title, o.title)
        }
    }
}
