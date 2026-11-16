import SwiftUI
import ProductiumCore

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemId: UUID?
    @State private var draft: WorkItem
    @State private var topics = ""
    private let isNew: Bool

    init(itemId: UUID?) {
        self.itemId = itemId
        isNew = itemId == nil
        let existing = itemId.flatMap { id in AppModel.shared.state.items.first { $0.id == id } }
        let d = existing ?? WorkItem(title: "", kind: .assignment,
                                     due: Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date())
        _draft = State(initialValue: d)
        _topics = State(initialValue: d.topics.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $draft.title)
                Picker("Type", selection: $draft.kind) {
                    ForEach(TaskKind.allCases, id: \.self) { Label($0.rawValue.capitalized, systemImage: $0.symbol).tag($0) }
                }
                TextField("Subject", text: Binding(get: { draft.subject ?? "" }, set: { draft.subject = $0.isEmpty ? nil : $0 }))
                DatePicker("Due", selection: $draft.due)
            }
            Section {
                Stepper("About \(minutesLabel(draft.estimateMinutes))", value: $draft.estimateMinutes, in: 10...3000, step: draft.estimateMinutes < 120 ? 10 : 30)
                let f = model.state.learned.estimateFactor(for: draft.kind)
                if abs(f - 1) > 0.05 {
                    Text("Planned as \(minutesLabel(Int(Double(draft.estimateMinutes) * f))). \(draft.kind.rawValue.capitalized)s usually take you \(Int(((f - 1) * 100).rounded()))% \(f > 1 ? "longer" : "less") than you'd guess.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Stakes", selection: $draft.importance) {
                    Text("Low").tag(1); Text("Some").tag(2); Text("Normal").tag(3); Text("High").tag(4); Text("Huge").tag(5)
                }
                Picker("Difficulty", selection: $draft.difficulty) { Text("Easy").tag(1); Text("Medium").tag(2); Text("Hard").tag(3) }
            } footer: {
                Text("Hard work goes in your sharpest hours. When time is short, high-stakes work wins.")
            }
            if draft.kind.isMemoryBased {
                Section {
                    TextField("e.g. ch 4 derivatives, chain rule", text: $topics, axis: .vertical)
                } header: { Text("Topics") } footer: { Text("Used to make flashcards for spaced review.") }
            }
            Section("Notes") { TextField("", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }), axis: .vertical).lineLimit(2...8) }

            let children = model.state.items.filter { $0.parentId == draft.id }.sorted { $0.due < $1.due }
            if !children.isEmpty {
                Section("Steps") {
                    ForEach(children) { c in
                        HStack {
                            Button { model.complete(c.id) } label: {
                                Image(systemName: c.isDone ? "checkmark.circle.fill" : "circle").foregroundStyle(c.isDone ? .green : .secondary)
                            }.buttonStyle(.plain)
                            VStack(alignment: .leading) {
                                Text(c.title.replacingOccurrences(of: draft.title + ": ", with: "")).strikethrough(c.isDone)
                                Text(c.due.relativeDay).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !isNew {
                Section {
                    Button { model.focusNow(on: draft); dismiss() } label: { Label("Start now", systemImage: "play.fill") }
                    if [.essay, .application, .project].contains(draft.kind) && children.isEmpty {
                        Button { Task { await model.decompose(draft.id) } } label: {
                            Label(model.busy.contains("decompose") ? "Breaking it down…" : "Break into steps", systemImage: "list.number")
                        }
                        .disabled(!ClaudeClient.shared.isConfigured || model.busy.contains("decompose"))
                    }
                    if draft.kind.isMemoryBased && !draft.topics.isEmpty {
                        Button { Task { await model.makeCards(for: draft) } } label: { Label("Make flashcards", systemImage: "rectangle.on.rectangle") }
                    }
                    Button { model.complete(draft.id); dismiss() } label: { Label("Mark done", systemImage: "checkmark") }
                    Button(role: .destructive) { model.delete(draft.id); dismiss() } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle(isNew ? "New task" : "Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    draft.topics = topics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if isNew { model.add(draft); model.replan() } else { model.update(draft) }
                    dismiss()
                }
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
