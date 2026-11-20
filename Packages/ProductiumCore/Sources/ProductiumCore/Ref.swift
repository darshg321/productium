import Foundation

public enum Ref {
    public static func task(_ id: UUID) -> String { "t" + short(id.uuidString) }
    public static func activity(_ id: UUID) -> String { "a" + short(id.uuidString) }
    public static func event(_ id: String) -> String { "e" + short(id) }
    public static func dayChange(_ id: UUID) -> String { "d" + short(id.uuidString) }
    public static func situation(_ id: UUID) -> String { "s" + short(id.uuidString) }
    public static func alarm(_ id: UUID) -> String { "r" + short(id.uuidString) }
    public static func reminder(_ id: UUID) -> String { "n" + short(id.uuidString) }

    static func short(_ s: String) -> String {
        if UUID(uuidString: s) != nil { return String(s.lowercased().filter(\.isHexDigit).prefix(6)) }
        // FNV-1a: `hashValue` changes every launch.
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(String(h, radix: 16).prefix(6))
    }

    static func matches(_ ref: String, prefix: Character, full: String) -> Bool {
        let r = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !r.isEmpty else { return false }
        if r == full.lowercased() { return true }
        let mine = short(full)
        if r == "\(prefix)\(mine)" { return true }
        let bare = r.first == prefix ? String(r.dropFirst()) : r
        return bare.count >= 4 && bare.allSatisfy(\.isHexDigit) && mine.hasPrefix(bare)
    }
}

/// Free-text clock times ("6:45", "7pm").
public enum ClockText {
    public static func timeOfDay(_ v: String?) -> TimeOfDay? {
        guard var v = v?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return nil }
        let pm = v.hasSuffix("pm"), am = v.hasSuffix("am")
        if pm || am { v = String(v.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        let p = v.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard var h = p.first, (0...23).contains(h) else { return nil }
        if pm && h < 12 { h += 12 }
        if am && h == 12 { h = 0 }
        let m = p.count > 1 ? p[1] : 0
        guard (0...59).contains(m) else { return nil }
        return TimeOfDay(h, m)
    }
}
