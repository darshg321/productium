import SwiftUI
import Charts
import ProductiumCore

// MARK: - K4: Settings → Categories (the same edits the box can do)

struct CategoriesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tree = model.state.categories
        List {
            Section {
                ForEach(ordered(tree), id: \.id) { n in
                    NavigationLink { CategoryDetail(id: n.id) } label: {
                        HStack {
                            Text(String(repeating: "    ", count: tree.depth(n.id) - 1))
                            Image(systemName: n.symbol).foregroundStyle(Theme.color(category: n.id, tree: tree))
                            Text(n.name)
                            if n.yours { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            } footer: {
                Text("Productium files everything into this tree and tidies it now and then. Ones you named or moved (📌) are never changed by it.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Categories")
    }

    private func ordered(_ tree: CategoryTree) -> [CategoryNode] {
        var out: [CategoryNode] = []
        func walk(_ p: CategoryID?) { for n in tree.children(p).sorted(by: { $0.name < $1.name }) { out.append(n); walk(n.id) } }
        walk(nil)
        return out
    }
}

struct CategoryDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: CategoryID
    @State private var name = ""
    @State private var into: CategoryID = CategoryTree.other

    static let colours = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray"]

    var body: some View {
        let tree = model.state.categories
        List {
            Section("Name") {
                TextField("Name", text: $name).onSubmit { model.renameCategory(id, name) }
                Button("Rename") { model.renameCategory(id, name) }.disabled(name == tree.node(id)?.name || name.isEmpty)
            }
            Section("Colour") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                    ForEach(Self.colours, id: \.self) { c in
                        Button { model.recolourCategory(id, c) } label: {
                            Circle().fill(Theme.named(c) ?? .gray).frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.primary, lineWidth: tree.node(id)?.colour == c ? 2 : 0))
                        }
                        .buttonStyle(.plain).accessibilityLabel(c)
                    }
                }
            }
            Section {
                CategoryPicker(selection: $into)
                Button("Merge Into \(tree.pathText(into))", role: .destructive) { model.mergeCategory(id, into: into); dismiss() }
                    .disabled(into == id || tree.isUnder(into, id))
            } header: { Text("Merge") } footer: { Text("Its time moves too; nothing is lost.") }
            if tree.node(id)?.yours != true {
                Section { Button("Never Change This") { model.pinCategory(id) } }
            }
        }
        .navigationTitle(tree.node(id)?.name ?? "Category")
        .onAppear { name = tree.node(id)?.name ?? ""; into = tree.node(id)?.parentId ?? CategoryTree.other }
    }
}

struct TaxonomyRunsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.state.taxonomy.runs.isEmpty { Text("No tidy-ups yet.").foregroundStyle(.secondary) }
            ForEach(model.state.taxonomy.runs.reversed()) { r in
                Section(r.at.formatted(date: .abbreviated, time: .shortened)) {
                    ForEach(r.lines, id: \.self) { Text($0).font(.subheadline) }
                    if r.reverted { Text("Reverted").foregroundStyle(.secondary) } else { Button("Revert") { model.revertTaxonomy(r.id) } }
                }
            }
        }
        .navigationTitle("Category Tidy-Ups")
    }
}

// MARK: - I: Settings → Goals

struct GoalsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.goalsAll) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.progress(g).line)
                        Text(g.origin == .builtIn ? "Built in" : g.origin == .ai ? "Suggested by Productium (it may move it ±10%)" : "Yours")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        if g.origin != .builtIn { Button("Remove", role: .destructive) { model.removeGoal(g.id) } }
                    }
                }
            } footer: {
                Text("Add or change one in the box: “my goal is 10 hours of studying a week”, “scrolling under an hour a day”, “finish 3 tasks a day”.")
            }
            let s = model.suggestedGoals
            if !s.isEmpty {
                Section("Suggested") {
                    ForEach(s) { g in
                        HStack {
                            Text("\(g.title) \(g.direction == .atMost ? "under" : "at least") \(durationLabel(g.target)) a \(g.period.rawValue)")
                            Spacer()
                            Button("Add") { model.addGoal(g) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Goals")
    }
}

// MARK: - v1.3 G: Settings → Places (from Review's Where; the Privacy screen is gone)

struct PlacesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var newName = ""
    @State private var merging: Place?

    var body: some View {
        List {
            Section { WhereCard().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            Section {
                ForEach(model.state.placeBook.places.sorted { $0.visits > $1.visits }) { p in
                    Button { newName = p.name ?? ""; renaming = p.id } label: {
                        LabeledContent {
                            Image(systemName: "pencil").foregroundStyle(.tint)
                        } label: {
                            Text(p.title).foregroundStyle(.primary)
                            Text(source(p)).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Merge") { merging = p }.tint(.orange) }
                    .contextMenu { Button("Merge Into…", systemImage: "arrow.triangle.merge") { merging = p } }
                }
            } header: { Text("Your Places") } footer: { Text("Tap a place to rename it. Swipe to merge two that are the same spot.") }
        }
        .listStyle(.insetGrouped)
        .alert("Rename Place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let id = renaming, !name.isEmpty { model.renamePlace(id, name) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .navigationTitle("Places")
        .confirmationDialog("Merge \(merging?.title ?? "") into…", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } }),
                            titleVisibility: .visible) {
            if let m = merging {
                ForEach(model.state.placeBook.places.filter { $0.id != m.id }.sorted { $0.visits > $1.visits }.prefix(8)) { p in
                    Button(p.title) { model.mergePlace(m.id, into: p.id); merging = nil }
                }
            }
        }
    }

    private func source(_ p: Place) -> String {
        let visits = p.visits == 1 ? "1 visit" : "\(p.visits) visits"
        switch p.named {
        case .you: return "Named by you · \(visits)"
        case .entries: return "From what you did there · \(visits)"
        case .map: return "From the address · \(visits)"
        case nil: return visits
        }
    }
}

// MARK: - E4: where

struct WhereCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = Calendar.current
        let week = DateInterval(start: cal.date(byAdding: .day, value: -7, to: Date()) ?? Date(), end: Date())
        let rows = Where.rows(visits: model.state.trace.visits, book: model.state.placeBook, entries: model.state.entries, range: week, now: Date())
        if !rows.isEmpty {
            Card {
                CardHeader(title: "Where", symbol: "mappin.and.ellipse", color: .red, detail: "Last 7 days")
                Chart(rows.prefix(6)) { r in
                    SectorMark(angle: .value("Minutes", r.minutes), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(by: .value("Place", r.name))
                }
                .frame(height: 150)
                ForEach(rows.prefix(8)) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(r.name, value: durationLabel(r.minutes))
                        if !r.top.isEmpty {
                            Text(r.top.map { "\(model.state.categories.node($0.0)?.name ?? $0.0) \(durationLabel($0.1))" }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                Text("Name a place by telling the box where you are: “this is the library”.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

