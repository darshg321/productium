import DeviceActivity
import SwiftUI

@main
struct ProductiumReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        TotalActivityReport { TotalActivityView(summary: $0) }
    }
}

extension DeviceActivityReport.Context {
    static let total = Self("Total Activity")
}

struct ActivitySummary {
    var total: TimeInterval
    var pickups: Int
    var top: [(name: String, duration: TimeInterval)]
}

struct TotalActivityReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .total
    let content: (ActivitySummary) -> TotalActivityView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> ActivitySummary {
        var total: TimeInterval = 0
        var pickups = 0
        var perApp: [String: TimeInterval] = [:]
        for await d in data {
            for await segment in d.activitySegments {
                total += segment.totalActivityDuration
                for await category in segment.categories {
                    for await app in category.applications {
                        let name = app.application.localizedDisplayName ?? "App"
                        perApp[name, default: 0] += app.totalActivityDuration
                        pickups += app.numberOfPickups
                    }
                }
            }
        }
        let top = perApp.sorted { $0.value > $1.value }.prefix(4).map { (name: $0.key, duration: $0.value) }
        return ActivitySummary(total: total, pickups: pickups, top: Array(top))
    }
}

struct TotalActivityView: View {
    let summary: ActivitySummary

    func fmt(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(fmt(summary.total)).font(.system(.title, design: .rounded).weight(.semibold))
                Text("on screen").foregroundStyle(.secondary)
                Spacer()
                Text("\(summary.pickups) pickups").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(summary.top, id: \.name) { item in
                HStack {
                    Text(item.name).font(.subheadline)
                    Spacer()
                    Text(fmt(item.duration)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    Capsule().fill(.tint.opacity(0.25))
                        .frame(width: max(4, g.size.width * CGFloat(item.duration / max(1, summary.top.first?.duration ?? 1))))
                }.frame(height: 4)
            }
        }
        .padding(.vertical, 4)
    }
}
