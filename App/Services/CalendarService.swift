import Foundation
import EventKit
import ProductiumCore

/// Imports calendar events as busy time (and as deadlines when titled like one), and
/// can write the plan into a "Productium" calendar so it shows on the Watch, etc.
final class CalendarService {
    static let shared = CalendarService()
    let store = EKEventStore()
    private let calendarTitle = "Productium"

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(days: Int) -> [FixedEvent] {
        guard authorized else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(Double(days) * 86400)
        let cals = store.calendars(for: .event).filter { $0.title != calendarTitle }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        return store.events(matching: pred).filter { !$0.isAllDay && $0.availability != .free }.compactMap { e in
            guard let start = e.startDate, let end = e.endDate else { return nil }
            return FixedEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Event", start: start, end: end, kind: .other)
        }
    }

    /// Events like "Bio test" or "Essay due" (timed or all-day) become work items, with no typing.
    func deadlineCandidates(days: Int) -> [WorkItem] {
        guard authorized else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let pred = store.predicateForEvents(withStart: start, end: start.addingTimeInterval(Double(days) * 86400),
                                            calendars: store.calendars(for: .event).filter { $0.title != calendarTitle })
        return store.events(matching: pred).compactMap { e in
            guard let title = e.title, let kind = Self.deadlineKind(title), let start = e.startDate else { return nil }
            let due = e.isAllDay ? (Calendar.current.date(bySettingHour: kind.isMemoryBased ? 8 : 23,
                                                         minute: kind.isMemoryBased ? 0 : 59, second: 0, of: start) ?? start)
                                 : start
            return WorkItem(title: title, kind: kind, due: due, importance: kind == .test ? 4 : 3, source: .calendar,
                            externalId: "cal:" + (e.eventIdentifier ?? title))
        }
    }

    static func deadlineKind(_ title: String) -> TaskKind? {
        let t = title.lowercased()
        if t.contains("final") || t.contains("exam") || t.contains("midterm") || t.contains(" test") || t.hasPrefix("test") { return .test }
        if t.contains("quiz") { return .quiz }
        if t.contains("essay") && (t.contains("due") || t.contains("deadline")) { return .essay }
        if t.contains("application") && (t.contains("due") || t.contains("deadline")) { return .application }
        if t.contains("project") && t.contains("due") { return .project }
        if t.contains(" due") || t.hasSuffix("due") || t.contains("deadline") { return .assignment }
        return nil
    }

    private func productiumCalendar() -> EKCalendar? {
        if let c = store.calendars(for: .event).first(where: { $0.title == calendarTitle }) { return c }
        let c = EKCalendar(for: .event, eventStore: store)
        c.title = calendarTitle
        c.cgColor = CGColor(red: 0.36, green: 0.42, blue: 0.85, alpha: 1)
        c.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local }
            ?? store.sources.first
        do { try store.saveCalendar(c, commit: true); return c } catch { return nil }
    }

    /// Replaces future events in the Productium calendar with the next 7 days of study blocks.
    func export(plan: Plan) {
        guard authorized, let cal = productiumCalendar() else { return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(14 * 86400), calendars: [cal])
        for e in store.events(matching: pred) { try? store.remove(e, span: .thisEvent, commit: false) }
        for b in plan.blocks where b.isStudy && b.start > now && b.start < now.addingTimeInterval(7 * 86400) {
            let e = EKEvent(eventStore: store)
            e.calendar = cal
            e.title = b.title
            e.startDate = b.start
            e.endDate = b.end
            e.notes = b.hint
            try? store.save(e, span: .thisEvent, commit: false)
        }
        try? store.commit()
    }
}
