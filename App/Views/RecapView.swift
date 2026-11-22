import SwiftUI
import ProductiumCore

// v1.3 Review → Your Week: the last 7 days as full-screen cards, one fact each (Spotify Wrapped style). Tap the right
// side or swipe for the next, the left side for the one before. Every number comes from the log (`WeekRecap`); the
// Weekly Note's words close it.

struct RecapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    struct Slide: Identifiable {
        let id: Int
        let colors: [Color]
        let symbol: String
        let kicker: String
        let big: String
        var unit: String?
        var line: String?
        var rows: [(String, String, Double, Color)] = []
    }

    var body: some View {
        let slides = make(model.weekRecap())
        ZStack(alignment: .top) {
            TabView(selection: $page) {
                ForEach(slides) { s in
                    SlideView(slide: s, last: s.id == slides.count - 1) { dismiss() }.tag(s.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation { page = max(0, page - 1) } }
                    Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation { page = min(slides.count - 1, page + 1) } }
                }
                .padding(.top, 70).padding(.bottom, 170)
            }
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(slides) { s in
                        Capsule().fill(.white.opacity(s.id <= page ? 0.95 : 0.3)).frame(height: 3)
                    }
                }
                HStack {
                    Text("Your Week").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).padding(8) }
                        .accessibilityLabel("Close")
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .statusBarHidden()
    }

    private func make(_ r: WeekRecap?) -> [Slide] {
        let range: String
        if let r {
            let end = r.end.addingTimeInterval(-1)
            range = "\(r.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        } else {
            range = ""
        }
        guard let r, r.trackedMinutes > 0 else {
            return [Slide(id: 0, colors: [.indigo, .purple], symbol: "sparkles", kicker: "Your Week", big: "Not yet",
                          line: "Track a few days and your week shows up here.")]
        }
        var out: [Slide] = []
        func add(_ colors: [Color], _ symbol: String, _ kicker: String, _ big: String, unit: String? = nil, line: String? = nil,
                 rows: [(String, String, Double, Color)] = []) {
            out.append(Slide(id: out.count, colors: colors, symbol: symbol, kicker: kicker, big: big, unit: unit, line: line, rows: rows))
        }
        add([.indigo, .purple, .pink], "sparkles", "Your Week", range, line: "Here's how the last seven days went.")
        add([.blue, .teal], "checkmark.circle.fill", "You tracked", hours(r.trackedMinutes), unit: "hours",
            line: "of your waking time. Your average day score was \(r.averageScore).")
        if !r.top.isEmpty {
            let most = Double(max(1, r.top.first?.minutes ?? 1))
            add([.orange, .pink], "chart.bar.fill", "Where it went", r.top[0].name,
                line: "took the most time: \(durationLabel(r.top[0].minutes)).",
                rows: r.top.map { ($0.name, durationLabel($0.minutes), Double($0.minutes) / most,
                                   Theme.color(category: $0.id, tree: model.state.categories)) })
        }
        var work = "on your tasks."
        if let u = r.usualWorkMinutes, u > 0 {
            let d = r.workMinutes - u
            work = abs(d) < 15 ? "About the same as your usual week." : "\(durationLabel(abs(d))) \(d > 0 ? "more" : "less") than your usual week."
        }
        if r.deadlinesDue > 0 { work += " \(r.deadlinesMet) of \(r.deadlinesDue) deadlines met." }
        add([.green, .mint], "pencil.line", "You worked", hours(r.workMinutes), unit: "hours", line: work)
        if let day = r.bestDay, let score = r.bestScore {
            add([.yellow, .orange], "trophy.fill", "Your best day", day.formatted(.dateTime.weekday(.wide)),
                line: "A day score of \(score).")
        }
        var scroll = r.topApp.map { "Most of it on \($0.name) (\(durationLabel($0.minutes)))." } ?? ""
        if let u = r.usualScrollingMinutes, u > 0 {
            let d = r.scrollingMinutes - u
            scroll = (abs(d) < 15 ? "About your usual. " : "\(durationLabel(abs(d))) \(d < 0 ? "less" : "more") than usual. ") + scroll
        }
        add([.pink, .red], "hourglass", "Scrolling", hours(r.scrollingMinutes), unit: "hours", line: scroll.isEmpty ? nil : scroll)
        if let s = r.sleepPerNight {
            add([.indigo, .blue], "moon.stars.fill", "You slept", durationLabel(s), line: "a night, on average.")
        }
        if let m = r.mood {
            let face = MoodButtons.faces.min { abs(Double($0.0) - m) < abs(Double($1.0) - m) }?.1 ?? "🙂"
            add([.teal, .cyan], "face.smiling", "You felt", face, line: String(format: "%.1f out of 5 on average.", m))
        }
        if let note = model.state.review {
            add([.purple, .indigo], "text.quote", "This week's note", note.headline,
                line: (note.wins + note.suggestions).prefix(3).joined(separator: "\n"))
        }
        add([.indigo, .purple, .pink], "hand.wave.fill", "That's your week", "See you next week",
            line: "Review has every number, any day.")
        return out
    }

    private func hours(_ m: Int) -> String {
        m < 60 ? "\(m) min" : String(format: m % 60 == 0 ? "%.0f" : "%.1f", Double(m) / 60)
    }
}

private struct SlideView: View {
    let slide: RecapView.Slide
    let last: Bool
    let close: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            LinearGradient(colors: slide.colors, startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                Image(systemName: slide.symbol).font(.system(size: 44, weight: .semibold))
                Text(slide.kicker.uppercased()).font(.headline).opacity(0.85)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(slide.big).font(.system(size: slide.big.count > 14 ? 40 : 64, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.5).lineLimit(3)
                    if let u = slide.unit { Text(u).font(.title2.weight(.bold)).opacity(0.85) }
                }
                if let l = slide.line { Text(l).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true) }
                if !slide.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(slide.rows.enumerated()), id: \.offset) { _, r in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(r.0).font(.headline); Spacer(); Text(r.1).font(.subheadline.monospacedDigit()) }
                                GeometryReader { g in
                                    Capsule().fill(.white.opacity(0.25)).overlay(alignment: .leading) {
                                        Capsule().fill(.white).frame(width: max(6, g.size.width * (shown ? r.2 : 0)))
                                    }
                                }
                                .frame(height: 8)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                Spacer()
                if last {
                    Button(action: close) { Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent).tint(.white.opacity(0.25))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28).padding(.vertical, 90)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 24)
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shown = true } }
        .onDisappear { shown = false }
        .accessibilityElement(children: .combine)
    }
}
