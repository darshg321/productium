import Foundation

// v1.1 J1: the colours that tell time categories apart. Each is an iOS system colour; its sRGB value in light and dark
// mode is written here so a test can check that categories drawn next to each other differ in lightness (they have to
// stay apart in grayscale). Colour is never the only cue: every category also has a symbol and a word, and inferred
// time is hatched (App `Hatch`).

public enum CategoryPalette {
    public struct RGB: Hashable, Sendable {
        public var r: Double, g: Double, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

        /// WCAG relative luminance.
        public var luminance: Double {
            func lin(_ c: Double) -> Double { let x = c / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
    }

    public static let light: [String: RGB] = [
        "blue": RGB(0, 122, 255), "indigo": RGB(88, 86, 214), "purple": RGB(175, 82, 222), "orange": RGB(255, 149, 0),
        "gray": RGB(142, 142, 147), "red": RGB(255, 59, 48), "green": RGB(52, 199, 89), "teal": RGB(48, 176, 199),
        "pink": RGB(255, 45, 85), "yellow": RGB(255, 204, 0),
    ]
    public static let dark: [String: RGB] = [
        "blue": RGB(10, 132, 255), "indigo": RGB(94, 92, 230), "purple": RGB(191, 90, 242), "orange": RGB(255, 159, 10),
        "gray": RGB(152, 152, 157), "red": RGB(255, 69, 58), "green": RGB(48, 209, 88), "teal": RGB(64, 200, 224),
        "pink": RGB(255, 55, 95), "yellow": RGB(255, 214, 10),
    ]

    /// The system colour each category uses. `Theme` must use the same ones.
    public static func name(_ c: TimeCategory) -> String {
        switch c {
        case .sleep: return "indigo"
        case .study: return "blue"
        case .free: return "yellow"
        case .screen: return "teal"
        case .school, .activities, .commute, .routine: return "gray"
        }
    }

    /// The symbol that goes with each category wherever its colour is shown.
    public static func symbol(_ c: TimeCategory) -> String {
        switch c {
        case .sleep: return "moon.fill"
        case .study: return "pencil.line"
        case .free: return "sun.max"
        case .screen: return "hourglass"
        case .school: return "building.2"
        case .activities: return "figure.run"
        case .commute: return "figure.walk"
        case .routine: return "checklist"
        }
    }

    /// Contrast ratio of two colours' luminance (1 = identical, 21 = black on white).
    public static func contrast(_ a: String, _ b: String, dark isDark: Bool) -> Double? {
        let table = isDark ? dark : light
        guard let x = table[a]?.luminance, let y = table[b]?.luminance else { return nil }
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Categories that sit next to each other in a strip or timeline.
    public static let shown: [TimeCategory] = [.sleep, .study, .free, .screen, .school]
    public static let minContrast = 1.2
}
