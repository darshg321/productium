import SwiftUI
import ProductiumCore

/// Full-screen focus session. The distracting apps are shielded while it runs.
/// Nothing else on screen: interruptions leave "attention residue" that slows the
/// work you return to (Leroy 2009; Mark et al. 2008).
struct FocusView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        if let f = model.state.focus {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let total = max(60, f.plannedEnd.timeIntervalSince(f.startedAt))
                let elapsed = ctx.date.timeIntervalSince(f.startedAt)
                let remaining = max(0, f.plannedEnd.timeIntervalSince(ctx.date))
                VStack(spacing: 28) {
                    Spacer()
                    Text(f.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center).padding(.horizontal)
                    if let hint = model.state.plan.blocks.first(where: { $0.id == f.blockId })?.hint {
                        Text(hint).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 10)
                        Circle().trim(from: 0, to: min(1, elapsed / total))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 4) {
                            Text(remaining > 0 ? clock(remaining) : "+" + clock(-f.plannedEnd.timeIntervalSince(ctx.date)))
                                .font(.system(size: 54, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(remaining > 0 ? "left" : "over. Nice momentum").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 250, height: 250)
                    if model.state.integrations.screenTime {
                        Label("Distracting apps are paused", systemImage: "shield.lefthalf.filled")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(spacing: 12) {
                        Button { model.endFocus(.done) } label: {
                            Text(remaining > 0 ? "Finished early" : "Done").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Stop") { confirmStop = true }
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .onChange(of: remaining == 0) { _, ended in
                    if ended { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            }
            .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("I got some done") { model.endFocus(.partial) }
                Button("Couldn't focus") { model.endFocus(.skipped) }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("Either way, the plan adjusts. No streak to lose.")
            }
            .interactiveDismissDisabled()
        } else {
            Color.clear
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
