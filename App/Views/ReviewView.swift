import SwiftUI
import ProductiumCore

/// The last seven days in three parts: a short note from Claude, the week drawn as
/// it actually went, and three sentences. No charts to pick between, no knobs.
struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Last 7 days").font(.display(34, .bold)).padding(.top, 16)
                    note
                    WeekAsLived(days: lastDays)
                    facts
                    if model.state.review?.changes != nil {
                        Button("Apply Claude's suggested changes") { model.applyReviewChanges() }
                            .buttonStyle(SlabButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .refreshable { await model.weeklyReviewIfDue(force: true) }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var lastDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (1...7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

    @ViewBuilder private var note: some View {
        if let r = model.state.review {
            VStack(alignment: .leading, spacing: 10) {
                Text(r.headline).font(.display(20, .semibold))
                Text((r.wins + r.suggestions).joined(separator: " "))
                    .font(.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        } else if model.busy.contains("review") {
            HStack(spacing: 10) { ProgressView(); Text("Claude is reading your week").foregroundStyle(.secondary) }
        } else {
            Text("Your first weekly note shows up after a few days of use. Pull down to ask for one now.")
                .foregroundStyle(.secondary)
        }
    }

    private var facts: some View {
        let this = model.dayTotals(last: 7)
        let prev = model.dayTotals(last: 14).prefix(7)
        func avg(_ xs: [Int]) -> Int? { xs.isEmpty ? nil : xs.reduce(0, +) / xs.count }
        let sleep = avg(this.compactMap(\.sleep)), sleepBefore = avg(prev.compactMap(\.sleep))
        let planned = this.reduce(0) { $0 + $1.plannedStudy }, done = this.reduce(0) { $0 + $1.doneStudy }
        let screen = avg(this.compactMap(\.screen))
        let limit = model.state.taper.targetMinutes
        return VStack(alignment: .leading, spacing: 14) {
            if let s = sleep {
                Text("You slept \(minutesLabel(s)) a night" + (sleepBefore.map { b in
                    let d = s - b
                    return abs(d) < 10 ? ", about the same as the week before." : ", \(minutesLabel(abs(d))) \(d > 0 ? "more" : "less") than the week before."
                } ?? "."))
            }
            if planned > 0 {
                Text("You did \(Int(Double(done) / Double(planned) * 100))% of the work you planned, \(minutesLabel(done)) in total.")
            }
            if let sc = screen {
                Text("Scrolling: \(minutesLabel(sc)) a day" + (limit.map { ", against a goal of \(minutesLabel($0))." } ?? "."))
            } else {
                Text("Scrolling isn't tracked yet. Drop a Screen Time screenshot in the box on Today.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Seven strips, one per day, showing what the time actually went to (observed or
/// assumed), with a legend written as words in their own colours.
struct WeekAsLived: View {
    @Environment(AppModel.self) private var model
    let days: [Date]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(days, id: \.self) { d in
                HStack(spacing: 10) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    SegmentStrip(segments: model.segments(on: d))
                }
            }
            legend.padding(.top, 6)
        }
    }

    private var legend: some View {
        (Text("Sleep").foregroundColor(Theme.night) + Text(", ") + Text("study").foregroundColor(Theme.cobalt)
         + Text(", ") + Text("free").foregroundColor(Theme.daylight) + Text(", and everything fixed in grey."))
            .font(.footnote)
            .foregroundStyle(.secondary)
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
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}
