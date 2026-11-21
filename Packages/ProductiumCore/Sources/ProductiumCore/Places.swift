import Foundation

public struct PlaceVisit: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var arrival: Date
    public var departure: Date?

    public init(latitude: Double, longitude: Double, arrival: Date, departure: Date? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.arrival = arrival
        self.departure = departure
    }
}

/// A place the app could save, waiting for a yes. `needsName` offers come from repeat visits and ask what to call it.
public struct PlaceOffer: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var needsName: Bool
    public var latitude: Double?
    public var longitude: Double?
    public var reason: String

    public init(id: String, name: String, needsName: Bool = false, latitude: Double? = nil, longitude: Double? = nil, reason: String) {
        self.id = id
        self.name = name
        self.needsName = needsName
        self.latitude = latitude
        self.longitude = longitude
        self.reason = reason
    }
}

public enum PlaceSuggester {
    public static func slug(_ name: String) -> String {
        name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "_")
    }

    /// "At school", or the end of something that happens somewhere, with no saved place of that name.
    public static func offer(after markers: [CheckIn], places: [SavedPlace], commitments: [Commitment],
                             declined: Set<String>) -> PlaceOffer? {
        func missing(_ id: String) -> Bool {
            !places.contains { $0.id == id || slug($0.name) == id } && !declined.contains(id)
        }
        for m in markers {
            switch (m.activity, m.phase) {
            case ("to_school", .end), ("school", .start):
                if missing("school") { return PlaceOffer(id: "school", name: "School", reason: "You said you're at school.") }
            case ("from_school", .end):
                if missing("home") { return PlaceOffer(id: "home", name: "Home", reason: "You said you're home.") }
            case (_, .end):
                guard let c = commitments.first(where: { MarkerParser.normalise($0.title) == m.activity }),
                      c.kind != .school else { continue }
                let id = slug(c.title)
                if missing(id) { return PlaceOffer(id: id, name: c.title, reason: "You finished \(c.title).") }
            default: break
            }
        }
        return nil
    }

    public static func meters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let r = 6_371_000.0
        let p1 = aLat * .pi / 180, p2 = bLat * .pi / 180
        let dp = (bLat - aLat) * .pi / 180, dl = (bLon - aLon) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// A spot visited on `minVisits` different days for 20 minutes or more, not near a saved place or one already turned down.
    public static func frequent(_ visits: [PlaceVisit], places: [SavedPlace], declinedSpots: [(Double, Double)] = [],
                                minVisits: Int = 3, calendar cal: Calendar) -> PlaceOffer? {
        let stays = visits.filter { v in
            guard let d = v.departure else { return false }
            return d.timeIntervalSince(v.arrival) >= 20 * 60
        }
        var clusters: [(lat: Double, lon: Double, days: Set<Date>)] = []
        for v in stays {
            if places.contains(where: { meters($0.latitude, $0.longitude, v.latitude, v.longitude) <= max(150, $0.radius) }) { continue }
            if declinedSpots.contains(where: { meters($0.0, $0.1, v.latitude, v.longitude) <= 150 }) { continue }
            if let i = clusters.firstIndex(where: { meters($0.lat, $0.lon, v.latitude, v.longitude) <= 150 }) {
                clusters[i].days.insert(cal.startOfDay(for: v.arrival))
            } else {
                clusters.append((v.latitude, v.longitude, [cal.startOfDay(for: v.arrival)]))
            }
        }
        guard let best = clusters.filter({ $0.days.count >= minVisits }).max(by: { $0.days.count < $1.days.count }) else { return nil }
        return PlaceOffer(id: "visit_\(Int(best.lat * 1000))_\(Int(best.lon * 1000))", name: "", needsName: true,
                          latitude: best.lat, longitude: best.lon,
                          reason: "You've been here on \(best.days.count) different days. What's it called?")
    }
}

public enum PlaceTime {
    /// Minutes per day spent at saved or visited places away from home (school, practice, friends'). A visit still
    /// open counts up to `now`.
    public static func awayMinutes(visits: [PlaceVisit], home: SavedPlace?, now: Date, calendar cal: Calendar) -> [Date: Int] {
        var out: [Date: Double] = [:]
        for v in visits {
            if let h = home, distance(v.latitude, v.longitude, h.latitude, h.longitude) < max(100, h.radius) { continue }
            let end = min(v.departure ?? now, now)
            var day = cal.startOfDay(for: v.arrival)
            while day < end {
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                let s = max(v.arrival, day), e = min(end, next)
                if e > s { out[day, default: 0] += e.timeIntervalSince(s) / 60 }
                day = next
            }
        }
        return out.mapValues { Int($0.rounded()) }
    }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, p = Double.pi / 180
        let a = sin((lat2 - lat1) * p / 2) * sin((lat2 - lat1) * p / 2)
            + cos(lat1 * p) * cos(lat2 * p) * sin((lon2 - lon1) * p / 2) * sin((lon2 - lon1) * p / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}

// MARK: - v1.2 Part E: places that name themselves

/// A coarse point while moving (≤1 per 5 minutes), between visits.
public struct TracePoint: Codable, Hashable, Sendable {
    public var at: Date
    public var latitude: Double
    public var longitude: Double
    public var accuracy: Double
    public init(at: Date, latitude: Double, longitude: Double, accuracy: Double) {
        self.at = at
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }
}

/// E2: the location history, on the phone and in the backup, kept 180 days.
public struct LocationTrace: Codable, Hashable, Sendable {
    public var visits: [PlaceVisit] = []
    public var points: [TracePoint] = []
    public init() {}

    public static let keepDays = 180.0

    /// A visit arrives twice from iOS (arrival, then with its departure): the second replaces the first.
    public mutating func add(_ v: PlaceVisit) {
        if let i = visits.lastIndex(where: { abs($0.arrival.timeIntervalSince(v.arrival)) < 60 }) { visits[i] = v } else { visits.append(v) }
        visits.sort { $0.arrival < $1.arrival }
    }

    @discardableResult
    public mutating func add(_ p: TracePoint) -> Bool {
        if let last = points.last, p.at.timeIntervalSince(last.at) < 5 * 60 { return false }
        points.append(p)
        return true
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keepDays * 86400)
        visits.removeAll { ($0.departure ?? now) < cutoff }
        points.removeAll { $0.at < cutoff }
    }
}

public struct Place: Codable, Hashable, Identifiable, Sendable {
    public enum Naming: String, Codable, Sendable { case you, entries, map }
    public var id: UUID
    public var name: String?
    public var latitude: Double
    public var longitude: Double
    public var radius: Double
    public var named: Naming?
    /// Apple's point of interest nearby, if one was found ("Starbucks", "Lord Byng Secondary").
    public var poi: String?
    public var createdAt: Date
    /// Visits that made it (its centre is their running mean).
    public var visits: Int = 1

    public init(id: UUID = UUID(), name: String? = nil, latitude: Double, longitude: Double, radius: Double = 150,
                named: Naming? = nil, poi: String? = nil, createdAt: Date) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.named = named
        self.poi = poi
        self.createdAt = createdAt
    }

    public var ref: String { "p" + Ref.short(id.uuidString) }
    public var title: String { name ?? poi ?? "Unnamed place" }
}

/// E2: visits cluster into places (150 m). Names come from you (the box: "this is the library"), from what you
/// logged there, or from Apple's map data. A place keeps its visits when renamed: membership is geometric.
public struct PlaceBook: Codable, Hashable, Sendable {
    public var places: [Place] = []
    public init() {}

    public static let clusterMeters = 150.0
    /// Visits shorter than this are passing through, not a place.
    public static let minStay: TimeInterval = 10 * 60

    public func place(at lat: Double, _ lon: Double) -> Place? {
        places.filter { PlaceSuggester.meters($0.latitude, $0.longitude, lat, lon) <= max(Self.clusterMeters, $0.radius) }
            .min { PlaceSuggester.meters($0.latitude, $0.longitude, lat, lon) < PlaceSuggester.meters($1.latitude, $1.longitude, lat, lon) }
    }

    public func place(for v: PlaceVisit) -> Place? { place(at: v.latitude, v.longitude) }

    /// Makes places for visits that aren't near one yet (stays of ≥10 minutes), and moves each place's centre to the
    /// mean of its visits, so a place follows where you actually are. Call with new visits only. Returns the new places.
    @discardableResult
    public mutating func cluster(_ visits: [PlaceVisit], now: Date) -> [Place] {
        var made: [Place] = []
        for v in visits where (v.departure ?? now).timeIntervalSince(v.arrival) >= Self.minStay {
            if let p = place(for: v), let i = places.firstIndex(where: { $0.id == p.id }) {
                let n = Double(places[i].visits)
                places[i].latitude = (places[i].latitude * n + v.latitude) / (n + 1)
                places[i].longitude = (places[i].longitude * n + v.longitude) / (n + 1)
                places[i].visits += 1
            } else {
                let p = Place(latitude: v.latitude, longitude: v.longitude, createdAt: now)
                places.append(p)
                made.append(p)
            }
        }
        return made
    }

    /// You named it: always wins (the box, Settings, a place offer).
    public mutating func name(_ id: UUID, _ name: String) {
        guard let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].name = name.trimmingCharacters(in: .whitespaces)
        places[i].named = .you
    }

    public mutating func setPOI(_ id: UUID, _ poi: String) {
        guard let i = places.firstIndex(where: { $0.id == id }) else { return }
        places[i].poi = poi
        if places[i].named == nil { places[i].name = poi; places[i].named = .map }
    }

    /// Merges `b` into `a` (the same place found twice): entries on `b` move to `a`.
    public mutating func merge(_ a: UUID, _ b: UUID, entries: inout [Entry]) {
        guard a != b, places.contains(where: { $0.id == a }), let j = places.firstIndex(where: { $0.id == b }) else { return }
        let gone = places.remove(at: j)
        if let i = places.firstIndex(where: { $0.id == a }) {
            places[i].radius = max(places[i].radius, PlaceSuggester.meters(places[i].latitude, places[i].longitude, gone.latitude, gone.longitude))
            if places[i].name == nil { places[i].name = gone.name; places[i].named = gone.named }
        }
        for k in entries.indices where entries[k].placeId == b { entries[k].placeId = a }
    }

    public mutating func forget(_ id: UUID, entries: inout [Entry]) {
        places.removeAll { $0.id == id }
        for k in entries.indices where entries[k].placeId == id { entries[k].placeId = nil }
    }

    /// "You logged Volleyball here 6 times → Gym?": the leaf you logged most at an unnamed place (≥3 times, ≥60%).
    public func suggestedName(_ id: UUID, entries: [Entry], tree: CategoryTree) -> (name: String, count: Int)? {
        let here = entries.filter { $0.placeId == id && $0.repeats == nil && $0.source != .plan }
        guard here.count >= 3 else { return nil }
        let byCat = Dictionary(grouping: here, by: \.category)
        guard let top = byCat.max(by: { $0.value.count < $1.value.count }), Double(top.value.count) / Double(here.count) >= 0.6,
              top.value.count >= 3 else { return nil }
        let name = tree.node(top.key)?.name ?? top.value[0].title
        return (name, top.value.count)
    }

    /// Names unnamed places from what you did there (E2), when it's clear. Returns the places named.
    @discardableResult
    public mutating func nameFromEntries(_ entries: [Entry], tree: CategoryTree) -> [UUID] {
        var out: [UUID] = []
        for i in places.indices where places[i].named == nil || places[i].named == .map {
            guard let s = suggestedName(places[i].id, entries: entries, tree: tree) else { continue }
            if places[i].named == .map && places[i].poi != nil { continue }
            places[i].name = s.name
            places[i].named = .entries
            out.append(places[i].id)
        }
        return out
    }
}

extension EntryBuilder {
    /// E3: each one-off entry gets the place of the visit that covers most of it (a running one: the open visit).
    /// Entries with a place already keep it. Returns how many were set.
    @discardableResult
    public static func places(_ entries: inout [Entry], visits: [PlaceVisit], book: PlaceBook, since: Date, now: Date) -> Int {
        var n = 0
        let vs = visits.filter { ($0.departure ?? now) > since }
        for i in entries.indices where entries[i].placeId == nil && entries[i].repeats == nil && entries[i].source != .plan
            && (entries[i].end ?? now) > since {
            let s = entries[i].start, e = entries[i].end ?? now
            guard e > s else { continue }
            var best: (Place, TimeInterval)?
            for v in vs {
                let o = min(e, v.departure ?? now).timeIntervalSince(max(s, v.arrival))
                guard o > 0, let p = book.place(for: v) else { continue }
                if best == nil || o > best!.1 { best = (p, o) }
            }
            if let b = best, b.1 >= e.timeIntervalSince(s) * 0.5 {
                entries[i].placeId = b.0.id
                n += 1
            }
        }
        return n
    }
}

/// E4: Review → Where: minutes at each place over a range (from visits), and what you did there.
public struct WhereRow: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var minutes: Int
    /// Top categories there (from entries with that place), most first.
    public var top: [(CategoryID, Int)]

    public static func == (a: WhereRow, b: WhereRow) -> Bool { a.id == b.id && a.minutes == b.minutes && a.name == b.name }
    public func hash(into h: inout Hasher) { h.combine(id); h.combine(minutes) }
}

public enum Where {
    public static func rows(visits: [PlaceVisit], book: PlaceBook, entries: [Entry], range: DateInterval, now: Date) -> [WhereRow] {
        var minutes: [UUID: Double] = [:]
        for v in visits {
            guard let p = book.place(for: v) else { continue }
            let s = max(v.arrival, range.start), e = min(v.departure ?? now, range.end, now)
            if e > s { minutes[p.id, default: 0] += e.timeIntervalSince(s) / 60 }
        }
        return minutes.compactMap { id, m -> WhereRow? in
            guard let p = book.places.first(where: { $0.id == id }), m >= 1 else { return nil }
            var cats: [CategoryID: Int] = [:]
            for e in entries where e.placeId == id && e.repeats == nil {
                let s = max(e.start, range.start), en = min(e.end ?? now, range.end, now)
                if en > s { cats[e.category, default: 0] += Int(en.timeIntervalSince(s) / 60) }
            }
            return WhereRow(id: id, name: p.title, minutes: Int(m.rounded()), top: cats.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) })
        }.sorted { $0.minutes > $1.minutes }
    }

    /// E5: `locations.csv` (visits with their place).
    public static func csv(_ trace: LocationTrace, book: PlaceBook) -> String {
        let f = ISO8601DateFormatter()
        return Exporter.csv(["arrival", "departure", "minutes", "place", "latitude", "longitude"], trace.visits.map { v in
            let mins = v.departure.map { String(Int($0.timeIntervalSince(v.arrival) / 60)) } ?? ""
            return [f.string(from: v.arrival), v.departure.map { f.string(from: $0) } ?? "", mins, book.place(for: v)?.title ?? "",
                    String(format: "%.5f", v.latitude), String(format: "%.5f", v.longitude)]
        })
    }
}
