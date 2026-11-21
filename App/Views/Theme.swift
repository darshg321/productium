import SwiftUI
import ProductiumCore

enum Theme {
    // Category colours come from `CategoryPalette` (core, J1): their lightness differs enough to tell apart in grayscale.
    // Each category also has a symbol and a word wherever it's shown, and inferred time is hatched, never only paler.
    static let focus = Color.blue
    static let free = Color.yellow
    static let sleep = Color.indigo
    static let fixed = Color.gray
    static let screen = Color.teal
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

    static func named(_ s: String?) -> Color? {
        guard let s = Palette.normalise(s) else { return nil }
        switch s {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray": return Color(.systemGray)
        default:
            guard s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
            return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
        }
    }

    static func color(for block: PlannedBlock) -> Color { named(block.color) ?? color(for: block.kind) }

    static func color(for item: WorkItem, in state: AppState) -> Color {
        let parent = item.parentId.flatMap { id in state.items.first { $0.id == id } }
        return named(Palette.color(for: item, parent: parent, colors: state.prefs.colors)) ?? color(for: item.kind)
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
        case .breakdown: return .purple
        case .review: return .teal
        case .taxonomy: return .orange
        }
    }

    static func symbol(for f: AIFeature) -> String {
        switch f {
        case .box: return "tray.and.arrow.down.fill"
        case .breakdown: return "list.bullet.indent"
        case .review: return "sparkles"
        case .taxonomy: return "square.stack.3d.up"
        }
    }

    /// A category's colour (its node's palette name; Untracked is a neutral fill).
    static func color(category id: CategoryID, tree: CategoryTree) -> Color {
        if id == CategoryTree.untracked { return Color(.systemGray4) }
        return named(tree.node(id)?.colour ?? tree.path(id).first?.colour) ?? Color(.systemGray)
    }

    static func color(group g: CategoryGroup?) -> Color { g.flatMap { named($0.colour) } ?? Color(.systemGray4) }

    static func symbol(category id: CategoryID, tree: CategoryTree) -> String {
        id == CategoryTree.untracked ? "questionmark.circle" : (tree.node(id)?.symbol ?? "circle")
    }

    static func meter(_ fraction: Double) -> Color {
        fraction >= 1 ? .red : fraction >= 0.8 ? .orange : .green
    }
}

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

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

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

/// Confetti drawn with `Canvas`, no dependency. Reduce Motion gets nothing here (the banner fades in instead).
struct ConfettiView: View {
    private struct Piece { var x: Double; var speed: Double; var size: Double; var hue: Double; var spin: Double; var phase: Double }
    @State private var start = Date()
    private let pieces: [Piece] = (0..<70).map { i in
        var g = SystemRandomNumberGenerator()
        _ = i
        return Piece(x: Double.random(in: 0...1, using: &g), speed: Double.random(in: 0.25...0.6, using: &g),
                     size: Double.random(in: 5...9, using: &g), hue: Double.random(in: 0...1, using: &g),
                     spin: Double.random(in: -4...4, using: &g), phase: Double.random(in: 0...0.4, using: &g))
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            Canvas { ctx, size in
                guard t < 3.5 else { return }
                for p in pieces {
                    let life = t - p.phase
                    guard life > 0 else { continue }
                    let y = life * p.speed * size.height * 0.5 - 20
                    let x = p.x * size.width + sin(life * 3 + p.spin) * 18
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(life * p.spin))
                    c.opacity = max(0, 1 - life / 3.5)
                    c.fill(Path(CGRect(x: 0, y: 0, width: p.size, height: p.size * 0.5)), with: .color(Color(hue: p.hue, saturation: 0.7, brightness: 0.95)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A celebration that says what happened (from data). A symbol and words, so it reads the same in grayscale;
/// no motion beyond the slide-in, so Reduce Motion needs nothing special.
struct RewardBanner: View {
    let moment: RewardMoment
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: moment.kind == .milestone || moment.kind == .personalBest ? "trophy.fill" : "checkmark.seal.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(moment.title).font(.headline)
                if let d = moment.detail { Text(d).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

func durationLabel(_ m: Int) -> String {
    let h = m / 60, r = m % 60
    if h == 0 { return "\(r) min" }
    return r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
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

struct UsageToolbar: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var showUsage = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showUsage = true } label: { TokenMeter() }
                        .accessibilityLabel("AI usage today: \(tokensLabel(model.tokensToday)) output tokens")
                }
            }
            .sheet(isPresented: $showUsage) { UsageView() }
    }
}

extension View {
    func usageMeter() -> some View { modifier(UsageToolbar()) }
}

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
