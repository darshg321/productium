import Foundation

// MARK: - about-me.md: what the app knows about the student, in their words
//
// One markdown file on the device with four sections the AI keeps tidy. The student can edit it
// in Settings → About You, and their edits always win: a line they wrote or changed ends in
// "(you)" and no AI write ever replaces or removes it.
//
//   ## Stated       things the student said (the box may append here)
//   ## Inferred     "… — evidence: …, confidence: med, since 2026-11-17" (reflection only)
//   ## Patterns     behaviour, e.g. "puts off university essays: deferred 3× this week" (reflection only)
//   ## Preferences  how they like things (the student, or reflection)

public enum AboutMeSection: String, CaseIterable, Codable, Sendable {
    case stated = "Stated", inferred = "Inferred", patterns = "Patterns", preferences = "Preferences"

    public init?(loose: String) {
        let l = loose.lowercased().filter(\.isLetter)
        guard let s = AboutMeSection.allCases.first(where: { l.hasPrefix($0.rawValue.lowercased()) }) else { return nil }
        self = s
    }
}

/// Who is writing. The box (Sonnet) may only append what the student literally said; the
/// reflection job (Opus) may also write inferences and patterns; the student may write anything.
public enum AboutMeWriter: String, Codable, Sendable {
    case student, box, reflection

    public func mayWrite(_ s: AboutMeSection) -> Bool {
        switch self {
        case .student: return true
        case .box: return s == .stated
        case .reflection: return s != .stated
        }
    }
}

/// One new or changed line, as the AI proposes it.
public struct AboutMeFact: Codable, Hashable, Sendable {
    public var section: String?
    public var text: String
    /// The existing line this one replaces (its text, without the "- ").
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
        /// Written or changed by the student: never overwritten.
        public var byStudent: Bool
        public init(_ text: String, byStudent: Bool = false) { self.text = text; self.byStudent = byStudent }
    }

    public static let studentMark = "(you)"
    public static let title = "# About me"

    public var sections: [AboutMeSection: [Line]]
    /// Anything above the first section or in a section the app doesn't know, kept as written.
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

    // MARK: Markdown

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

    /// The file as the AI sees it (inside the user turn, so the system prompt never changes).
    public var promptText: String {
        let body = AboutMeSection.allCases.compactMap { s -> String? in
            let lines = self[s]
            guard !lines.isEmpty else { return nil }
            return "\(s.rawValue): " + lines.map(\.text).joined(separator: "; ")
        }
        return body.isEmpty ? "About the student: nothing yet" : "About the student (about-me.md):\n" + body.joined(separator: "\n")
    }

    // MARK: Changes

    static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Applies an AI's line. Returns a receipt line, or the reason it was refused.
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
        // Already there, in any section: nothing to do.
        if AboutMeSection.allCases.contains(where: { self[$0].contains { AboutMe.norm($0.text) == AboutMe.norm(line) } }) {
            return .success("Already known: \(line)")
        }
        if let old = f.replaces.map(AboutMe.norm), !old.isEmpty {
            for s in AboutMeSection.allCases {
                guard let i = self[s].firstIndex(where: { AboutMe.norm($0.text) == old }) else { continue }
                if self[s][i].byStudent && writer != .student { return .failure(.studentLine) }
                guard writer.mayWrite(s) else { return .failure(.notAllowed(s)) }
                self[s].remove(at: i)
                break
            }
        }
        self[section].append(Line(line, byStudent: writer == .student))
        return .success("Noted: \(line)")
    }

    /// The student saved the editor: every line they added or changed (compared with what the
    /// file said before) is marked as theirs. Lines that were theirs stay theirs.
    public static func studentEdited(old: String, new: String) -> AboutMe {
        let before = AboutMe.parse(old)
        var after = AboutMe.parse(new)
        var known: [String: Bool] = [:]
        for s in AboutMeSection.allCases { for l in before[s] { known[norm(l.text)] = l.byStudent } }
        for s in AboutMeSection.allCases {
            after[s] = after[s].map { l in
                var l = l
                if let was = known[norm(l.text)] { l.byStudent = l.byStudent || was } else { l.byStudent = true }
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
        case .notAllowed(let s): return "only the weekly reflection may write \(s.rawValue) lines"
        case .studentLine: return "that line is yours, so it wasn't changed"
        }
    }
}
