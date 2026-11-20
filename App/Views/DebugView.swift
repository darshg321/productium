import SwiftUI
import ProductiumCore

/// Settings → Debug (T3): the numbers to look at first, then the development log, newest first. Everything here is
/// also in every backup (`ExportBundle.diagnostics` and `state.telemetry`).
struct DebugView: View {
    @Environment(AppModel.self) private var model
    @State private var area: TelemetryEvent.Area?
    @State private var level: TelemetryEvent.Level = .debug

    var body: some View {
        let snap = Diagnostics.snapshot(model.state, now: Date(), calendar: model.cal)
        let events = model.state.telemetry.recent(area, atLeast: level, limit: 200).reversed()
        List {
            Section("Now") {
                ForEach(snap.sorted { $0.key < $1.key }, id: \.key) { k, v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k).font(.caption).foregroundStyle(.secondary)
                        Text(v).font(.footnote.monospaced())
                    }
                }
            }
            Section("Log") {
                Picker("Area", selection: $area) {
                    Text("All").tag(TelemetryEvent.Area?.none)
                    ForEach(TelemetryEvent.Area.allCases, id: \.self) { Text($0.rawValue).tag(TelemetryEvent.Area?.some($0)) }
                }
                Picker("Level", selection: $level) {
                    ForEach([TelemetryEvent.Level.debug, .info, .warn, .error], id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text("\(model.state.telemetry.events.count) events kept (newest \(Telemetry.maxEvents), \(Telemetry.maxAgeDays) days)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(e.area.rawValue).\(e.name)").font(.footnote.weight(.semibold))
                                .foregroundStyle(e.level == .error ? .red : e.level == .warn ? .orange : .primary)
                            Spacer()
                            Text(e.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if !e.detail.isEmpty {
                            Text(e.detail.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                        }
                    }
                }
            }
        }
        .navigationTitle("Debug")
    }
}
