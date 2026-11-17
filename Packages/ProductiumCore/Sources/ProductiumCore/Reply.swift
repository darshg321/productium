import Foundation

public struct AIResponse: Decodable, Sendable {
    public struct Block: Sendable {
        public var type: String
        public var text: String?
        public var input: JSONValue?
    }
    public struct Usage: Codable, Hashable, Sendable {
        public var input_tokens: Int?
        public var output_tokens: Int?
        public var cache_creation_input_tokens: Int?
        public var cache_read_input_tokens: Int?
    }

    public var id: String?
    public var model: String?
    public var content: [Block]
    public var stop_reason: String?
    public var usage: Usage?
    public var rawContent: JSONValue?

    public init(model: String?, text: String, usage: Usage?, stopReason: String? = nil) {
        self.model = model
        self.content = [Block(type: "text", text: text, input: nil)]
        self.rawContent = .array([.object(["type": .string("text"), "text": .string(text)])])
        self.usage = usage
        self.stop_reason = stopReason
    }

    enum CodingKeys: String, CodingKey { case id, model, content, stop_reason, usage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        stop_reason = try? c.decodeIfPresent(String.self, forKey: .stop_reason)
        usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
        rawContent = (try? c.decodeIfPresent(JSONValue.self, forKey: .content)) ?? nil
        switch rawContent {
        case .array(let blocks)?:
            content = blocks.compactMap { b in
                switch b {
                case .string(let s): return Block(type: "text", text: s, input: nil)
                case .object(let o):
                    var type = "text", text: String?
                    if case .string(let t)? = o["type"] { type = t }
                    if case .string(let t)? = o["text"] { text = t }
                    return Block(type: type, text: text, input: o["input"])
                default: return nil
                }
            }
        case .string(let s)?: content = [Block(type: "text", text: s, input: nil)]
        case .object(let o)?: content = [Block(type: "tool_use", text: nil, input: .object(o))]
        default: content = []
        }
    }

    public var text: String { content.filter { $0.type == "text" }.compactMap(\.text).joined() }

    public var isTruncated: Bool { stop_reason == "max_tokens" }

    var candidates: [JSONValue] {
        content.compactMap { b -> JSONValue? in
            guard b.type == "tool_use", let input = b.input else { return nil }
            if case .object(let o) = input, o.isEmpty { return nil }
            return input
        } + [StructuredRepair.parse(text)].compactMap { $0 }
    }

    public var structured: JSONValue? { candidates.first }

    public func structured(for schema: JSONValue) -> JSONValue? {
        candidates.first.map { StructuredRepair.coerce($0, to: schema) }
    }

    public func decoded<T: Decodable>(_ type: T.Type, schema: JSONValue, accept: (T) -> Bool = { _ in true }) -> T? {
        for c in candidates {
            if let v = try? StructuredRepair.coerce(c, to: schema).decode(T.self), accept(v) { return v }
        }
        return nil
    }

    public var tokens: TokenCount {
        TokenCount(input: usage?.input_tokens ?? 0, output: usage?.output_tokens ?? 0,
                   cacheRead: usage?.cache_read_input_tokens ?? 0, cacheWrite: usage?.cache_creation_input_tokens ?? 0)
    }
}

struct LooseJSON {
    enum Context { case key, objectValue, arrayItem }

    let c: [Character]
    var i: Int
    var cut = false

    static let quotes: [Character: [Character]] = [
        "\"": ["\""], "'": ["'"], "“": ["”", "“", "\""], "”": ["”", "\""], "‘": ["’", "'"], "`": ["`"],
    ]
    static let maxDepth = 48

    init(_ chars: [Character], at start: Int) { c = chars; i = start }

    mutating func skipSpace() {
        while i < c.count {
            if c[i].isWhitespace { i += 1 }
            else if c[i] == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, !c[i].isNewline { i += 1 }
            } else if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i < c.count, !(c[i] == "*" && i + 1 < c.count && c[i + 1] == "/") { i += 1 }
                i = min(c.count, i + 2)
            } else { break }
        }
    }

    mutating func value(_ ctx: Context, depth: Int = 0) -> JSONValue? {
        skipSpace()
        guard i < c.count else { cut = true; return nil }
        if depth > Self.maxDepth { i = c.count; cut = true; return nil }
        if c[i] == "{" { return object(depth) }
        if c[i] == "[" { return array(depth) }
        if let closers = Self.quotes[c[i]] { return .string(string(closers, ctx)) }
        return bare()
    }

    mutating func object(_ depth: Int) -> JSONValue {
        i += 1
        var o: [String: JSONValue] = [:]
        while true {
            skipSpace()
            guard i < c.count else { cut = true; break }
            if c[i] == "}" { i += 1; break }
            if c[i] == "]" { break }
            if c[i] == "," { i += 1; continue }
            let key: String
            if let closers = Self.quotes[c[i]] { key = string(closers, .key) } else { key = bareKey() }
            skipSpace()
            guard i < c.count else { cut = true; break }
            guard c[i] == ":" || c[i] == "=" else { continue }
            i += 1
            guard let v = value(.objectValue, depth: depth + 1) else { break }
            o[key] = v
        }
        return .object(o)
    }

    mutating func array(_ depth: Int) -> JSONValue {
        i += 1
        var a: [JSONValue] = []
        while true {
            skipSpace()
            guard i < c.count else { cut = true; break }
            if c[i] == "]" { i += 1; break }
            if c[i] == "}" { break }
            if c[i] == "," || c[i] == ":" { i += 1; continue }
            guard let v = value(.arrayItem, depth: depth + 1) else { break }
            if cut { if case .string = v { a.append(v) }; break }
            a.append(v)
        }
        return .array(a)
    }

    mutating func bareKey() -> String {
        let start = i
        while i < c.count, !":=,}]".contains(c[i]), !c[i].isNewline { i += 1 }
        return String(c[start..<i]).trimmingCharacters(in: .whitespaces)
    }

    mutating func bare() -> JSONValue {
        let start = i
        while i < c.count, !",}]".contains(c[i]), !c[i].isNewline { i += 1 }
        let t = String(c[start..<i]).trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "": return .null
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null", "none", "nil", "undefined", "nan": return .null
        default:
            if let n = Double(t), n.isFinite { return .number(n) }
            return .string(t)
        }
    }

    mutating func string(_ closers: [Character], _ ctx: Context) -> String {
        i += 1
        var out = ""
        while i < c.count {
            let ch = c[i]
            if ch == "\\" {
                i += 1
                guard i < c.count else { break }
                switch c[i] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b", "f": break
                case "u":
                    if let s = unicodeEscape() { out.unicodeScalars.append(s) }
                default: out.append(c[i])
                }
                i += 1
                continue
            }
            if closers.contains(ch), closes(after: i + 1, ctx) { i += 1; return out }
            out.append(ch)
            i += 1
        }
        cut = true
        return out
    }

    mutating func unicodeEscape() -> Unicode.Scalar? {
        func hex(_ at: Int) -> UInt32? {
            guard at + 4 <= c.count else { return nil }
            return UInt32(String(c[at..<at + 4]), radix: 16)
        }
        guard let hi = hex(i + 1) else { return nil }
        i += 4
        if (0xD800..<0xDC00).contains(hi) {
            guard i + 2 < c.count, c[i + 1] == "\\", c[i + 2] == "u", let lo = hex(i + 3), (0xDC00..<0xE000).contains(lo) else { return nil }
            i += 6
            return Unicode.Scalar(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00))
        }
        return Unicode.Scalar(hi)
    }

    func next(from j: Int) -> Int {
        var j = j
        while j < c.count, c[j].isWhitespace { j += 1 }
        return j
    }

    func closes(after j: Int, _ ctx: Context) -> Bool {
        let j = next(from: j)
        guard j < c.count else { return true }
        switch ctx {
        case .key: return ":=,}".contains(c[j])
        case .arrayItem: return ",]}".contains(c[j])
        case .objectValue:
            if c[j] == "}" || c[j] == "]" { return true }
            if c[j] == "," { return keyAhead(j + 1) }
            return Self.quotes[c[j]] != nil && keyAhead(j)
        }
    }

    func keyAhead(_ j: Int) -> Bool {
        var j = next(from: j)
        guard j < c.count else { return true }
        if c[j] == "}" { return true }
        if let closers = Self.quotes[c[j]] {
            j += 1
            let limit = min(c.count, j + 80)
            while j < limit, !closers.contains(c[j]), !c[j].isNewline { j += 1 }
            guard j < limit, closers.contains(c[j]) else { return false }
            j = next(from: j + 1)
            return j >= c.count || c[j] == ":"
        }
        guard c[j].isLetter || c[j] == "_" else { return false }
        while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
        j = next(from: j)
        return j < c.count && c[j] == ":"
    }
}

public enum StructuredRepair {
    public static func parse(_ raw: String) -> JSONValue? { parse(raw, depth: 0) }

    static func parse(_ raw: String, depth: Int) -> JSONValue? {
        let t = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !t.isEmpty, depth < 4 else { return nil }
        if let v = decode(t) {
            switch v {
            case .object, .array: return v
            case .string(let inner): return parse(inner, depth: depth + 1)
            default: return nil
            }
        }
        let chars = Array(t)
        for open in ["{", "["] as [Character] {
            var best: (value: JSONValue, weight: Int)?
            var i = 0
            while i < chars.count {
                guard chars[i] == open else { i += 1; continue }
                var reader = LooseJSON(chars, at: i)
                if let v = reader.value(.arrayItem) {
                    let w = weight(v)
                    if w > (best?.weight ?? 0) { best = (v, w) }
                }
                i = max(reader.i, i + 1)
            }
            if let best { return best.value }
        }
        return nil
    }

    static func decode(_ s: String) -> JSONValue? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }

    static func weight(_ v: JSONValue) -> Int {
        switch v {
        case .object(let o): return o.reduce(0) { $0 + 1 + weight($1.value) }
        case .array(let a): return a.reduce(0) { $0 + weight($1) }
        case .null: return 0
        default: return 1
        }
    }

    public static func coerce(_ v: JSONValue, to schema: JSONValue) -> JSONValue {
        fit(v, schema, depth: 0) ?? empty(schema)
    }

    static func type(of schema: JSONValue) -> (type: String, schema: [String: JSONValue])? {
        guard case .object(let sc) = schema, case .string(let type)? = sc["type"] else { return nil }
        return (type, sc)
    }

    static func empty(_ schema: JSONValue) -> JSONValue {
        guard let (type, sc) = type(of: schema) else { return .null }
        switch type {
        case "string": return .string("")
        case "integer", "number": return .number(0)
        case "boolean": return .bool(false)
        case "array": return .array([])
        case "object":
            guard case .object(let props)? = sc["properties"] else { return .object([:]) }
            return .object(Dictionary(uniqueKeysWithValues: required(sc).compactMap { k in props[k].map { (k, empty($0)) } }))
        default: return .null
        }
    }

    static func required(_ sc: [String: JSONValue]) -> [String] {
        guard case .array(let r)? = sc["required"] else { return [] }
        return r.compactMap { if case .string(let k) = $0 { return k }; return nil }
    }


    static func fit(_ v: JSONValue, _ schema: JSONValue, depth: Int) -> JSONValue? {
        guard let (type, sc) = type(of: schema) else { return v }
        guard depth < 24 else { return nil }
        switch type {
        case "object": return fitObject(v, schema, sc, depth: depth)
        case "array":
            let items = sc["items"]
            switch v {
            case .array(let a):
                guard let items else { return v }
                return .array(a.compactMap { $0 == .null ? nil : fit($0, items, depth: depth + 1) })
            case .string(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("[") || t.hasPrefix("{"), let parsed = parse(t) { return fit(parsed, schema, depth: depth + 1) }
                return fit(.array(splitList(s)), schema, depth: depth + 1)
            case .null: return nil
            default: return fit(.array([v]), schema, depth: depth + 1)
            }
        case "integer", "number":
            var n: Double
            switch v {
            case .number(let x): n = x
            case .string(let s): guard let x = number(in: s) else { return nil }; n = x
            case .array(let a) where a.count == 1: return fit(a[0], schema, depth: depth + 1)
            default: return nil
            }
            guard n.isFinite else { return nil }
            if type == "integer" { n = max(-1e9, min(1e9, n.rounded())) }
            return .number(n)
        case "boolean":
            switch v {
            case .bool: return v
            case .number(let n): return .bool(n != 0)
            case .string(let s):
                switch s.lowercased().trimmingCharacters(in: .whitespaces) {
                case "true", "yes", "y", "1": return .bool(true)
                case "false", "no", "n", "0": return .bool(false)
                default: return nil
                }
            default: return nil
            }
        case "string":
            switch v {
            case .string(let s):
                guard case .array(let options)? = sc["enum"], !options.contains(v) else { return v }
                let match = options.first { if case .string(let o) = $0 { return o.plainKey == s.plainKey }; return false }
                return match ?? v
            case .number(let n): return .string(n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n))
            case .bool(let b): return .string(b ? "true" : "false")
            case .array(let a):
                let parts = a.compactMap { fit($0, schema, depth: depth + 1) }.compactMap { p -> String? in
                    if case .string(let s) = p { return s }; return nil
                }
                return parts.isEmpty ? nil : .string(parts.joined(separator: " "))
            default: return nil
            }
        default:
            return v
        }
    }

    static func fitObject(_ v: JSONValue, _ schema: JSONValue, _ sc: [String: JSONValue], depth: Int) -> JSONValue? {
        guard case .object(let props)? = sc["properties"] else {
            if case .object = v { return v }
            return nil
        }
        let byPlain = Dictionary(props.keys.map { ($0.plainKey, $0) }, uniquingKeysWith: { a, _ in a })
        switch v {
        case .object(let raw):
            var o: [String: JSONValue] = [:]
            for (k, val) in raw {
                guard let name = props[k] != nil ? k : byPlain[k.plainKey] else { continue }
                if props[k] != nil || o[name] == nil { o[name] = val }
            }
            if o.isEmpty {
                let inner = raw.values.compactMap { val -> JSONValue? in
                    switch val {
                    case .object, .array: return holds(val, byPlain) ? fit(val, schema, depth: depth + 1) : nil
                    case .string(let s):
                        guard let p = parse(s), holds(p, byPlain) else { return nil }
                        return fit(p, schema, depth: depth + 1)
                    default: return nil
                    }
                }
                if let best = inner.max(by: { weight($0) < weight($1) }) { return best }
            }
            for (k, val) in o {
                if let ps = props[k], val != .null, let fitted = fit(val, ps, depth: depth + 1) { o[k] = fitted } else { o[k] = nil }
            }
            for k in required(sc) where o[k] == nil { if let ps = props[k] { o[k] = empty(ps) } }
            return .object(o)
        case .string(let s):
            guard let parsed = parse(s) else { return nil }
            return fit(parsed, schema, depth: depth + 1)
        case .array(let a):
            if a.count == 1, holds(a[0], byPlain) { return fit(a[0], schema, depth: depth + 1) }
            let lists = props.filter { StructuredRepair.type(of: $0.value)?.type == "array" }
            guard lists.count == 1, let (key, ls) = lists.first, let fitted = fit(v, ls, depth: depth + 1) else { return nil }
            var o: [String: JSONValue] = [key: fitted]
            for k in required(sc) where o[k] == nil { if let ps = props[k] { o[k] = empty(ps) } }
            return .object(o)
        default:
            return nil
        }
    }

    static func holds(_ v: JSONValue, _ byPlain: [String: String]) -> Bool {
        switch v {
        case .object(let o): return o.keys.contains { byPlain[$0.plainKey] != nil }
        case .array(let a): return a.count == 1 && holds(a[0], byPlain)
        default: return false
        }
    }

    static func number(in s: String) -> Double? {
        var t = Substring(s.trimmingCharacters(in: .whitespaces))
        while let f = t.first, "~≈+".contains(f) { t = t.dropFirst() }
        let digits = t.prefix { "0123456789.-".contains($0) }
        guard let n = Double(digits) else { return nil }
        let rest = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        return ["", "m", "min", "mins", "minute", "minutes", "%"].contains(rest) ? n : nil
    }

    static func splitList(_ s: String) -> [JSONValue] {
        s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { .string($0) }
    }
}
