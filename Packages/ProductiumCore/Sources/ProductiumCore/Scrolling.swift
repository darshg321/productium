import Foundation

// MARK: - Scroll sessions that end when you actually stop
//
// Free builds can't read Screen Time or see the lock screen, so sessions come from Shortcuts
// automations: "App is opened" starts one, and several signals can end it. "App is closed" only
// fires reliably when switching apps from the app switcher, not on Home or lock, so a session can
// also end because:
//   - another app opened (a scrolling one starts its own session; a non-scrolling one just ends it),
//   - the charger connected, an alarm stopped, or a Sleep/Work/Driving Focus came on,
//   - Productium came to the foreground or one of its intents ran,
//   - the "still scrolling?" check-in was answered No, or wasn't answered at all.
// A session with no observed end is never assumed to have kept running: it's credited the typical
// length of this student's sessions for that app, marked estimated. A Screen Time screenshot for a
// day is the truth; comparing it with the Shortcuts count gives a per-app correction factor that's
// applied to days without one.

public struct ScrollSession: Codable, Hashable, Identifiable, Sendable {
    public enum EndSource: String, Codable, Sendable {
        /// "App is closed" fired.
        case closed
        /// Another app opened.
        case otherApp
        /// Productium came forward or one of its intents ran.
        case productium
        /// The check-in was answered "No, I stopped".
        case checkIn
        /// The check-in wasn't answered.
        case checkInIgnored
        /// Charger, alarm, or a Focus turning on: the phone was probably put down.
        case lockProxy
        /// Nothing ended it; credited the typical length.
        case estimated

        /// True when the end was seen happen (so its length teaches the typical session).
        public var observed: Bool { [.closed, .otherApp, .productium, .lockProxy].contains(self) }
    }

    public var id: UUID
    public var app: String
    public var openedAt: Date
    public var endedAt: Date?
    public var endSource: EndSource?
    /// The latest moment the student said they were still scrolling.
    public var confirmedUntil: Date?
    /// When the "still scrolling?" check-in went out, if one is waiting for an answer.
    public var checkInAt: Date?

    public init(id: UUID = UUID(), app: String, openedAt: Date, endedAt: Date? = nil, endSource: EndSource? = nil,
                confirmedUntil: Date? = nil, checkInAt: Date? = nil) {
        self.id = id
        self.app = app
        self.openedAt = openedAt
        self.endedAt = endedAt
        self.endSource = endSource
        self.confirmedUntil = confirmedUntil
        self.checkInAt = checkInAt
    }

    public var isOpen: Bool { endedAt == nil }
    /// Minutes credited (nil while open).
    public var minutes: Int? { endedAt.map { max(0, Int(($0.timeIntervalSince(openedAt) / 60).rounded())) } }
    /// Not seen to end: drawn hatched and labelled "estimated".
    public var isEstimated: Bool { !(endSource?.observed ?? true) && endSource != .checkIn }
}

public struct ScrollLog: Codable, Hashable, Sendable {
    public struct Day: Codable, Hashable, Sendable {
        public var day: Date
        public var opens: Int
        public var pauses: Int
        public init(day: Date, opens: Int = 0, pauses: Int = 0) { self.day = day; self.opens = opens; self.pauses = pauses }
    }

    /// Every session, oldest first. Kept (the export holds them all).
    public var sessions: [ScrollSession]
    public var days: [Day]
    /// Set once any end has been observed: until then, minutes aren't measured, only opens.
    public var measuresClosing: Bool
    /// app → how much Shortcuts over-counts it compared with Screen Time screenshots (1.4 = 40% more).
    public var overCount: [String: Double]

    public init(sessions: [ScrollSession] = [], days: [Day] = [], measuresClosing: Bool = false, overCount: [String: Double] = [:]) {
        self.sessions = sessions
        self.days = days
        self.measuresClosing = measuresClosing
        self.overCount = overCount
    }

    /// Without enough observed sessions, a session with no end is credited this.
    public static let priorMinutes = 8
    /// Never credit more than this for a session nobody saw end.
    public static let estimateCap = 30
    /// A check-in left this long without an answer counts as "stopped".
    public static let answerWindow: TimeInterval = 10 * 60
    /// Whatever happens, no session is longer than this.
    public static let hardCap = 4 * 60

    public var open: ScrollSession? { sessions.last.flatMap { $0.isOpen ? $0 : nil } }

    static func norm(_ app: String) -> String { app.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Median length of this app's sessions that were seen to end (prior 8 min), capped at 30.
    public func typicalMinutes(_ app: String) -> Int {
        let a = Self.norm(app)
        let seen = sessions.filter { Self.norm($0.app) == a && ($0.endSource?.observed ?? false) }.compactMap(\.minutes).sorted()
        guard seen.count >= 3 else { return Self.priorMinutes }
        let mid = seen.count / 2
        let m = seen.count % 2 == 1 ? seen[mid] : (seen[mid - 1] + seen[mid]) / 2
        return max(1, min(Self.estimateCap, m))
    }

    private mutating func end(_ i: Int, at t: Date, _ source: ScrollSession.EndSource) {
        let s = sessions[i]
        sessions[i].endedAt = min(max(t, s.openedAt), s.openedAt.addingTimeInterval(Double(Self.hardCap) * 60))
        sessions[i].endSource = source
        sessions[i].checkInAt = nil
        if source.observed { measuresClosing = true }
    }

    /// Where an unconfirmed session most likely ended: the later of the last "yes, still scrolling"
    /// and open + the typical length, never after `limit`.
    private func estimatedEnd(_ s: ScrollSession, limit: Date) -> Date {
        let typical = s.openedAt.addingTimeInterval(Double(typicalMinutes(s.app)) * 60)
        return min(limit, max(s.confirmedUntil ?? s.openedAt, typical))
    }

    /// Ends what has to be ended by now: an unanswered check-in, or a session nobody could still be
    /// in. Call before reading minutes.
    public mutating func resolve(now: Date) {
        guard let i = sessions.indices.last, sessions[i].isOpen else { return }
        let s = sessions[i]
        if let c = s.checkInAt, now.timeIntervalSince(c) >= Self.answerWindow {
            end(i, at: estimatedEnd(s, limit: c), .checkInIgnored)
            return
        }
        // No signal at all for well past the typical length (plus any confirmation): estimate it.
        let quietSince = max(s.confirmedUntil ?? s.openedAt, s.checkInAt ?? s.openedAt)
        if now.timeIntervalSince(quietSince) > Double(Self.estimateCap + 30) * 60 {
            end(i, at: estimatedEnd(s, limit: now), .estimated)
        }
    }

    /// A scrolling app opened. Opening a different one ends the current session at that moment.
    public mutating func opened(_ app: String, at now: Date, paused: Bool, calendar cal: Calendar) {
        resolve(now: now)
        if let i = sessions.indices.last, sessions[i].isOpen {
            if Self.norm(sessions[i].app) == Self.norm(app) {
                bump(cal.startOfDay(for: now)) { $0.opens += 1; if paused { $0.pauses += 1 } }
                return
            }
            end(i, at: now, .otherApp)
        }
        sessions.append(ScrollSession(app: app, openedAt: now))
        bump(cal.startOfDay(for: now)) { $0.opens += 1; if paused { $0.pauses += 1 } }
    }

    /// "App is closed" (for `app`, or whichever is open). Returns the minutes credited.
    @discardableResult
    public mutating func closed(_ app: String? = nil, at now: Date) -> Int {
        resolve(now: now)
        measuresClosing = true
        guard let i = sessions.indices.last, sessions[i].isOpen,
              app.map({ Self.norm($0) == Self.norm(sessions[i].app) }) ?? true else { return 0 }
        end(i, at: now, .closed)
        return sessions[i].minutes ?? 0
    }

    /// Any other end signal: a non-scrolling app, the charger, an alarm, a Focus, Productium itself.
    @discardableResult
    public mutating func ended(by source: ScrollSession.EndSource, at now: Date) -> Int? {
        resolve(now: now)
        guard let i = sessions.indices.last, sessions[i].isOpen else { return nil }
        end(i, at: now, source)
        return sessions[i].minutes
    }

    /// The "still scrolling?" check-in went out.
    public mutating func checkInSent(at now: Date) {
        resolve(now: now)
        guard let i = sessions.indices.last, sessions[i].isOpen else { return }
        sessions[i].checkInAt = now
    }

    /// Yes: still at it (the next check-in is scheduled by the caller). No: it ends at the later
    /// of the last confirmation and the typical length. Returns whether a session is still open.
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

    // MARK: Minutes

    /// Minutes per app on `day` from finished sessions, as counted (no correction).
    public func rawMinutes(on day: Date, calendar cal: Calendar) -> [String: Int] {
        var out: [String: Int] = [:]
        for s in sessions where !s.isOpen && cal.isDate(s.openedAt, inSameDayAs: day) {
            out[s.app, default: 0] += s.minutes ?? 0
        }
        return out
    }

    /// Minutes per app on `day`, corrected by what screenshots taught.
    public func minutes(on day: Date, calendar cal: Calendar) -> [String: Int] {
        rawMinutes(on: day, calendar: cal).reduce(into: [:]) { out, kv in
            let f = overCount.first { Self.norm($0.key) == Self.norm(kv.key) }?.value ?? 1
            out[kv.key] = Int((Double(kv.value) / f).rounded())
        }
    }

    public func today(_ now: Date, calendar cal: Calendar) -> Day? {
        days.first { cal.isDate($0.day, inSameDayAs: now) }
    }

    /// Finished days as ScreenDays (source "shortcuts"), only once an end has ever been observed.
    public func screenDays(before now: Date, calendar cal: Calendar) -> [ScreenDay] {
        guard measuresClosing else { return [] }
        let today = cal.startOfDay(for: now)
        let dayStarts = Set(days.map { cal.startOfDay(for: $0.day) } + sessions.map { cal.startOfDay(for: $0.openedAt) })
        return dayStarts.filter { $0 < today }.sorted().map { d in
            let apps = minutes(on: d, calendar: cal)
            return ScreenDay(day: d, distractingMinutes: apps.values.reduce(0, +),
                             unlockRequests: days.first { cal.isDate($0.day, inSameDayAs: d) }?.opens ?? 0,
                             apps: apps.isEmpty ? nil : apps.sorted { $0.key < $1.key }.map { AppUsage(name: $0.key, minutes: $0.value, distracting: true) },
                             source: "shortcuts")
        }
    }

    /// Learns how much Shortcuts over-counts each app from days that also have a screenshot (the
    /// truth): the median ratio, bounded 0.3-3, from at least one day.
    public mutating func calibrate(with screenshots: [ScreenDay], calendar cal: Calendar) {
        var ratios: [String: [Double]] = [:]
        for shot in screenshots where shot.source == "screenshot" {
            let counted = rawMinutes(on: shot.day, calendar: cal)
            for app in shot.apps ?? [] where app.minutes >= 5 {
                guard let (name, c) = counted.first(where: { Self.norm($0.key) == Self.norm(app.name) }), c >= 5 else { continue }
                ratios[name, default: []].append(Double(c) / Double(app.minutes))
            }
        }
        for (app, rs) in ratios {
            let sorted = rs.sorted()
            let med = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            overCount[app] = (max(0.3, min(3, med)) * 100).rounded() / 100
        }
    }

    /// "Shortcuts over-counts Instagram ~1.4×", for What Productium Thinks.
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
