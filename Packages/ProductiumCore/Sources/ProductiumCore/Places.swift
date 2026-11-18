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
    public static func offer(after markers: [TimelineEvent], places: [SavedPlace], commitments: [Commitment],
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
