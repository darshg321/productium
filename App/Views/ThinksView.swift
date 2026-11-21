import SwiftUI
import ProductiumCore

struct ThinksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let beliefs = model.state.beliefs
        List {
            Section {
                NavigationLink { ChangesView() } label: {
                    LabeledContent("Changes", value: "\(model.state.changes.applied.count)")
                }
                NavigationLink("Study Settings") { StudySettings() }
                NavigationLink { TaxonomyRunsView() } label: {
                    LabeledContent("Category Tidy-Ups", value: "\(model.state.taxonomy.runs.filter { !$0.reverted }.count)")
                }
            } footer: {
                Text("What Productium adjusted about how it plans and reminds you, from how your weeks went. Each one can be undone.")
            }
            let reminders = model.state.policy.intentions.filter { $0.byStudent == true }
            if !reminders.isEmpty {
                Section("Your Reminders") {
                    ForEach(reminders) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.text)
                            Text(r.trigger == IntentionNudge.Trigger.arriveHome ? "When you get home" : (r.time?.label ?? "")).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { model.removeReminder(r.id) } }
                    }
                }
            }
            let gaps = model.state.telemetry.events.filter { $0.area == .gap && $0.name == "cant_do" }.suffix(30).reversed()
            if !gaps.isEmpty {
                Section {
                    ForEach(Array(gaps.enumerated()), id: \.offset) { _, g in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.detail["what"] ?? "")
                            if let said = g.detail["said"], !said.isEmpty { Text(said).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } header: { Text("Things I Couldn't Do Yet") } footer: {
                    Text("What you asked for that Productium has no way to do. It's in the backup, and it's the list for the next version.")
                }
            }
            Section {
                ForEach(Beliefs.routines(model.routines)) { BeliefRow(belief: $0) }
                ForEach(beliefs.group("routines")) { BeliefRow(belief: $0) }
            } header: { Text("Routines") } footer: {
                Text("Learned from what you log. Tell the box your own routine (\"I get ready 7:00 to 7:40\") and that's used instead.")
            }
            ForEach(beliefs.groups.filter { !["routines", "places", "scrolling", "patterns"].contains($0.id) }) { g in
                let rows = beliefs.group(g.id)
                if !rows.isEmpty || g.createdBy != "app" {
                    Section {
                        ForEach(rows) { BeliefRow(belief: $0) }
                    } header: { Text(g.title) } footer: {
                        if let n = g.note { Text(n) }
                    }
                }
            }
            Section("Places") {
                let named = model.state.placeBook.places.filter { $0.name != nil }
                if named.isEmpty { Text("None named yet. Tell the box where you are: “this is the library”.").foregroundStyle(.secondary) }
                ForEach(named) { p in LabeledContent(p.title, value: p.named?.rawValue ?? "") }
            }
            Section("Scrolling") {
                let log = Friction.log
                let apps = Set(log.sessions.map(\.app)).sorted()
                if apps.isEmpty { Text("Nothing counted yet.").foregroundStyle(.secondary) }
                ForEach(apps, id: \.self) { a in
                    LabeledContent(a, value: "usually \(log.typicalMinutes(a)) min a session")
                }
                ForEach(log.calibrationNotes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
            let patterns = model.aboutMe[.patterns]
            if !patterns.isEmpty {
                Section("Patterns") {
                    ForEach(patterns, id: \.text) { Text($0.text).font(.subheadline) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("What Productium Thinks")
        .onChange(of: model.state.beliefs) { _, _ in model.replan() }
    }
}

struct BeliefRow: View {
    let belief: Belief

    var body: some View {
        NavigationLink { BeliefDetail(id: belief.id, fallback: belief) } label: {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent(belief.label, value: belief.display)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String {
        var parts = [belief.confidence.title]
        if belief.samples > 0 { parts.append("from \(belief.samples) \(belief.samples == 1 ? "day" : "days")") }
        if let d = belief.disagreement { parts.append(d) }
        return parts.joined(separator: " · ")
    }
}

struct BeliefDetail: View {
    @Environment(AppModel.self) private var model
    let id: String
    let fallback: Belief

    var body: some View {
        let b = model.state.beliefs[id] ?? fallback
        List {
            Section {
                LabeledContent("Now", value: b.display)
                LabeledContent("How sure", value: b.confidence.title)
                if b.prior != b.effective { LabeledContent("Started at", value: Belief.format(b.prior, b.unit)) }
            }
            Section("Evidence") {
                if b.evidence.isEmpty { Text("Nothing yet: this is the starting assumption.").foregroundStyle(.secondary) }
                ForEach(b.evidence, id: \.self) { Text($0).font(.subheadline) }
            }
            Section {
                Button("Correct…") {
                    model.draftText = "\(b.label) is actually about "
                    model.deepLink = "productium://now"
                }
                if model.state.beliefs[id] != nil {
                    Button("Reset to the Starting Assumption", role: .destructive) { model.state.beliefs.reset(id) }
                }
            } footer: {
                Text("Correct… opens the Inbox with this filled in, so you only add the number.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(b.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let log = model.state.changes
        List {
            Section {
                if log.history.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(log.history) { c in ChangeRow(change: c) }
            } footer: {
                Text("Changed with the weekly note, in small steps, at most once a week each. Undo anything here; Productium won't try it again for a month.")
            }
            Section {
                if model.busy.contains("review") {
                    HStack(spacing: 10) { ProgressView(); Text("Thinking about your week…").foregroundStyle(.secondary) }
                } else {
                    Button("Why Do I Keep Putting Things Off?") {
                        Task { await model.insightPass(asked: "Why do I keep putting things off?") }
                    }
                }
            } footer: { Text("The answer appears in the Weekly Note on Review.") }
            if !log.pinned.isEmpty {
                Section("Never Changed") {
                    ForEach(log.pinned.sorted(), id: \.self) { k in
                        HStack {
                            Text(Registry.knob(k)?.note.capitalizedFirstLetter ?? k)
                            Spacer()
                            Button("Allow") { model.unpin(k) }.font(.subheadline).buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Changes")
    }
}

struct ChangeRow: View {
    @Environment(AppModel.self) private var model
    let change: LoggedChange

    private var statusLine: String {
        switch change.status {
        case .applied: return "Changed \(change.at.formatted(date: .abbreviated, time: .omitted))"
        case .reverted: return "Undone \((change.revertedAt ?? change.at).formatted(date: .abbreviated, time: .omitted))"
        case .declined: return "You turned this down"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(change.title).font(.subheadline)
            Text("\(statusLine) · \(change.reason)").font(.caption).foregroundStyle(.secondary)
            if change.status == .applied {
                HStack(spacing: 16) {
                    Button("Revert") { model.revertChange(change.id) }
                    Button("Never Change This") { model.neverChange(change.id) }.foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
        }
    }
}

extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
