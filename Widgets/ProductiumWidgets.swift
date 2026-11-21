import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct ProductiumWidgets: WidgetBundle {
    var body: some Widget {
        RunningLiveActivity()
        if #available(iOSApplicationExtension 18.0, *) {
            StopControl()
            StartNextControl()
            OpenBoxControl()
        }
    }
}

// MARK: - D5: the running entry on the Lock Screen and in the Dynamic Island

struct RunningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunningAttributes.self) { context in
            LockScreenRunning(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.title, systemImage: "record.circle").font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.start, style: .timer).monospacedDigit().font(.headline)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 80)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.goalLine ?? context.state.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button(intent: StopActivityIntent()) { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.bordered).tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            } compactTrailing: {
                Text(context.state.start, style: .timer).monospacedDigit().frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
            .widgetURL(AppInfo.url("today"))
        }
    }
}

private struct LockScreenRunning: View {
    let state: RunningAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(state.title, systemImage: "record.circle").font(.headline).lineLimit(1)
                Text(state.goalLine ?? state.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(state.start, style: .timer).monospacedDigit().font(.title3.weight(.semibold))
                .multilineTextAlignment(.trailing).frame(maxWidth: 90)
            Button(intent: StopActivityIntent()) { Image(systemName: "stop.fill") }
                .buttonStyle(.bordered).tint(.red)
                .accessibilityLabel("Stop")
        }
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
