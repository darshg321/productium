import Foundation

extension String {
    /// Lowercased letters and digits only: "Estimate Minutes", "estimate_minutes" and "estimateMinutes" match.
    public var plainKey: String { lowercased().filter { $0.isLetter || $0.isNumber } }
}

extension DateFormatter {
    public static func local(_ format: String, _ cal: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}

public func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    let r = p * Double(s.count - 1)
    let lo = Int(r.rounded(.down)), hi = Int(r.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
}

extension Array where Element == Int {
    /// The middle value (the lower-rounded mean of the two middle ones for an even count).
    public var median: Int? {
        guard !isEmpty else { return nil }
        let s = sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
