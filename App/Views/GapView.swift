import SwiftUI
import ProductiumCore

/// A few spare minutes: options that beat scrolling. Retrieval practice, a short
/// read, prep for the next block, or a reset. Usually two or three choices, never a feed.
struct GapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: GapActivity?

    var minutes: Int {
        guard let b = model.state.plan.current(at: Date()), b.kind == .gap || b.kind == .free || b.kind == .breakTime else { return 5 }
        return max(2, Int(b.end.timeIntervalSinceNow / 60))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .flashcards: FlashcardSession()
                case .read(let p): ReadView(piece: p)
                case .nextStep(let id, let prompt): NextStepView(itemId: id, prompt: prompt)
                case .breathe: BreatheView()
                case .walk: WalkView()
                case nil: chooser
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if mode != nil { ToolbarItem(placement: .topBarLeading) { Button("Back") { mode = nil } } }
            }
            .task { await model.ensureGapContent() }
        }
    }

    private var chooser: some View {
        let opts = GapPlanner.options(minutes: minutes, cards: model.state.flashcards, reads: model.state.reads,
                                      items: model.state.items, mood: model.todayMood?.mood, now: Date())
        return VStack(alignment: .leading, spacing: 22) {
            Text("\(minutes) minutes").font(.display(34, .bold))
            if Friction.pausesToday() > 0 {
                Text("Paused \(Friction.pausesToday()) times today.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(opts.enumerated()), id: \.offset) { _, o in
                Button { mode = o } label: {
                    HStack(spacing: 14) {
                        Image(systemName: symbol(o)).font(.title3).foregroundStyle(Theme.cobalt).frame(width: 28)
                        Text(o.title).font(.title3).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            TextAction("Go back to the app anyway (no pause for 10 min)", color: .secondary) {
                Friction.grant(minutes: 10)
                dismiss()
            }
            .font(.footnote)
        }
        .padding(24)
    }

    private func symbol(_ o: GapActivity) -> String {
        switch o {
        case .flashcards: return "rectangle.on.rectangle"
        case .read: return "text.book.closed"
        case .nextStep: return "list.bullet"
        case .breathe: return "wind"
        case .walk: return "figure.walk"
        }
    }
}

struct FlashcardSession: View {
    @Environment(AppModel.self) private var model
    @State private var revealed = false
    @State private var queue: [Flashcard] = []
    @State private var done = 0

    var body: some View {
        VStack(spacing: 20) {
            if let c = queue.first {
                Text("\(done) done, \(queue.count) to go").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let s = c.subject { Text(s).font(.caption).foregroundStyle(.secondary) }
                        Text(c.front).font(.title3.weight(.semibold))
                        if revealed {
                            Divider()
                            Text(c.back).font(.body)
                        } else {
                            Text("Answer in your head first. Retrieving it is what builds memory.").font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fog.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radius))
                }
                .onTapGesture { withAnimation { revealed = true } }
                if revealed {
                    HStack(spacing: 12) {
                        Button("Missed it") { next(c, false) }.buttonStyle(SlabButtonStyle(color: .gray))
                        Button("Got it") { next(c, true) }.buttonStyle(SlabButtonStyle())
                    }
                } else {
                    Button("Show answer") { withAnimation { revealed = true } }.buttonStyle(SlabButtonStyle())
                }
            } else {
                ContentUnavailableView(done > 0 ? "Done: \(done) cards" : "No cards due",
                                       systemImage: "checkmark.circle",
                                       description: Text(done > 0 ? "They'll come back right before you'd forget them." : "Add topics to a test to get cards."))
            }
            Spacer()
        }
        .padding()
        .onAppear { queue = Array(Leitner.dueCards(model.state.flashcards, now: Date()).prefix(12)) }
    }

    private func next(_ c: Flashcard, _ ok: Bool) {
        model.reviewCard(c.id, correct: ok)
        revealed = false
        done += 1
        withAnimation { queue.removeFirst() }
    }
}

struct ReadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let piece: ReadPiece
    @State private var answer = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(piece.title).font(.display(24, .bold))
                Text(piece.body).font(.body).lineSpacing(5)
                if let q = piece.question {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(q).font(.headline)
                        TextField("Your answer, if you want", text: $answer, axis: .vertical).lineLimit(2...5)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.cobalt).frame(width: 3) }
                }
                Button("Done reading") { model.markRead(piece.id); dismiss() }.buttonStyle(SlabButtonStyle())
            }
            .padding()
        }
    }
}

struct NextStepView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let itemId: UUID
    let prompt: String
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt).font(.headline)
            TextField("Three short points", text: $text, axis: .vertical).lineLimit(4...10)
                .padding(12).background(Theme.fog.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.radius))
            Button {
                if var item = model.state.items.first(where: { $0.id == itemId }), !text.isEmpty {
                    item.notes = [item.notes, "Next: " + text].compactMap { $0 }.joined(separator: "\n")
                    model.update(item)
                }
                dismiss()
            } label: { Text("Save to the task") }
                .buttonStyle(SlabButtonStyle())
            Text("Planning the next step lowers the effort of starting it, and it stops it nagging at you in the meantime.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}

struct BreatheView: View {
    @State private var phase = 0
    @State private var started = Date()
    @State private var finished = false

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(started)
            let cycle = t.truncatingRemainder(dividingBy: 10)   // 2s inhale, 1s top-up, 7s exhale
            let scale = cycle < 2 ? 0.6 + 0.3 * cycle / 2 : cycle < 3 ? 0.9 + 0.1 * (cycle - 2) : 1.0 - 0.4 * (cycle - 3) / 7
            let step = cycle < 2 ? 0 : cycle < 3 ? 1 : 2
            VStack(spacing: 30) {
                Spacer()
                Rectangle().fill(Theme.cobalt.opacity(0.85)).frame(width: 12, height: 300 * scale)
                    .frame(height: 300, alignment: .bottom)
                Text(GapPlanner.breathingSteps[step]).font(.title3)
                Text(t < 60 ? "\(60 - Int(t))s" : "That's a minute. Nicely done.").foregroundStyle(.secondary)
                Spacer()
            }
            .onChange(of: t >= 60) { _, done in
                if done && !finished {
                    finished = true
                    HealthService.shared.logMindful(start: started, end: Date())
                }
            }
        }
        .onAppear { started = Date() }
    }
}

struct WalkView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Walk for a few minutes").font(.display(26, .bold))
            Text("Phone in your pocket, eyes up. Even a short walk improves attention for the next block, and daylight helps you fall asleep on time tonight.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }
}
