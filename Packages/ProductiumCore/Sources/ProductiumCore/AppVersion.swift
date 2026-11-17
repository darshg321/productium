import Foundation

public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "v1.0.3", "1.0.3" or "1.0": missing parts are zero; anything else is nil.
    public init?(_ tag: String) {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("v") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), !parts.contains(where: { $0 == nil }) else { return nil }
        let n = parts.compactMap { $0 }
        guard !n.contains(where: { $0 < 0 }) else { return nil }
        self.init(n[0], n.count > 1 ? n[1] : 0, n.count > 2 ? n[2] : 0)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "v\(major).\(minor).\(patch)" }
}

public struct ReleaseInfo: Codable, Hashable, Sendable {
    public var tag: String
    public var url: String
    public var checkedAt: Date

    public init(tag: String, url: String, checkedAt: Date) {
        self.tag = tag
        self.url = url
        self.checkedAt = checkedAt
    }

    /// The latest release when it's newer than what's installed.
    public func update(over installed: String) -> AppVersion? {
        guard let latest = AppVersion(tag), let mine = AppVersion(installed), latest > mine else { return nil }
        return latest
    }

    /// GitHub's releases API; public, no token, and nothing about the user is sent.
    public static func parse(_ json: Data, now: Date) -> ReleaseInfo? {
        struct Raw: Decodable { var tag_name: String; var html_url: String }
        guard let r = try? JSONDecoder().decode(Raw.self, from: json), AppVersion(r.tag_name) != nil else { return nil }
        return ReleaseInfo(tag: r.tag_name, url: r.html_url, checkedAt: now)
    }

    public static func isDue(last: Date?, now: Date) -> Bool {
        last.map { now.timeIntervalSince($0) >= 24 * 3600 } ?? true
    }
}
