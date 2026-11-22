import Foundation

public struct ScrollSession: Codable, Hashable, Identifiable, Sendable {
    public enum EndSource: String, Codable, Sendable {
        case closed
        case otherApp
        case productium
        case checkIn
        case checkInIgnored
        case lockProxy
        case estimated

        public var observed: Bool { [.closed, .otherApp, .productium, .lockProxy].contains(self) }
    }

    public var id: UUID
    public var app: String
    public var openedAt: Date
    public var endedAt: Date?
    public var endSource: EndSource?
    public var confirmedUntil: Date?
    public var checkInAt: Date?
    /// False for an app logged by the "Opened an App" automation that isn't on your scrolling list. Nil (older
    /// sessions, the pause automation) is a scrolling app.
    public var scrolling: Bool?

    public init(id: UUID = UUID(), app: String, openedAt: Date, endedAt: Date? = nil, endSource: EndSource? = nil,
                confirmedUntil: Date? = nil, checkInAt: Date? = nil, scrolling: Bool? = nil) {
        self.id = id
        self.app = app
        self.openedAt = openedAt
        self.endedAt = endedAt
        self.endSource = endSource
        self.confirmedUntil = confirmedUntil
        self.checkInAt = checkInAt
        self.scrolling = scrolling
    }

    public var isOpen: Bool { endedAt == nil }
    public var minutes: Int? { endedAt.map { max(0, Int(($0.timeIntervalSince(openedAt) / 60).rounded())) } }
    public var isEstimated: Bool { !(endSource?.observed ?? true) && endSource != .checkIn }
    public var isScrolling: Bool { scrolling ?? true }
}

public struct ScrollLog: Codable, Hashable, Sendable {
    public struct Day: Codable, Hashable, Sendable {
        public var day: Date
        public var opens: Int
        public var pauses: Int
        public init(day: Date, opens: Int = 0, pauses: Int = 0) { self.day = day; self.opens = opens; self.pauses = pauses }
    }

    public var sessions: [ScrollSession]
    public var days: [Day]
    public var measuresClosing: Bool
    public var overCount: [String: Double]

    public init(sessions: [ScrollSession] = [], days: [Day] = [], measuresClosing: Bool = false, overCount: [String: Double] = [:]) {
        self.sessions = sessions
        self.days = days
        self.measuresClosing = measuresClosing
        self.overCount = overCount
    }

    public static let priorMinutes = 8
    public static let estimateCap = 30
    public static let answerWindow: TimeInterval = 10 * 60
    public static let hardCap = 4 * 60

    public var open: ScrollSession? { sessions.last.flatMap { $0.isOpen ? $0 : nil } }

    public func typicalMinutes(_ app: String) -> Int {
        let seen = sessions.filter { $0.app.plainKey == app.plainKey && ($0.endSource?.observed ?? false) }.compactMap(\.minutes)
        guard seen.count >= 3, let m = seen.median else { return Self.priorMinutes }
        return max(1, min(Self.estimateCap, m))
    }

    private mutating func end(_ i: Int, at t: Date, _ source: ScrollSession.EndSource) {
        let s = sessions[i]
        sessions[i].endedAt = min(max(t, s.openedAt), s.openedAt.addingTimeInterval(Double(Self.hardCap) * 60))
        sessions[i].endSource = source
        sessions[i].checkInAt = nil
        if source.observed { measuresClosing = true }
    }

    private func estimatedEnd(_ s: ScrollSession, limit: Date) -> Date {
        let typical = s.openedAt.addingTimeInterval(Double(typicalMinutes(s.app)) * 60)
        return min(limit, max(s.confirmedUntil ?? s.openedAt, typical))
    }

    public mutating func resolve(now: Date) {
        guard let i = sessions.indices.last, sessions[i].isOpen else { return }
        let s = sessions[i]
        if let c = s.checkInAt, now.timeIntervalSince(c) >= Self.answerWindow {
            end(i, at: estimatedEnd(s, limit: c), .checkInIgnored)
            return
        }
        let quietSince = max(s.confirmedUntil ?? s.openedAt, s.checkInAt ?? s.openedAt)
        if now.timeIntervalSince(quietSince) > Double(Self.estimateCap + 30) * 60 {
            end(i, at: estimatedEnd(s, limit: now), .estimated)
        }
    }

    public mutating func opened(_ app: String, at now: Date, paused: Bool, calendar cal: Calendar) {
        resolve(now: now)
        if let i = sessions.indices.last, sessions[i].isOpen {
            if sessions[i].app.plainKey == app.plainKey {
                bump(cal.startOfDay(for: now)) { $0.opens += 1; if paused { $0.pauses += 1 } }
                return
            }
            end(i, at: now, .otherApp)
        }
        sessions.append(ScrollSession(app: app, openedAt: now))
        bump(cal.startOfDay(for: now)) { $0.opens += 1; if paused { $0.pauses += 1 } }
    }

    /// The "Opened an App" automation (any app): ends what was open and starts this app's session. The pause
    /// automation may report the same opening a moment apart, so a repeat within `repeatWindow` is the same one.
    public mutating func seen(_ app: String, at now: Date, scrolling: Bool) {
        resolve(now: now)
        if let i = sessions.indices.last, sessions[i].isOpen {
            if sessions[i].app.plainKey == app.plainKey {
                if now.timeIntervalSince(sessions[i].openedAt) <= Self.repeatWindow || sessions[i].scrolling == nil { return }
            }
            end(i, at: now, .otherApp)
        }
        sessions.append(ScrollSession(app: app, openedAt: now, scrolling: scrolling))
    }

    public static let repeatWindow: TimeInterval = 15

    /// Sessions are kept 35 days; each finished day is already in `AppState.screen` by then.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-35 * 86400)
        sessions.removeAll { $0.openedAt < cutoff && !$0.isOpen }
        days.removeAll { $0.day < cutoff }
    }

    @discardableResult
    public mutating func closed(_ app: String? = nil, at now: Date) -> Int {
        resolve(now: now)
        measuresClosing = true
        guard let i = sessions.indices.last, sessions[i].isOpen,
              app.map({ $0.plainKey == sessions[i].app.plainKey }) ?? true else { return 0 }
        end(i, at: now, .closed)
        return sessions[i].minutes ?? 0
    }

    @discardableResult
    public mutating func ended(by source: ScrollSession.EndSource, at now: Date) -> Int? {
        resolve(now: now)
        guard let i = sessions.indices.last, sessions[i].isOpen else { return nil }
        end(i, at: now, source)
        return sessions[i].minutes
    }

    public mutating func checkInSent(at now: Date) {
        resolve(now: now)
        guard let i = sessions.indices.last, sessions[i].isOpen else { return }
        sessions[i].checkInAt = now
    }

    @discardableResult
    public mutating func checkInAnswered(stillScrolling: Bool, at now: Date) -> Bool {
        guard let i = sessions.indices.last, sessions[i].isOpen else { return false }
        if stillScrolling {
            sessions[i].confirmedUntil = now
            sessions[i].checkInAt = nil
            return true
        }
        end(i, at: estimatedEnd(sessions[i], limit: now), .checkIn)
        return false
    }

    public func rawMinutes(on day: Date, calendar cal: Calendar) -> [String: Int] {
        var out: [String: Int] = [:]
        for s in sessions where !s.isOpen && cal.isDate(s.openedAt, inSameDayAs: day) {
            out[s.app, default: 0] += s.minutes ?? 0
        }
        return out
    }

    public func minutes(on day: Date, calendar cal: Calendar) -> [String: Int] {
        rawMinutes(on: day, calendar: cal).reduce(into: [:]) { out, kv in
            let f = overCount.first { $0.key.plainKey == kv.key.plainKey }?.value ?? 1
            out[kv.key] = Int((Double(kv.value) / f).rounded())
        }
    }

    public func today(_ now: Date, calendar cal: Calendar) -> Day? {
        days.first { cal.isDate($0.day, inSameDayAs: now) }
    }

    public func screenDays(before now: Date, calendar cal: Calendar) -> [ScreenDay] {
        guard measuresClosing else { return [] }
        let today = cal.startOfDay(for: now)
        let dayStarts = Set(days.map { cal.startOfDay(for: $0.day) } + sessions.map { cal.startOfDay(for: $0.openedAt) })
        return dayStarts.filter { $0 < today }.sorted().map { d in
            let apps = minutes(on: d, calendar: cal)
            let scrollingApps = Set(sessions.filter { $0.isScrolling && cal.isDate($0.openedAt, inSameDayAs: d) }.map(\.app))
            let everyApp = sessions.contains { !$0.isScrolling && cal.isDate($0.openedAt, inSameDayAs: d) }
            return ScreenDay(day: d, distractingMinutes: apps.filter { scrollingApps.contains($0.key) }.values.reduce(0, +),
                             unlockRequests: days.first { cal.isDate($0.day, inSameDayAs: d) }?.opens ?? 0,
                             totalMinutes: everyApp ? apps.values.reduce(0, +) : nil,
                             apps: apps.isEmpty ? nil : apps.sorted { $0.key < $1.key }.map {
                                 AppUsage(name: $0.key, minutes: $0.value, distracting: scrollingApps.contains($0.key))
                             },
                             source: "shortcuts")
        }
    }

    public mutating func calibrate(with screenshots: [ScreenDay], calendar cal: Calendar) {
        var ratios: [String: [Double]] = [:]
        for shot in screenshots where shot.source == "screenshot" {
            let counted = rawMinutes(on: shot.day, calendar: cal)
            for app in shot.apps ?? [] where app.minutes >= 5 {
                guard let (name, c) = counted.first(where: { $0.key.plainKey == app.name.plainKey }), c >= 5 else { continue }
                ratios[name, default: []].append(Double(c) / Double(app.minutes))
            }
        }
        for (app, rs) in ratios {
            overCount[app] = (max(0.3, min(3, percentile(rs, 0.5))) * 100).rounded() / 100
        }
    }

    public var calibrationNotes: [String] {
        overCount.sorted { $0.key < $1.key }.compactMap { app, f in
            guard abs(f - 1) >= 0.1 else { return nil }
            return f > 1 ? "Shortcuts over-counts \(app) ~\(String(format: "%.1f", f))×"
                : "Shortcuts under-counts \(app) (it sees ~\(Int((f * 100).rounded()))% of the time)"
        }
    }

    private mutating func bump(_ day: Date, _ f: (inout Day) -> Void) {
        if let i = days.firstIndex(where: { $0.day == day }) { f(&days[i]) } else {
            var d = Day(day: day)
            f(&d)
            days.append(d)
        }
    }
}
