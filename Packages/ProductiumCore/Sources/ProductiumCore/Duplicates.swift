import Foundation

/// Decides when two things on the calendar are the same thing written twice.
public enum EventMatch {
    static let filler: Set<String> = ["the", "a", "an", "and", "with", "meeting", "class", "period", "club"]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    static func isPeriodTag(_ w: String) -> Bool { w.count <= 3 && w.first == "p" && w.dropFirst().allSatisfy(\.isNumber) && w.count > 1 }

    /// "Math (P1)" and "P1 Math" match; so do two titles that share their one real word.
    public static func similarTitles(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let strip: (Set<String>) -> Set<String> = { $0.filter { !isPeriodTag($0) && !filler.contains($0) } }
        let sx = strip(x), sy = strip(y)
        guard !sx.isEmpty, !sy.isEmpty else { return false }
        if sx.isSubset(of: sy) || sy.isSubset(of: sx) { return true }
        return !sx.intersection(sy).isEmpty && Double(sx.intersection(sy).count) / Double(min(sx.count, sy.count)) >= 0.5
    }

    /// The overlap as a share of the shorter one.
    public static func overlap(_ a: (Date, Date), _ b: (Date, Date)) -> Double {
        let shorter = min(a.1.timeIntervalSince(a.0), b.1.timeIntervalSince(b.0))
        guard shorter > 0 else { return 0 }
        let both = min(a.1, b.1).timeIntervalSince(max(a.0, b.0))
        return max(0, both) / shorter
    }

}
