import SwiftUI
import Charts
import ProductiumCore

struct ReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    note
                    MetricsSection()
                    SectionTitle("Your Week")
                    Card {
                        CardHeader(title: "As It Went", symbol: "calendar", color: .secondary, detail: "Today so far and the 6 days before")
                        WeekAsLived(days: lastDays)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .refreshable { await model.insightPass(force: true) }
            .navigationTitle("Review")
            .usageMeter()
        }
    }

    private var lastDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0...6).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

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
}

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
                legend("Sleep", "moon.fill", Theme.sleep)
                legend("Study", "pencil.line", Theme.focus)
                legend("Free", "sun.max", Theme.free)
                legend("Fixed", "building.2", Theme.fixed)
                legend("Scrolling", "hourglass", Theme.screen)
            }
            .padding(.top, 4)
        }
    }

    private func legend(_ t: String, _ symbol: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
                .overlay { Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.7)) }
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
                    Rectangle().fill(Theme.color(for: s.category))
                        .overlay { if s.inferred { Hatch().opacity(0.45) } }
                        .overlay(alignment: .trailing) { Rectangle().fill(Color(.systemBackground)).frame(width: 1) }
                        .frame(width: g.size.width * CGFloat(s.minutes) / 1440)
                }
                Spacer(minLength: 0)
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// Diagonal stripes for time that is inferred rather than observed. A pattern, so it survives grayscale.
struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(p, with: .color(.black), lineWidth: 1)
                x += 5
            }
        }
        .allowsHitTesting(false)
    }
}
