import SwiftUI
import Charts
import ProductiumCore

/// The last seven days as Health-style highlight cards: Claude's weekly note, then sleep,
/// work and scrolling (one number, one comparison, one small chart each), then the week
/// drawn as it actually went.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            let this = model.dayTotals(last: 7)
            let prev = Array(model.dayTotals(last: 14).prefix(7))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    note
                    SectionTitle("Highlights")
                    sleepCard(this, prev)
                    workCard(this)
                    screenCard(this)
                    SectionTitle("Your Week")
                    Card {
                        CardHeader(title: "As It Went", symbol: "calendar", color: .secondary, detail: "Last 7 days")
                        WeekAsLived(days: lastDays)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .refreshable { await model.weeklyReviewIfDue(force: true) }
            .navigationTitle("Review")
            .usageMeter()
        }
    }

    private var lastDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (1...7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

    private func avg(_ xs: [Int]) -> Int? { xs.isEmpty ? nil : xs.reduce(0, +) / xs.count }

    // MARK: Cards

    @ViewBuilder private var note: some View {
        Card {
            CardHeader(title: "Weekly Note", symbol: "sparkles", color: .teal,
                       detail: model.state.reviewAt.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) })
            if let r = model.state.review {
                Text(r.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                ForEach(r.wins + r.suggestions, id: \.self) { line in
                    Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            } else if model.busy.contains("review") {
                HStack(spacing: 10) { ProgressView(); Text("Claude is reading your week…").foregroundStyle(.secondary) }
            } else {
                Text("Your first weekly note arrives after a few days of use. Pull down to ask for one now.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// Where last week's nights came from, e.g. "from your check-ins".
    private var sleepSource: String? {
        let week = model.state.health.filter { $0.sleepMinutes != nil && $0.day > Date().addingTimeInterval(-8 * 86400) }
        let sources = Set(week.map { $0.sleepSource ?? .health })
        guard !sources.isEmpty else { return nil }
        return sources.count == 1 ? sources.first!.label.prefix(1).uppercased() + sources.first!.label.dropFirst() : "From Health and your check-ins"
    }

    private func sleepCard(_ this: [DayTotals], _ prev: [DayTotals]) -> some View {
        let s = avg(this.compactMap(\.sleep)), before = avg(prev.compactMap(\.sleep))
        return Card {
            CardHeader(title: "Sleep", symbol: "bed.double.fill", color: Theme.sleep, detail: "Average")
            if let s {
                DurationValue(minutes: s)
                if let src = sleepSource {
                    Text(src).font(.subheadline).foregroundStyle(.secondary)
                }
                if let b = before {
                    let d = s - b
                    Text(abs(d) < 10 ? "About the same as the week before." : "\(durationLabel(abs(d))) \(d > 0 ? "more" : "less") than the week before.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(this, id: \.day) { t in
                        BarMark(x: .value("Day", t.day, unit: .day), y: .value("Hours", Double(t.sleep ?? 0) / 60))
                            .foregroundStyle(Theme.sleep.gradient)
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("Need", Double(model.state.prefs.sleepNeedMinutes) / 60))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .chartYAxis { AxisMarks(position: .trailing) }
                .frame(height: 110)
            } else {
                Text("Turn on Health in Settings, or tell the Inbox when you woke up.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func workCard(_ this: [DayTotals]) -> some View {
        let planned = this.reduce(0) { $0 + $1.plannedStudy }, done = this.reduce(0) { $0 + $1.doneStudy }
        return Card {
            CardHeader(title: "Work", symbol: "pencil.line", color: Theme.focus, detail: "This week")
            if planned > 0 {
                BigValue(value: "\(Int(Double(done) / Double(planned) * 100))", unit: "% of planned")
                Text("\(durationLabel(done)) of focused work in total.").font(.subheadline).foregroundStyle(.secondary)
                Chart {
                    ForEach(this, id: \.day) { t in
                        BarMark(x: .value("Day", t.day, unit: .day), y: .value("Minutes", t.doneStudy))
                            .foregroundStyle(Theme.focus.gradient)
                            .cornerRadius(3)
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .chartYAxis(.hidden)
                .frame(height: 90)
            } else {
                Text("Nothing planned yet this week.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func screenCard(_ this: [DayTotals]) -> some View {
        let sc = avg(this.compactMap(\.screen))
        let limit = model.state.taper.targetMinutes
        return Card {
            CardHeader(title: "Screen Time", symbol: "hourglass", color: Theme.screen, detail: "Daily average")
            if let sc {
                DurationValue(minutes: sc)
                if let l = limit {
                    Text(sc <= l ? "Under your \(durationLabel(l)) goal." : "\(durationLabel(sc - l)) over your \(durationLabel(l)) goal.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("Not tracked yet. Drop a Screen Time screenshot in the Inbox on Today.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Seven strips, one per day, showing what the time actually went to (observed or
/// assumed), with a legend.
struct WeekAsLived: View {
    @Environment(AppModel.self) private var model
    let days: [Date]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(days, id: \.self) { d in
                HStack(spacing: 10) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    SegmentStrip(segments: model.segments(on: d))
                }
            }
            HStack(spacing: 12) {
                legend("Sleep", Theme.sleep)
                legend("Study", Theme.focus)
                legend("Free", Theme.free)
                legend("Fixed", Theme.fixed)
            }
            .padding(.top, 4)
        }
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SegmentStrip: View {
    let segments: [Segment]
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(segments, id: \.start) { s in
                    Rectangle().fill(Theme.color(for: s.category).opacity(s.inferred ? 0.55 : 1))
                        .frame(width: g.size.width * CGFloat(s.minutes) / 1440)
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
