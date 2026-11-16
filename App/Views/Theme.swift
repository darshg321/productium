import SwiftUI
import ProductiumCore

/// Productium looks like the system, in the way Health and Settings do: grouped
/// backgrounds, inset cards with a tinted category header and one big number, and
/// SF Symbols on coloured rounded squares for lists. All colours are system colours,
/// so dark mode, Increase Contrast and Liquid Glass come for free. Each means one thing:
///   blue    focus work          orange  free time
///   indigo  sleep               gray    fixed time (school, travel, routines, meals)
///   purple  screen time         red     something actually needs attention
enum Theme {
    static let focus = Color.blue
    static let free = Color.orange
    static let sleep = Color.indigo
    static let fixed = Color(.systemGray3)
    static let screen = Color.purple
    static let alert = Color.red

    static let background = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
    static let cardRadius: CGFloat = 16

    static func color(for kind: BlockKind) -> Color {
        switch kind {
        case .work, .review: return focus
        case .free, .gap, .breakTime: return free
        case .sleep, .windDown: return sleep
        case .commitment, .event, .meal, .routine: return fixed
        }
    }

    static func color(for c: TimeCategory) -> Color {
        switch c {
        case .sleep: return sleep
        case .study: return focus
        case .free: return free
        case .screen: return screen
        case .school, .activities, .commute, .routine: return fixed
        }
    }

    static func color(for kind: TaskKind) -> Color {
        switch kind {
        case .test: return .red
        case .quiz: return .pink
        case .assignment: return .blue
        case .project: return .purple
        case .essay: return .indigo
        case .application: return .green
        case .reading: return .brown
        case .practice: return .teal
        case .chore, .other: return .gray
        }
    }

    static func symbol(for kind: BlockKind) -> String {
        switch kind {
        case .work: return "pencil.line"
        case .review: return "brain.head.profile"
        case .breakTime: return "cup.and.saucer.fill"
        case .free, .gap: return "sun.max.fill"
        case .commitment: return "building.2.fill"
        case .event: return "calendar"
        case .meal: return "fork.knife"
        case .routine: return "figure.walk"
        case .windDown, .sleep: return "moon.fill"
        }
    }

    static func color(for f: AIFeature) -> Color {
        switch f {
        case .box: return .blue
        case .flashcards: return .orange
        case .reads: return .brown
        case .breakdown: return .purple
        case .review: return .teal
        }
    }

    static func symbol(for f: AIFeature) -> String {
        switch f {
        case .box: return "tray.and.arrow.down.fill"
        case .flashcards: return "rectangle.on.rectangle"
        case .reads: return "text.book.closed.fill"
        case .breakdown: return "list.bullet.indent"
        case .review: return "sparkles"
        }
    }

    /// Meter colour: calm until most of the day's budget is gone.
    static func meter(_ fraction: Double) -> Color {
        fraction >= 1 ? .red : fraction >= 0.8 ? .orange : .green
    }
}

// MARK: - Building blocks

/// The Settings-app icon: a white symbol on a coloured, continuous-corner square.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A Settings-style row label: icon tile, then the title.
struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconTile(symbol: symbol, color: color)
        }
    }
}

/// A Health-style card on the grouped background.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// The tinted category line at the top of a card: symbol and name in colour,
/// a quiet detail and (optionally) a chevron on the right.
struct CardHeader: View {
    let title: String
    let symbol: String
    let color: Color
    var detail: String?
    var chevron = false

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The one big number with its unit beside it, as Health shows a reading.
struct BigValue: View {
    let value: String
    var unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
            if let unit {
                Text(unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A bold section title between cards ("Schedule", "Highlights").
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Banner for short confirmations, above the tab bar.
struct Notice: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16)
    }
}

/// "1 hr 20 min", the way Health writes durations.
func durationLabel(_ m: Int) -> String {
    let h = m / 60, r = m % 60
    if h == 0 { return "\(r) min" }
    return r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
}

/// A duration as Health shows one: big numbers, small units ("7 hr 32 min").
struct DurationValue: View {
    let minutes: Int
    var body: some View {
        let h = minutes / 60, m = minutes % 60
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if h > 0 { part("\(h)", "hr") }
            if m > 0 || h == 0 { part("\(m)", "min") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(durationLabel(minutes))
    }

    private func part(_ v: String, _ u: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(v).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(u).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}

extension Date {
    var hm: String { formatted(date: .omitted, time: .shortened) }
    var relativeDay: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "today" }
        if cal.isDateInTomorrow(self) { return "tomorrow" }
        if let d = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: self)).day, d > 0, d < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A horizontal bar of the day, each block its own width: the app's one chart.
struct DayStrip: View {
    let blocks: [PlannedBlock]
    let start: Date
    let end: Date
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let span = max(60, end.timeIntervalSince(start))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                ForEach(blocks.filter { $0.end > start && $0.start < end && $0.kind != .breakTime }) { b in
                    let x = max(0, b.start.timeIntervalSince(start)) / span
                    let w = min(b.end, end).timeIntervalSince(max(b.start, start)) / span
                    Rectangle().fill(Theme.color(for: b.kind))
                        .frame(width: max(1, g.size.width * w))
                        .offset(x: g.size.width * x)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Toolbar button for the token meter, top right on every tab.
struct UsageToolbar: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var showUsage = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showUsage = true } label: { TokenMeter() }
                        .accessibilityLabel("AI usage today: \(tokensLabel(model.tokensToday)) tokens")
                }
            }
            .sheet(isPresented: $showUsage) { UsageView() }
    }
}

extension View {
    func usageMeter() -> some View { modifier(UsageToolbar()) }
}

/// A small ring that fills toward today's budget, with today's token count.
struct TokenMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let f = model.usageFraction
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
                Circle().trim(from: 0, to: min(1, max(0.001, f)))
                    .stroke(Theme.meter(f), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            Text(tokensLabel(model.tokensToday))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 2)
        .animation(.easeOut(duration: 0.3), value: f)
    }
}
