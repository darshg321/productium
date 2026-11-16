import SwiftUI
import ProductiumCore

/// One accent colour, system type, lots of space. Few things on screen at once,
/// so the UI never adds to the load it's trying to reduce.
enum Theme {
    static let accent = Color.indigo

    static func color(for kind: BlockKind) -> Color {
        switch kind {
        case .work: return .indigo
        case .review: return .purple
        case .breakTime: return .mint
        case .free: return .green
        case .gap: return .teal
        case .commitment, .event: return .gray
        case .meal, .routine: return .orange.opacity(0.7)
        case .windDown, .sleep: return .blue.opacity(0.6)
        }
    }

    static func symbol(for kind: BlockKind) -> String {
        switch kind {
        case .work: return "pencil.line"
        case .review: return "brain.head.profile"
        case .breakTime: return "cup.and.saucer"
        case .free: return "sun.max"
        case .gap: return "sparkles"
        case .commitment: return "building.2"
        case .event: return "calendar"
        case .meal: return "fork.knife"
        case .routine: return "figure.walk"
        case .windDown: return "moon"
        case .sleep: return "bed.double"
        }
    }

    static func color(for c: TimeCategory) -> Color {
        switch c {
        case .sleep: return .blue.opacity(0.55)
        case .school: return .gray
        case .activities: return .orange
        case .study: return .indigo
        case .commute: return .brown.opacity(0.6)
        case .routine: return .yellow.opacity(0.7)
        case .screen: return .pink
        case .free: return .green.opacity(0.7)
        }
    }

    static let moodFaces = ["😣", "😕", "😐", "🙂", "😄"]
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            .padding(.horizontal, 24)
    }
}

extension Date {
    var hm: String { formatted(date: .omitted, time: .shortened) }
    var relativeDay: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInTomorrow(self) { return "Tomorrow" }
        if let d = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: self)).day, d < 7, d > 0 {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Five faces, one tap. Naming a feeling helps regulate it (affect labelling, Lieberman et al. 2007).
struct MoodPicker: View {
    var selected: Int?
    var onPick: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { m in
                Button { onPick(m) } label: {
                    Text(Theme.moodFaces[m - 1])
                        .font(.system(size: 30))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .opacity(selected == nil || selected == m ? 1 : 0.35)
                        .scaleEffect(selected == m ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["Awful", "Low", "Okay", "Good", "Great"][m - 1])
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }
}
