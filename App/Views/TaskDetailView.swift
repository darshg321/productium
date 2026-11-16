import SwiftUI
import ProductiumCore

/// What Productium knows about one task and when it's planned. Changes go through the box
/// on Today ("move the essay to friday", "the essay is done"), so there's no form to fill in.
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemId: UUID

    var body: some View {
        if let item = model.state.items.first(where: { $0.id == itemId }) {
            let steps = model.state.items.filter { $0.parentId == item.id }.sorted { $0.due < $1.due }
            let ids: Set<UUID> = Set([item.id] + steps.map(\.id))
            let planned: [PlannedBlock] = model.state.plan.blocks.filter { b in
                guard b.isStudy, b.end > Date(), let id = b.itemId else { return false }
                return ids.contains(id)
            }
            let factor = model.state.learned.estimateFactor(for: item.kind)
            let total = Int(Double(item.estimateMinutes) * factor)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(item.title).font(.display(26, .bold)).fixedSize(horizontal: false, vertical: true)
                    Text(summary(item, total: total)).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let short = model.state.plan.shortfalls[item.id], short > 0 {
                        Text("About \(minutesLabel(short)) of this doesn't fit before it's due.").foregroundStyle(Theme.signal)
                    }
                    if !steps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(steps) { s in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Button { model.complete(s.id) } label: {
                                        Image(systemName: s.isDone ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(s.isDone ? Theme.cobalt : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(s.isDone ? "Done" : "Mark done")
                                    Text(s.title.replacingOccurrences(of: item.title + ": ", with: "")).strikethrough(s.isDone)
                                    Spacer()
                                    Text(s.due.relativeDay).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !planned.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Planned").font(.subheadline.weight(.semibold))
                            ForEach(planned.prefix(8)) { b in
                                Text("\(b.start.relativeDay.capitalized) at \(b.start.hm), \(b.minutes) min").font(.subheadline)
                            }
                        }
                    }
                    if let n = item.notes, !n.isEmpty { Text(n).font(.footnote).foregroundStyle(.secondary) }
                    VStack(spacing: 12) {
                        Button("Work on it now") { model.focusNow(on: item); dismiss() }.buttonStyle(SlabButtonStyle())
                        HStack {
                            TextAction("It's done") { model.complete(item.id); dismiss() }
                            Spacer()
                            TextAction("Delete", color: Theme.signal) { model.delete(item.id); dismiss() }
                        }
                    }
                    Text("To change the date, length or anything else, just tell the box on Today.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("This task is gone.").foregroundStyle(.secondary)
        }
    }

    private func summary(_ i: WorkItem, total: Int) -> String {
        var s = "\(i.kind.rawValue.capitalized)\(i.subject.map { " for \($0)" } ?? ""), due \(i.due.relativeDay) at \(i.due.hm). "
        s += "Planned as \(minutesLabel(total))"
        if i.completedMinutes > 0 { s += ", \(minutesLabel(i.completedMinutes)) done so far" }
        s += "."
        if !i.topics.isEmpty { s += " Covers \(i.topics.joined(separator: ", "))." }
        return s
    }
}
