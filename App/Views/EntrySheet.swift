import SwiftUI
import ProductiumCore

// v1.2 C4 / O11: one sheet for any stretch of time, wherever it was tapped (Today's ring, the schedule, Review, a
// drill-down). Editing one day of a series makes that day its own entry; a new category is a correction that teaches
// the rules, with "also move similar".

struct EntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let day: DayEntry
    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var category: CategoryID = CategoryTree.other
    @State private var topics = ""
    @State private var note = ""
    @State private var askSimilar = false

    var body: some View {
        let tree = model.state.categories
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    DatePicker("Start", selection: $start)
                    if !day.running { DatePicker("End", selection: $end, in: start...) }
                } footer: {
                    Text(status)
                }
                Section("Category") {
                    CategoryPicker(selection: $category)
                    TextField("Topics (comma separated)", text: $topics)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    if let p = model.placeName(day.entry.placeId) { LabeledContent("Place", value: p) }
                    TextField("Note", text: $note, axis: .vertical)
                }
                if day.assumed && day.end <= Date() {
                    Section {
                        Button("Yes, it happened") { model.confirm(day); dismiss() }
                        Button("No, it didn't") { model.reject(day); dismiss() }
                    } footer: { Text("It counts as what happened unless you say no.") }
                }
                if day.running {
                    Section { Button("Stop") { model.stopRunning(source: "sheet"); dismiss() } }
                }
                Section {
                    Button(day.entry.repeats != nil ? "Remove This Day" : "Delete", role: .destructive) {
                        model.remove(day)
                        dismiss()
                    }
                }
            }
            .navigationTitle(day.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear {
                title = day.title
                start = day.start
                end = day.end
                category = day.category
                topics = day.entry.topics.joined(separator: ", ")
                note = day.entry.note ?? ""
            }
            .alert("Also move similar ones?", isPresented: $askSimilar) {
                Button("Move \(model.similarCount(title, besides: day.entry.id, category: category))") {
                    model.moveSimilar(title: title, to: category)
                    dismiss()
                }
                Button("Just This One", role: .cancel) { dismiss() }
            } message: {
                Text("Other “\(title)” entries go under \(tree.pathText(category)) too, and new ones will.")
            }
        }
    }

    private var status: String {
        var parts: [String] = [day.source.label]
        if day.running { parts.append("running") }
        else if day.isPlannedSession { parts.append("planned, not started") }
        else if day.assumed { parts.append("assumed") }
        else if day.mark == .confirmed { parts.append("confirmed") }
        if day.entry.repeats != nil { parts.append("repeats: \(day.entry.repeats!.days.text(.current)); changes apply to this day only") }
        return parts.joined(separator: " · ")
    }

    private func save() {
        let t = topics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let moved = category != day.category
        model.save(day, title: title, start: start, end: day.running ? nil : end, category: category, topics: t,
                   note: note.isEmpty ? nil : note)
        if moved, model.similarCount(title, besides: day.entry.id, category: category) > 0 { askSimilar = true } else { dismiss() }
    }
}

extension EntrySource {
    var label: String {
        switch self {
        case .you: return "Yours"
        case .calendar: return "From Calendar"
        case .health: return "From Health"
        case .sensor: return "Noticed by the phone"
        case .plan: return "The plan's"
        }
    }
}

/// A picker over the whole tree, indented by depth, with "New…" under any node.
struct CategoryPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: CategoryID
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        let tree = model.state.categories
        Picker("Category", selection: $selection) {
            ForEach(ordered(tree), id: \.id) { n in
                Text(String(repeating: "   ", count: tree.depth(n.id) - 1) + n.name).tag(n.id)
            }
        }
        .pickerStyle(.navigationLink)
        Button("New Category Under \(tree.node(selection)?.name ?? "This")…") { adding = true }
            .disabled(tree.depth(selection) >= CategoryTree.maxDepth)
            .alert("New category", isPresented: $adding) {
                TextField("Name", text: $newName)
                Button("Add") {
                    if let n = model.state.categories.add(newName, under: selection, yours: true) { selection = n.id }
                    newName = ""
                    model.save()
                }
                Button("Cancel", role: .cancel) { newName = "" }
            }
    }

    private func ordered(_ tree: CategoryTree) -> [CategoryNode] {
        var out: [CategoryNode] = []
        func walk(_ p: CategoryID?) {
            for n in tree.children(p).sorted(by: { $0.name < $1.name }) { out.append(n); walk(n.id) }
        }
        walk(nil)
        return out
    }
}
