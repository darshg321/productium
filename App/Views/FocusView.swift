import SwiftUI
import ProductiumCore

/// A focus session: the title, the time left, and a single bar that empties as time
/// passes (the same ruler as Today, one block tall). Distracting apps are shielded
/// where Screen Time is available.
struct FocusView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        if let f = model.state.focus {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let total = max(60, f.plannedEnd.timeIntervalSince(f.startedAt))
                let remaining = f.plannedEnd.timeIntervalSince(ctx.date)
                HStack(alignment: .bottom, spacing: 24) {
                    GeometryReader { g in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle().fill(Theme.cobalt)
                                .frame(height: g.size.height * CGFloat(max(0, min(1, remaining / total))))
                        }
                        .background(Theme.fog.opacity(0.5))
                    }
                    .frame(width: 10)
                    VStack(alignment: .leading, spacing: 18) {
                        Spacer()
                        Text(f.title).font(.display(28, .bold)).fixedSize(horizontal: false, vertical: true)
                        if let hint = model.state.plan.blocks.first(where: { $0.id == f.blockId })?.hint {
                            Text(hint).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(remaining > 0 ? clock(remaining) : "+" + clock(-remaining))
                            .font(.system(size: 64, weight: .semibold).width(.expanded).monospacedDigit())
                            .foregroundStyle(remaining > 0 ? .primary : Theme.cobalt)
                        Spacer()
                        Button(remaining > 0 ? "Finished early" : "Done") { model.endFocus(.done) }
                            .buttonStyle(SlabButtonStyle())
                        TextAction("Stop", color: .secondary) { confirmStop = true }
                    }
                }
                .padding(24)
                .onChange(of: remaining <= 0) { _, ended in
                    if ended { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            }
            .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("I got some done") { model.endFocus(.partial) }
                Button("Couldn't focus") { model.endFocus(.skipped) }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("Either way, the plan moves the rest to a better time.")
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
