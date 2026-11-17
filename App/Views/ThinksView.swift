import SwiftUI
import ProductiumCore

/// Settings → What Productium Thinks: every assumption the app makes, one section per group,
/// each with its value, how sure it is, and the evidence behind it.
struct ThinksView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let beliefs = model.state.beliefs
        List {
            Section {
                ForEach(Beliefs.routines(model.state.routines)) { BeliefRow(belief: $0) }
                ForEach(beliefs.group("routines")) { BeliefRow(belief: $0) }
                NavigationLink("Turn Routines On or Off") { RoutineSettings() }
            } header: { Text("Routines") }
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
                if model.state.places.isEmpty { Text("None saved yet.").foregroundStyle(.secondary) }
                ForEach(model.state.places) { p in LabeledContent(p.name, value: "\(Int(p.radius)) m") }
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
                if model.state.beliefs[id] != nil {
                    Button("Reset to the Starting Assumption", role: .destructive) { model.state.beliefs.reset(id) }
                }
            } footer: {
                Text("To correct it, tell the Inbox, e.g. “\(b.label.lowercased()) is about \(b.display)”.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(b.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}
