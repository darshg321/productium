import SwiftUI
import ProductiumCore

/// A focus session, laid out like the Clock app's timer: the title, a ring that empties
/// as time passes with the time left inside it, and two buttons. Distracting apps are
/// shielded where Screen Time is available.
struct FocusView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmStop = false

    var body: some View {
        if let f = model.state.focus {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let total = max(60, f.plannedEnd.timeIntervalSince(f.startedAt))
                let remaining = f.plannedEnd.timeIntervalSince(ctx.date)
                let fraction = max(0, min(1, remaining / total))
                VStack(spacing: 28) {
                    VStack(spacing: 6) {
                        Label("Focus", systemImage: "pencil.line")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.focus)
                        Text(f.title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let hint = model.state.plan.blocks.first(where: { $0.id == f.blockId })?.hint {
                            Text(hint).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 40)
                    Spacer(minLength: 0)
                    ZStack {
                        Circle().stroke(Color(.tertiarySystemFill), lineWidth: 14)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(Theme.focus, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: fraction)
                        VStack(spacing: 4) {
                            Text(remaining > 0 ? clock(remaining) : "+" + clock(-remaining))
                                .font(.system(size: 60, weight: .light, design: .rounded).monospacedDigit())
                                .foregroundStyle(remaining > 0 ? Color.primary : Theme.focus)
                            Text("ends \(f.plannedEnd.hm)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 300)
                    .padding(.horizontal, 24)
                    Spacer(minLength: 0)
                    HStack(spacing: 14) {
                        Button { confirmStop = true } label: { Text("Stop").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                        Button { model.endFocus(.done) } label: {
                            Text(remaining > 0 ? "Finished Early" : "Done").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .onChange(of: remaining <= 0) { _, ended in
                    if ended { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            }
            .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("I Got Some Done") { model.endFocus(.partial) }
                Button("Couldn't Focus") { model.endFocus(.skipped) }
                Button("Keep Going", role: .cancel) {}
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
