import SwiftUI
import ProductiumCore

/// Productium's visual language. The subject is a student's day measured in time,
/// so the characteristic element is the day drawn to scale: flat colour bars whose
/// length *is* their duration. Everything else stays quiet. One family (SF), with
/// width as the voice: expanded for the few things that matter, regular for the rest.
///
/// Palette, five named colours, each meaning one thing:
///   cobalt   #2340F5  focus work (and the only accent)
///   daylight #F5A623  free time
///   night    #1A2350  sleep
///   fog      #E4E6EB  fixed time: school, travel, routines, meals (dark: #2C2E35)
///   signal   #E5482D  something actually needs attention
enum Theme {
    static let cobalt = Color(red: 0x23 / 255, green: 0x40 / 255, blue: 0xF5 / 255)
    static let daylight = Color(red: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255)
    static let night = Color(red: 0x1A / 255, green: 0x23 / 255, blue: 0x50 / 255)
    static let fog = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x2C / 255, green: 0x2E / 255, blue: 0x35 / 255, alpha: 1)
        : UIColor(red: 0xE4 / 255, green: 0xE6 / 255, blue: 0xEB / 255, alpha: 1) })
    static let signal = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x2D / 255)
    static let accent = cobalt

    /// Fields and bars: barely rounded. Shape comes from proportion, not corners.
    static let radius: CGFloat = 3

    static func color(for kind: BlockKind) -> Color {
        switch kind {
        case .work, .review: return cobalt
        case .free, .gap, .breakTime: return daylight
        case .sleep, .windDown: return night
        case .commitment, .event, .meal, .routine: return fog
        }
    }

    static func color(for c: TimeCategory) -> Color {
        switch c {
        case .sleep: return night
        case .study: return cobalt
        case .free: return daylight
        case .screen: return signal
        case .school, .activities, .commute, .routine: return fog
        }
    }

    static func symbol(for kind: BlockKind) -> String {
        switch kind {
        case .work: return "pencil.line"
        case .review: return "brain.head.profile"
        case .breakTime: return "cup.and.saucer"
        case .free, .gap: return "sun.max"
        case .commitment: return "building.2"
        case .event: return "calendar"
        case .meal: return "fork.knife"
        case .routine: return "figure.walk"
        case .windDown, .sleep: return "moon"
        }
    }
}

extension Font {
    /// Display voice: SF expanded. Used for at most one or two things per screen.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
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

/// A plain text button in the accent colour: the default action style.
struct TextAction: View {
    let title: String
    var color: Color = Theme.cobalt
    let action: () -> Void
    init(_ title: String, color: Color = Theme.cobalt, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }
    var body: some View {
        Button(action: action) { Text(title).font(.body.weight(.semibold)).foregroundStyle(color) }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
    }
}

/// The one filled button style: a flat cobalt slab, nearly square-cornered.
struct SlabButtonStyle: ButtonStyle {
    var color: Color = Theme.cobalt
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Plain notice line (replaces floating toasts): sits at the bottom, no capsule, no shadow.
struct Notice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.cobalt).frame(width: 3) }
    }
}
