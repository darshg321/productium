import SwiftUI
import ProductiumCore

/// What Productium knows about one task and when it's planned. Edit opens the same form as
/// adding a task (no tokens); the Inbox still takes plain-words changes ("move the essay to friday").
struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemId: UUID
    @State private var editing: WorkItem?

    init(itemId: UUID) { self.itemId = itemId }

    var body: some View {
        if let item = model.state.items.first(where: { $0.id == itemId }) {
            let steps = model.state.items.filter { $0.parentId == item.id }.sorted { $0.due < $1.due }
            let ids: Set<UUID> = Set([item.id] + steps.map(\.id))
            let planned: [PlannedBlock] = model.state.plan.blocks.filter { b in
                guard b.isStudy, b.end > Date(), let id = b.itemId else { return false }
                return ids.contains(id)
            }
            let total = Int(Double(item.estimateMinutes) * model.state.learned.estimateFactor(for: item.kind))
            List {
                Section {
                    HStack(spacing: 14) {
                        IconTile(symbol: item.kind.symbol, color: Theme.color(for: item.kind), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            Text([item.kind.rawValue.capitalized, item.subject].compactMap { $0 }.joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    LabeledContent("Due", value: "\(item.due.relativeDay.capitalized), \(item.due.hm)")
                    LabeledContent("Planned Time", value: durationLabel(total))
                    if item.completedMinutes > 0 {
                        LabeledContent("Done So Far", value: durationLabel(item.completedMinutes))
                    }
                    if total > 0 {
                        ProgressView(value: min(1, Double(item.completedMinutes) / Double(total)))
                            .tint(Theme.focus)
                    }
                    if !item.topics.isEmpty {
                        LabeledContent("Covers", value: item.topics.joined(separator: ", "))
                    }
                } footer: {
                    if let short = model.state.plan.shortfalls[item.id], short > 0 {
                        Label("About \(durationLabel(short)) of this doesn't fit before it's due.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.alert)
                    }
                }

                if !steps.isEmpty {
                    Section("Steps") {
                        ForEach(steps) { s in
                            Button { model.complete(s.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: s.isDone ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(s.isDone ? Theme.focus : Color.secondary)
                                    Text(s.title.replacingOccurrences(of: item.title + ": ", with: ""))
                                        .strikethrough(s.isDone)
                                        .foregroundStyle(s.isDone ? .secondary : .primary)
                                    Spacer()
                                    Text(s.due.relativeDay).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(s.isDone)
                            .accessibilityLabel(s.isDone ? "\(s.title), done" : "Mark \(s.title) done")
                        }
                    }
                }

                if !planned.isEmpty {
                    Section("Planned Sessions") {
                        ForEach(planned.prefix(8)) { b in
                            LabeledContent("\(b.start.relativeDay.capitalized), \(b.start.hm)", value: durationLabel(b.minutes))
                        }
                    }
                }

                if let n = item.notes, !n.isEmpty {
                    Section("Notes") { Text(n).font(.subheadline) }
                }

                Section {
                    if item.isDone {
                        Button { model.reopen(item.id) } label: {
                            Label("Mark as Not Done", systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button { model.focusNow(on: item); dismiss() } label: {
                            Label("Work on It Now", systemImage: "play.fill")
                        }
                        Button { model.complete(item.id); dismiss() } label: {
                            Label("Mark as Done", systemImage: "checkmark.circle")
                        }
                    }
                    Button(role: .destructive) { model.delete(item.id); dismiss() } label: {
                        Label("Delete Task", systemImage: "trash")
                    }
                } footer: {
                    Text("Edit changes it here, with no AI. You can also tell the Inbox, like “move this to friday”.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = item } }
            }
            .sheet(item: $editing) { TaskEditor(item: $0, isNew: false) }
        } else {
            ContentUnavailableView("Task Removed", systemImage: "tray")
        }
    }
}
