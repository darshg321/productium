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
                NavigationLink { ChangesView() } label: {
                    LabeledContent("Changes", value: "\(model.state.proposals.pending.count) waiting")
                }
            } footer: {
                Text("What the weekly reflection suggested about how Productium behaves. Nothing changes until you approve it.")
            }
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

/// Settings → What Productium Thinks → Changes: pending suggestions, then approved ones with Revert.
struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let book = model.state.proposals
        List {
            Section("Waiting for You") {
                if book.pending.isEmpty { Text("Nothing waiting.").foregroundStyle(.secondary) }
                ForEach(book.pending) { ProposalRow(proposal: $0) }
            }
            Section("Changed") {
                if book.history.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(book.history) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.title).font(.subheadline)
                        Text("\(p.status == .reverted ? "Reverted" : "Approved") \((p.decidedAt ?? p.at).formatted(date: .abbreviated, time: .omitted)) · \(p.reason)")
                            .font(.caption).foregroundStyle(.secondary)
                        if p.status == .approved {
                            Button("Revert") { model.revertProposal(p.id) }.font(.subheadline).buttonStyle(.borderless)
                        }
                    }
                }
            }
            if !book.pinned.isEmpty {
                Section("Never Changed") {
                    ForEach(book.pinned.sorted(), id: \.self) { k in
                        Text(Registry.knob(k)?.note.capitalizedFirstLetter ?? k)
                    }
                }
            }
            if book.isPaused(now: Date()), let until = book.pausedUntil {
                Section { Text("Suggestions are paused until \(until.formatted(date: .abbreviated, time: .omitted)), since you turned down the last two.") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Changes")
    }
}

extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
