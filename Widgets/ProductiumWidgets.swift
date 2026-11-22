import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct ProductiumWidgets: WidgetBundle {
    var body: some Widget {
        NowLiveActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            StopControl()
            StartNextControl()
            OpenBoxControl()
        }
    }
}

// MARK: - D5 / v1.3 B: the Now activity on the Lock Screen and in the Dynamic Island

struct NowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowAttributes.self) { context in
            NowLockScreen(card: shown(context), rings: context.state.rings)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
        } dynamicIsland: { context in
            let card = shown(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(card.title, systemImage: NowLook.symbol(card.kind)).font(.headline).lineLimit(2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let since = card.since {
                        Text(since, style: .timer).monospacedDigit().font(.headline)
                            .multilineTextAlignment(.trailing).frame(maxWidth: 80)
                    } else if let r = context.state.rings {
                        MiniRings(rings: r).frame(width: 36, height: 36)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let sub = card.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        NowButtons(card: card)
                    }
                }
            } compactLeading: {
                Image(systemName: NowLook.symbol(card.kind)).foregroundStyle(NowLook.tint(card.kind))
            } compactTrailing: {
                if let since = card.since {
                    Text(since, style: .timer).monospacedDigit().frame(maxWidth: 48)
                } else if let r = context.state.rings {
                    MiniRings(rings: r).frame(width: 18, height: 18)
                }
            } minimal: {
                Image(systemName: NowLook.symbol(card.kind)).foregroundStyle(NowLook.tint(card.kind))
            }
            .widgetURL(AppInfo.url("today"))
        }
    }

    /// Past its stale date the card that comes next shows (School ended: "What are you doing?").
    private func shown(_ context: ActivityViewContext<NowAttributes>) -> NowAttributes.Card {
        context.isStale ? (context.state.then ?? context.state.card) : context.state.card
    }
}

enum NowLook {
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "running": return "record.circle"
        case "question": return "questionmark.bubble"
        case "untracked": return "questionmark.circle"
        case "assumed": return "checkmark.circle.badge.questionmark"
        default: return "list.bullet"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind {
        case "running": return .red
        case "question": return .purple
        case "untracked": return .orange
        default: return .blue
        }
    }
}

private struct NowLockScreen: View {
    let card: NowAttributes.Card
    let rings: NowAttributes.Rings?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(card.title, systemImage: NowLook.symbol(card.kind)).font(.headline).lineLimit(2)
                    if let sub = card.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if card.kind == "running", let since = card.since {
                    Text(since, style: .timer).monospacedDigit().font(.title3.weight(.semibold))
                        .multilineTextAlignment(.trailing).frame(maxWidth: 90)
                } else if let rings {
                    MiniRings(rings: rings).frame(width: 40, height: 40)
                        .accessibilityLabel("Work \(rings.workLabel), tracked \(rings.trackedLabel), limit \(rings.limitLabel)")
                }
            }
            NowButtons(card: card)
        }
    }
}

private struct NowButtons: View {
    let card: NowAttributes.Card

    var body: some View {
        if !card.buttons.isEmpty || card.other {
            HStack(spacing: 6) {
                ForEach(card.buttons, id: \.action) { b in
                    Button(intent: NowActionIntent(action: b.action)) {
                        if let s = b.symbol { Label(b.label, systemImage: s).lineLimit(1) } else { Text(b.label).lineLimit(1) }
                    }
                    .buttonStyle(.bordered)
                    .tint(b.action == "stop" ? .red : NowLook.tint(card.kind))
                }
                if card.other {
                    Link(destination: AppInfo.url("box")!) { Label("Other", systemImage: "text.bubble").lineLimit(1) }
                        .buttonStyle(.bordered)
                }
            }
            .font(.caption)
        }
    }
}

/// D2: the three rings, small (Work blue, Tracked green, Limit teal → red).
struct MiniRings: View {
    let rings: NowAttributes.Rings

    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height)
            let line = w * 0.13
            ZStack {
                ring(rings.work, .blue, w, line)
                ring(rings.tracked, .green, w - 2.3 * line, line)
                ring(rings.limit, rings.limit >= 1 ? .red : .teal, w - 4.6 * line, line)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private func ring(_ p: Double, _ c: Color, _ size: CGFloat, _ line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(c.opacity(0.2), lineWidth: line)
            Circle().trim(from: 0, to: min(1, max(0.001, p)))
                .stroke(c, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: max(1, size), height: max(1, size))
    }
}

// MARK: - M10: Control Center, Lock Screen and Action button controls

@available(iOSApplicationExtension 18.0, *)
struct StopControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.productium.control.stop") {
            ControlWidgetButton(action: StopActivityIntent()) { Label("Stop tracking", systemImage: "stop.circle") }
        }
        .displayName("Stop tracking")
        .description("Stops whatever Productium is tracking.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct StartNextControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.productium.control.start") {
            ControlWidgetButton(action: StartFocusIntent()) { Label("Start next", systemImage: "play.circle") }
        }
        .displayName("Start next")
        .description("Starts the block that's on now, or the next one.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct OpenBoxControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.productium.control.box") {
            ControlWidgetButton(action: OpenURLIntent(AppInfo.url("box")!)) {
                Label("Tell Productium", systemImage: "text.bubble")
            }
        }
        .displayName("Tell Productium")
        .description("Opens Productium on the box.")
    }
}
