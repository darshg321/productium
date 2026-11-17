import Foundation

public struct Nudge: Codable, Hashable, Sendable {
    public var symbol: String
    public var text: String
}

public enum Wellbeing {
    public static func supportSuggested(moods: [MoodEntry], now: Date) -> Bool {
        let recent = moods.filter { now.timeIntervalSince($0.at) < 14 * 86400 }
        guard recent.count >= 4 else { return false }
        let mean = Double(recent.map(\.mood).reduce(0, +)) / Double(recent.count)
        let lows = recent.filter { $0.mood == 1 }.count
        return mean <= 2.0 || lows >= 4
    }

    public static func nudges(now: Date, todayMood: MoodEntry?, health: HealthDay?, screen: ScreenDay?,
                              screenLimit: Int?, calendar cal: Calendar) -> [Nudge] {
        var out: [Nudge] = []
        let hour = cal.component(.hour, from: now)
        if let steps = health?.steps, hour >= 15, steps < 4000 {
            out.append(Nudge(symbol: "figure.walk", text: "\(steps) steps so far. A 10-min walk before your next block helps focus."))
        }
        if let d = health?.daylightMinutes, hour >= 14, hour < 18, d < 20 {
            out.append(Nudge(symbol: "sun.max", text: "Little daylight today. 10 minutes outside helps you sleep on time tonight."))
        }
        if let m = todayMood, m.mood <= 2 {
            out.append(Nudge(symbol: "leaf", text: "Pick the smallest next step and do just 5 minutes of it."))
        }
        if let s = screen?.distractingMinutes, let l = screenLimit, s > l {
            out.append(Nudge(symbol: "hourglass", text: "Past today's limit. Tomorrow's a fresh day, no guilt."))
        }
        return Array(out.prefix(2))
    }

    public static func correlation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 7 else { return nil }
        let n = Double(pairs.count)
        let mx = pairs.map(\.0).reduce(0, +) / n, my = pairs.map(\.1).reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in pairs { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my) }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx.squareRoot() * syy.squareRoot())
    }

    public static let crisisText = "If things feel really heavy, talk to someone you trust. If you're in the US you can call or text 988 any time, or find your local line at findahelpline.com."
}
