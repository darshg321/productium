import Foundation

// v1.1 Part I: one day as a list in time order, not a grid. Wake first (with leave-by), bed last, study blocks as the
// prominent rows, fixed time as one quiet row each (a school day's periods collapse into it), free time as a gap row,
// due items inline at their time, and a Now marker on today. Overlaps are simply listed one after another.

public struct AgendaRow: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case wake, leave, study, fixed, breakTime, windDown, free, due, now, bed }
    public var id: String
    public var kind: Kind
    public var start: Date
    public var end: Date?
    public var title: String
    public var detail: String?
    public var blockId: UUID?
    public var itemId: UUID?
    /// Fixed rows only: the periods folded into this row, shown when it's opened.
    public var children: [AgendaRow]

    public var minutes: Int? { end.map { Int($0.timeIntervalSince(start) / 60) } }
}

public enum Agenda {
    /// Free stretches shorter than this aren't shown as rows.
    public static let minFreeMinutes = 20

    public static func rows(day: Date, plan: Plan, items: [WorkItem], now: Date, calendar cal: Calendar) -> [AgendaRow] {
        let dayStart = cal.startOfDay(for: day)
        var rows: [AgendaRow] = []
        func row(_ id: String, _ kind: AgendaRow.Kind, _ s: Date, _ e: Date? = nil, _ title: String, detail: String? = nil,
                 block: UUID? = nil, item: UUID? = nil, children: [AgendaRow] = []) {
            rows.append(AgendaRow(id: id, kind: kind, start: s, end: e, title: title, detail: detail, blockId: block, itemId: item, children: children))
        }

        let wake = plan.wakePlans.first { cal.isDate($0.day, inSameDayAs: dayStart) }
        if let w = wake {
            row("wake", .wake, w.wake, nil, "Wake up", detail: w.reason)
            if let l = w.leaveBy { row("leave", .leave, l, nil, "Leave by") }
        }
        let blocks = plan.blocks.filter { cal.isDate($0.start, inSameDayAs: dayStart) }.sorted { $0.start < $1.start }
        let bed = blocks.first { $0.kind == .sleep }
        if let b = bed { row("bed", .bed, b.start, nil, "Bed") }

        // Fixed time: consecutive blocks from the same activity are one row ("School 8:30–3:00") with periods inside.
        var run: [PlannedBlock] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            let kids = run.count > 1 ? run.map { AgendaRow(id: "p.\($0.id)", kind: .fixed, start: $0.start, end: $0.end, title: $0.title,
                                                         detail: nil, blockId: $0.id, itemId: nil, children: []) } : []
            row("fixed.\(first.id)", .fixed, first.start, last.end, first.sourceId != nil && run.count > 1 ? groupTitle(run) : first.title,
                block: first.id, children: kids)
            run = []
        }
        func groupTitle(_ rs: [PlannedBlock]) -> String { rs.first?.hint?.isEmpty == false ? rs[0].hint! : rs[0].title }
        for b in blocks {
            switch b.kind {
            case .commitment, .event, .meal, .routine:
                if let l = run.last, l.sourceId != nil, l.sourceId == b.sourceId, b.start.timeIntervalSince(l.end) <= 15 * 60 { run.append(b) }
                else { flush(); run = [b] }
            case .work, .review:
                flush()
                row("study.\(b.id)", .study, b.start, b.end, b.title, detail: b.hint, block: b.id, item: b.itemId)
            case .breakTime:
                flush()
                row("break.\(b.id)", .breakTime, b.start, b.end, "Break", block: b.id)
            case .windDown:
                flush()
                row("wind.\(b.id)", .windDown, b.start, b.end, "Wind down", block: b.id)
            case .free, .gap, .sleep:
                flush()
            }
        }
        flush()

        for item in items where !item.isDone && item.parentId == nil && cal.isDate(item.due, inSameDayAs: dayStart) {
            row("due.\(item.id)", .due, item.due, nil, item.title, detail: "Due", item: item.id)
        }

        // Free time: whatever is left between the day's first wake and bed, shown as gaps.
        let busy = rows.filter { [.study, .fixed, .windDown].contains($0.kind) }.compactMap { r in r.end.map { (r.start, $0) } }.sorted { $0.0 < $1.0 }
        let from = wake?.wake ?? busy.first?.0, to = bed?.start ?? busy.last?.1
        if var cursor = from, let stop = to, stop > cursor {
            if let w = wake, let l = w.leaveBy { cursor = max(cursor, l) }
            for (s, e) in busy where e > cursor {
                if s.timeIntervalSince(cursor) >= Double(minFreeMinutes) * 60, s <= stop {
                    row("free.\(Int(cursor.timeIntervalSince1970))", .free, cursor, min(s, stop), "Free")
                }
                cursor = max(cursor, e)
            }
            if stop.timeIntervalSince(cursor) >= Double(minFreeMinutes) * 60 {
                row("free.\(Int(cursor.timeIntervalSince1970))", .free, cursor, stop, "Free")
            }
        }

        if cal.isDate(now, inSameDayAs: dayStart) { row("now", .now, now, nil, "Now") }

        let order: [AgendaRow.Kind: Int] = [.wake: 0, .leave: 1, .now: 2, .study: 2, .fixed: 2, .breakTime: 2, .windDown: 2, .free: 2, .due: 2, .bed: 3]
        return rows.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            let oa = order[a.kind] ?? 2, ob = order[b.kind] ?? 2
            return oa != ob ? oa < ob : a.id < b.id
        }
    }
}
