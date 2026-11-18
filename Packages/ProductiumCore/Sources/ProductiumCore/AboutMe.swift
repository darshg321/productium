import Foundation

public enum AboutMeSection: String, CaseIterable, Codable, Sendable {
    case stated = "Stated", inferred = "Inferred", patterns = "Patterns", preferences = "Preferences"

    public init?(loose: String) {
        let l = loose.lowercased().filter(\.isLetter)
        guard let s = AboutMeSection.allCases.first(where: { l.hasPrefix($0.rawValue.lowercased()) }) else { return nil }
        self = s
    }
}

public struct AboutMeFact: Codable, Hashable, Sendable {
    public var section: String?
    public var text: String
    public var replaces: String?

    public init(section: String? = nil, text: String, replaces: String? = nil) {
        self.section = section
        self.text = text
        self.replaces = replaces
    }
}

public struct AboutMe: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        public var text: String
        public var byStudent: Bool
        public init(_ text: String, byStudent: Bool = false) { self.text = text; self.byStudent = byStudent }
    }

    public static let studentMark = "(you)"
    public static let title = "# About me"

    public var sections: [AboutMeSection: [Line]]
    public var other: [String]

    public init(sections: [AboutMeSection: [Line]] = [:], other: [String] = []) {
        self.sections = sections
        self.other = other
    }

    public static let empty = AboutMe()

    public subscript(_ s: AboutMeSection) -> [Line] {
        get { sections[s] ?? [] }
        set { sections[s] = newValue }
    }

    public var isEmpty: Bool { AboutMeSection.allCases.allSatisfy { self[$0].isEmpty } && other.isEmpty }

    public static func parse(_ md: String) -> AboutMe {
        var me = AboutMe()
        var current: AboutMeSection?
        var unknownSection = false
        for raw in md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                current = AboutMeSection(loose: String(line.dropFirst(3)))
                unknownSection = current == nil
                if unknownSection { me.other.append(raw) }
                continue
            }
            if line.hasPrefix("# ") || line.isEmpty { if unknownSection && !line.isEmpty { me.other.append(raw) }; continue }
            guard let sec = current, !unknownSection else { me.other.append(raw); continue }
            var text = line
            if text.hasPrefix("- ") || text.hasPrefix("* ") { text = String(text.dropFirst(2)) }
            text = text.trimmingCharacters(in: .whitespaces)
            var mine = false
            if text.hasSuffix(studentMark) {
                mine = true
                text = String(text.dropLast(studentMark.count)).trimmingCharacters(in: .whitespaces)
            }
            guard !text.isEmpty else { continue }
            me[sec].append(Line(text, byStudent: mine))
        }
        return me
    }

    public var markdown: String {
        var out = [AboutMe.title, ""]
        for s in AboutMeSection.allCases {
            out.append("## \(s.rawValue)")
            for l in self[s] { out.append("- \(l.text)" + (l.byStudent ? " \(AboutMe.studentMark)" : "")) }
            out.append("")
        }
        if !other.isEmpty { out += other + [""] }
        return out.joined(separator: "\n")
    }

    public var promptText: String {
        let body = AboutMeSection.allCases.compactMap { s -> String? in
            let lines = self[s]
            guard !lines.isEmpty else { return nil }
            return "\(s.rawValue): " + lines.map(\.text).joined(separator: "; ")
        }
        return body.isEmpty ? "About the student: nothing yet" : "About the student (about-me.md):\n" + body.joined(separator: "\n")
    }

    @discardableResult
    public mutating func apply(_ f: AboutMeFact, by writer: AboutMeWriter, now: Date? = nil) -> Result<String, AboutMeRefusal> {
        let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return .failure(.empty) }
        let section = f.section.flatMap(AboutMeSection.init(loose:)) ?? .stated
        guard writer.mayWrite(section) else { return .failure(.notAllowed(section)) }
        var line = String(text.prefix(300))
        if line.hasSuffix(AboutMe.studentMark) && writer != .student {
            line = String(line.dropLast(AboutMe.studentMark.count)).trimmingCharacters(in: .whitespaces)
        }
        if AboutMeSection.allCases.contains(where: { self[$0].contains { $0.text.plainKey == line.plainKey } }) {
            return .success("Already known: \(line)")
        }
        if let old = f.replaces?.plainKey, !old.isEmpty {
            for s in AboutMeSection.allCases {
                guard let i = self[s].firstIndex(where: { $0.text.plainKey == old }) else { continue }
                if self[s][i].byStudent && writer != .student { return .failure(.studentLine) }
                guard writer.mayWrite(s) else { return .failure(.notAllowed(s)) }
                self[s].remove(at: i)
                break
            }
        }
        self[section].append(Line(line, byStudent: writer == .student))
        return .success("Noted: \(line)")
    }

    public static func studentEdited(old: String, new: String) -> AboutMe {
        let before = AboutMe.parse(old)
        var after = AboutMe.parse(new)
        var known: [String: Bool] = [:]
        for s in AboutMeSection.allCases { for l in before[s] { known[l.text.plainKey] = l.byStudent } }
        for s in AboutMeSection.allCases {
            after[s] = after[s].map { l in
                var l = l
                if let was = known[l.text.plainKey] { l.byStudent = l.byStudent || was } else { l.byStudent = true }
                return l
            }
        }
        return after
    }
}

public enum AboutMeRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    case empty, notAllowed(AboutMeSection), studentLine

    public var description: String {
        switch self {
        case .empty: return "an empty line"
        case .notAllowed(let s): return "only the weekly insight pass may write \(s.rawValue) lines"
        case .studentLine: return "that line is yours, so it wasn't changed"
        }
    }
}
