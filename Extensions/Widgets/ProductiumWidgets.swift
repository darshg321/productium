import WidgetKit
import SwiftUI
import ActivityKit

@main
struct ProductiumWidgets: WidgetBundle {
    var body: some Widget {
        NextUpWidget()
        BlockLiveActivity()
    }
}

// MARK: - Home / lock screen widget: now + next

struct NextUpEntry: TimelineEntry {
    let date: Date
    let now: WidgetSnapshot.Item?
    let next: WidgetSnapshot.Item?
    let progress: Double
}

struct NextUpProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextUpEntry {
        NextUpEntry(date: Date(), now: .init(title: "Chem review", start: Date(), end: Date().addingTimeInterval(1800), kind: "review", symbol: "graduationcap"),
                    next: .init(title: "Free", start: Date().addingTimeInterval(1800), end: Date().addingTimeInterval(3600), kind: "free", symbol: "sun.max"),
                    progress: 0.4)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextUpEntry) -> Void) {
        completion(entries().first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextUpEntry>) -> Void) {
        let e = entries()
        completion(Timeline(entries: e.isEmpty ? [NextUpEntry(date: Date(), now: nil, next: nil, progress: 0)] : e,
                            policy: .after(Date().addingTimeInterval(3600))))
    }

    /// One entry per block boundary in the next 12 hours, so the widget changes on time with no app wake-ups.
    private func entries() -> [NextUpEntry] {
        guard let snap = WidgetSnapshot.load() else { return [] }
        let items = snap.items.sorted { $0.start < $1.start }
        let progress = snap.studyMinutesToday > 0 ? Double(snap.doneMinutesToday) / Double(snap.studyMinutesToday) : 0
        var dates = Set([Date()])
        for i in items where i.start > Date() && i.start < Date().addingTimeInterval(12 * 3600) { dates.insert(i.start) }
        return dates.sorted().map { d in
            NextUpEntry(date: d, now: items.first { $0.start <= d && d < $0.end },
                        next: items.first { $0.start > d }, progress: progress)
        }
    }
}

struct NextUpView: View {
    @Environment(\.widgetFamily) var family
    let entry: NextUpEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                if let n = entry.now {
                    Text(n.title).font(.headline).lineLimit(1)
                    Text(timerInterval: n.start...n.end, countsDown: true).font(.caption).monospacedDigit()
                } else if let n = entry.next {
                    Text("Next: \(n.title)").font(.headline).lineLimit(1)
                    Text(n.start, style: .time).font(.caption)
                } else {
                    Text("Nothing planned").font(.headline)
                }
            }
        case .accessoryCircular:
            Gauge(value: entry.progress) { Image(systemName: "checkmark") }
                .gaugeStyle(.accessoryCircularCapacity)
        default:
            VStack(alignment: .leading, spacing: 6) {
                if let n = entry.now {
                    Label(n.title, systemImage: n.symbol).font(.headline).lineLimit(2)
                    Text(timerInterval: n.start...n.end, countsDown: true)
                        .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                } else {
                    Text("Free right now").font(.headline)
                }
                Spacer(minLength: 0)
                if let n = entry.next {
                    HStack {
                        Text(n.start, style: .time).foregroundStyle(.secondary)
                        Text(n.title).lineLimit(1)
                    }.font(.caption)
                }
            }
        }
    }
}

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextUp", provider: NextUpProvider()) { entry in
            NextUpView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now & next")
        .description("What you're on, and what's after.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
    }
}

// MARK: - Live Activity

struct BlockLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BlockActivityAttributes.self) { context in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.title).font(.headline).lineLimit(1)
                    if let next = context.state.nextTitle {
                        Text("Then: \(next)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                    .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                    .frame(maxWidth: 90)
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground).opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.kind == "breakTime" ? "cup.and.saucer" : "leaf").foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.center) { Text(context.state.title).lineLimit(1) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true).monospacedDigit().frame(width: 60)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(timerInterval: context.state.start...context.state.end, countsDown: false).tint(.indigo)
                }
            } compactLeading: {
                Image(systemName: "leaf").foregroundStyle(.indigo)
            } compactTrailing: {
                Text(timerInterval: context.state.start...context.state.end, countsDown: true).monospacedDigit().frame(width: 44)
            } minimal: {
                Image(systemName: "leaf").foregroundStyle(.indigo)
            }
        }
    }
}
