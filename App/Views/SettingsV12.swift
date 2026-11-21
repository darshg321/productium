import SwiftUI
import ProductiumCore

// MARK: - J3: Settings → Alarms

struct AlarmsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        List {
            Section {
                Toggle(isOn: Binding(get: { model.state.integrations.alarms }, set: { on in
                    Task {
                        m.state.integrations.alarms = on ? await AlarmService.requestAuthorization() : false
                        model.log(.alarm, "master", ["on": "\(m.state.integrations.alarms)"])
                        model.replan()
                    }
                })) { SettingsLabel(title: "Full-Screen Alarms", symbol: "alarm.fill", color: .orange) }
            } footer: {
                Text("Off: Productium never rings full screen; you get normal notifications instead. A new alarm the AI wants always waits for your Allow.")
            }
            Section("Productium's Alarms") {
                Toggle("Wake-Up (the end of your planned sleep)", isOn: $m.state.prefs.wakeAlarms)
                Toggle("Bedtime, Leave-By and Missed Start", isOn: $m.state.prefs.nudges.alarms)
            }
            Section {
                if model.entryAlarmList.isEmpty { Text("None yet. Ask the box: “alarm at 6:40 on school days”.").foregroundStyle(.secondary) }
                ForEach(model.entryAlarmList) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title)
                        Text(e.start.hm + (e.repeats.map { " · " + $0.days.text(.current) } ?? "") + (e.alert?.approved == true ? "" : " · waiting for Allow"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Turn Off", role: .destructive) { model.removeAlarm(e) } }
                }
            } header: { Text("Yours") } footer: { Text("Swipe to turn one off. Turning alarms off or moving them never needs approval.") }
            let waiting = model.approvals.filter(\.addsAlarm)
            if !waiting.isEmpty {
                Section("Waiting for You") { ForEach(waiting) { ApprovalRow(approval: $0) } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Alarms")
        .onChange(of: model.state.prefs) { _, _ in model.replan() }
    }
}

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

// MARK: - E5: Settings → Privacy

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    @State private var renaming: UUID?
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                LabeledContent("Visits kept", value: "\(model.state.trace.visits.count)")
                LabeledContent("Places", value: "\(model.state.placeBook.places.count)")
                LabeledContent("Location", value: LocationService.shared.statusText)
            } footer: {
                Text("The location history stays on this phone and in backups you make. It's kept 180 days, then dropped.")
            }
            Section {
                ForEach(model.state.placeBook.places.filter { $0.name != nil }) { p in
                    Button { newName = p.title; renaming = p.id } label: { Text(p.title).foregroundStyle(.primary) }
                        .swipeActions { Button("Forget", role: .destructive) { model.forgetPlace(p.id) } }
                }
            } header: { Text("Named Places") }
            Section {
                Button("Forget Location History", role: .destructive) { confirm = true }
            }
        }
        .listStyle(.insetGrouped)
        .alert("Rename place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let id = renaming, !name.isEmpty { model.renamePlace(id, name) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .navigationTitle("Privacy")
        .confirmationDialog("Forget every visit, place and the place on every entry?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.forgetLocationHistory() }
        }
    }
}
