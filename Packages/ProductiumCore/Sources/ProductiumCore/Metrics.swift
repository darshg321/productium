import Foundation

// Life Metrics (v1.1 Part G): each metric is a daily series with a source; comparisons are like for like, a change
// inside the metric's normal day-to-day noise is "same", and a missing day is never a zero. No overall score.

public enum MetricID: String, Codable, CaseIterable, Sendable {
    case scrolling, screenTotal, pickups, firstPickup, scrollOpens, notifications
    case sleep, sleepRegularity, bedOnTime
    case focus, planDone, tasksDone
    case mood, energy, steps, daylight, exercise, outside, restingHeartRate

    /// The tiles shown until you choose your own (G.1).
    public static let defaultTiles: [MetricID] = [.scrolling, .pickups, .sleep, .focus, .mood, .steps]
}

public enum MetricUnit: String, Codable, Sendable { case minutes, count, percent, clock, rating, bpm }

public enum MetricBetter: Hashable, Sendable {
    case lower, higher
    /// Closer to the range is better; inside it, more isn't better (sleep).
    case inside(Double, Double)
}

public enum MetricAggregate: Sendable {
    /// The period's value is the mean of its days (per-day average, so a part-week compares fairly).
    case mean
    /// The period's value is how much its days vary (regularity). Has no single-day value.
    case spread
}

public struct MetricDef: Sendable {
    public var id: MetricID
    public var title: String
    public var symbol: String
    public var unit: MetricUnit
    public var better: MetricBetter
    /// The smallest change that counts as a change at all, in the metric's unit.
    public var noiseFloor: Double
    public var aggregate: MetricAggregate
    /// Builds up over the day (scrolling, focus, steps): today so far is not comparable with all of yesterday.
    public var cumulative: Bool
    /// Shown as a tile (false: detail only).
    public var headline: Bool

    public static func of(_ id: MetricID) -> MetricDef { all[id]! }

    public static let all: [MetricID: MetricDef] = {
        let defs: [MetricDef] = [
            .init(id: .scrolling, title: "Scrolling", symbol: "hourglass", unit: .minutes, better: .lower, noiseFloor: 10, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .screenTotal, title: "Screen Time", symbol: "iphone", unit: .minutes, better: .lower, noiseFloor: 15, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .pickups, title: "Pickups", symbol: "hand.raised", unit: .count, better: .lower, noiseFloor: 5, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .firstPickup, title: "First Pickup", symbol: "sunrise", unit: .clock, better: .higher, noiseFloor: 10, aggregate: .mean, cumulative: false, headline: true),
            .init(id: .scrollOpens, title: "Scrolling App Opens", symbol: "arrow.up.forward.app", unit: .count, better: .lower, noiseFloor: 2, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .notifications, title: "Notifications", symbol: "bell", unit: .count, better: .lower, noiseFloor: 10, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .sleep, title: "Sleep", symbol: "bed.double", unit: .minutes, better: .inside(480, 600), noiseFloor: 15, aggregate: .mean, cumulative: false, headline: true),
            .init(id: .sleepRegularity, title: "Sleep Regularity", symbol: "metronome", unit: .minutes, better: .lower, noiseFloor: 10, aggregate: .spread, cumulative: false, headline: true),
            .init(id: .bedOnTime, title: "In Bed on Time", symbol: "moon", unit: .percent, better: .higher, noiseFloor: 10, aggregate: .mean, cumulative: false, headline: true),
            .init(id: .focus, title: "Focus", symbol: "pencil.line", unit: .minutes, better: .higher, noiseFloor: 10, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .planDone, title: "Plan Done", symbol: "checklist", unit: .percent, better: .higher, noiseFloor: 5, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .tasksDone, title: "Tasks Finished", symbol: "checkmark.circle", unit: .count, better: .higher, noiseFloor: 0.5, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .mood, title: "Mood", symbol: "face.smiling", unit: .rating, better: .higher, noiseFloor: 0.3, aggregate: .mean, cumulative: false, headline: true),
            .init(id: .energy, title: "Energy", symbol: "bolt", unit: .rating, better: .higher, noiseFloor: 0.3, aggregate: .mean, cumulative: false, headline: true),
            .init(id: .steps, title: "Steps", symbol: "figure.walk", unit: .count, better: .higher, noiseFloor: 500, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .daylight, title: "Daylight", symbol: "sun.max", unit: .minutes, better: .higher, noiseFloor: 5, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .exercise, title: "Exercise", symbol: "figure.run", unit: .minutes, better: .higher, noiseFloor: 10, aggregate: .mean, cumulative: true, headline: false),
            .init(id: .outside, title: "Time Out", symbol: "door.left.hand.open", unit: .minutes, better: .higher, noiseFloor: 15, aggregate: .mean, cumulative: true, headline: true),
            .init(id: .restingHeartRate, title: "Resting Heart Rate", symbol: "heart", unit: .bpm, better: .lower, noiseFloor: 2, aggregate: .mean, cumulative: false, headline: false),
        ]
        return Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0) })
    }()

    /// The sleep range follows your sleep need (need − 1 h … need + 1 h), not a fixed number.
    public static func sleep(need: Int) -> MetricDef {
        var d = of(.sleep)
        d.better = .inside(Double(need - 60), Double(need + 60))
        return d
    }
}

public enum MetricSource: String, Codable, Sendable {
    case measured, screenshot, estimated, stated, average

    public var label: String {
        switch self {
        case .measured: return "measured"
        case .screenshot: return "from screenshots"
        case .estimated: return "estimated"
        case .stated: return "you logged"
        case .average: return "weekly average"
        }
    }
}

public struct MetricPoint: Hashable, Sendable {
    public var day: Date
    public var value: Double
    public var source: MetricSource
    public init(day: Date, value: Double, source: MetricSource) {
        self.day = day
        self.value = value
        self.source = source
    }
}

/// One metric's days. `soFar(day, cutoff)` gives a cumulative metric's value on `day` up to the same time of day
/// as `cutoff`, when the data allows it (focus sessions have times; a screenshot doesn't).
public struct MetricSeries {
    public var def: MetricDef
    public var points: [Date: MetricPoint]
    public var soFar: ((Date, Date) -> Double?)?

    public init(def: MetricDef, points: [MetricPoint], calendar cal: Calendar, soFar: ((Date, Date) -> Double?)? = nil) {
        self.def = def
        self.points = Dictionary(points.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { _, b in b })
        self.soFar = soFar
    }
}

public enum MetricPeriod: String, Codable, CaseIterable, Sendable { case day, week, month }

public enum MetricVerdict: String, Codable, Sendable {
    case better, worse, same, notEnoughData

    /// Shown with the arrow, so good / bad never depends on colour alone (J.1).
    public var word: String {
        switch self {
        case .better: return "better"
        case .worse: return "worse"
        case .same: return "same"
        case .notEnoughData: return "Not enough data"
        }
    }

    public var symbol: String {
        switch self {
        case .better: return "checkmark.circle.fill"
        case .worse: return "exclamationmark.circle.fill"
        case .same: return "equal.circle"
        case .notEnoughData: return "questionmark.circle"
        }
    }
}

public enum MetricArrow: String, Codable, Sendable { case up, down, flat, none }

public struct MetricComparison: Sendable {
    public var id: MetricID
    public var period: MetricPeriod
    public var current: Double?
    public var previous: Double?
    public var change: Double?
    public var band: Double
    public var verdict: MetricVerdict
    public var arrow: MetricArrow
    public var currentDays: Int
    public var previousDays: Int
    public var sources: [MetricSource]
    /// Why there's no arrow, or what the comparison covers ("Mon–Wed vs last Mon–Wed").
    public var note: String?
}

public enum Metrics {
    /// Days of history used for the noise band.
    public static let noiseWindow = 28

    public static func range(_ period: MetricPeriod, now: Date, calendar cal: Calendar) -> (current: [Date], previous: [Date]) {
        let today = cal.startOfDay(for: now)
        func days(from start: Date, count: Int) -> [Date] {
            (0..<max(0, count)).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }
        switch period {
        case .day:
            return ([today], [cal.date(byAdding: .day, value: -1, to: today)!])
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let k = (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1
            return (days(from: start, count: k), days(from: cal.date(byAdding: .day, value: -7, to: start)!, count: k))
        case .month:
            let start = cal.dateInterval(of: .month, for: today)?.start ?? today
            let k = (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1
            let prevStart = cal.date(byAdding: .month, value: -1, to: start)!
            let prevLen = cal.range(of: .day, in: .month, for: prevStart)?.count ?? 30
            return (days(from: start, count: k), days(from: prevStart, count: min(k, prevLen)))
        }
    }

    public static func compare(_ s: MetricSeries, period: MetricPeriod, now: Date, calendar cal: Calendar) -> MetricComparison {
        let def = s.def
        let today = cal.startOfDay(for: now)
        var (cur, prev) = range(period, now: now, calendar: cal)
        let todayPartial = def.cumulative
        var note: String?

        func value(_ d: Date, isToday: Bool, mirrorOf: Date?) -> MetricPoint? {
            if isToday, todayPartial { return s.points[d] }
            if let mirrorOf, todayPartial {
                // The previous period's matching day counts only up to the same time of day.
                guard let soFar = s.soFar else { return nil }
                let offset = cal.dateComponents([.day], from: d, to: mirrorOf).day ?? 0
                let cutoff = cal.date(byAdding: .day, value: -offset, to: now) ?? now
                return soFar(d, cutoff).map { MetricPoint(day: d, value: $0, source: s.points[d]?.source ?? .measured) }
            }
            return s.points[d]
        }

        if def.aggregate == .spread && period == .day {
            return MetricComparison(id: def.id, period: period, current: nil, previous: nil, change: nil, band: def.noiseFloor,
                                    verdict: .notEnoughData, arrow: .none, currentDays: 0, previousDays: 0, sources: [],
                                    note: "Regularity needs a week")
        }

        // Today is still running: it only compares if the previous period's same day can be cut at the same time.
        if todayPartial, cur.last == today, s.soFar == nil {
            cur.removeLast()
            prev = Array(prev.prefix(cur.count))
            if period == .day { note = "Compared once today is over" }
        }
        var curPts: [MetricPoint] = [], prevPts: [MetricPoint] = []
        for (i, d) in cur.enumerated() {
            if let p = value(d, isToday: d == today, mirrorOf: nil) { curPts.append(p) }
            if i < prev.count, let p = value(prev[i], isToday: false, mirrorOf: d == today ? today : nil) { prevPts.append(p) }
        }

        let needed: Int
        switch period {
        case .day: needed = 1
        case .week, .month: needed = max(def.aggregate == .spread ? 3 : 2, Int((Double(cur.count) * 0.4).rounded(.up)))
        }
        let curV = aggregate(curPts.map(\.value), def.aggregate)
        let prevV = aggregate(prevPts.map(\.value), def.aggregate)
        let sources = Array(Set((curPts + prevPts).map(\.source))).sorted { $0.rawValue < $1.rawValue }
        guard curPts.count >= needed, prevPts.count >= needed, let c = curV, let p = prevV else {
            return MetricComparison(id: def.id, period: period, current: curV, previous: prevV, change: nil, band: def.noiseFloor,
                                    verdict: .notEnoughData, arrow: .none, currentDays: curPts.count, previousDays: prevPts.count,
                                    sources: sources, note: note ?? "Not enough data")
        }
        let band = noiseBand(s, before: cur.first ?? today, n: min(curPts.count, prevPts.count), calendar: cal, previous: p)
        let change = c - p
        let arrow: MetricArrow = abs(change) < band ? .flat : (change > 0 ? .up : .down)
        let verdict: MetricVerdict
        switch def.better {
        case .lower: verdict = abs(change) < band ? .same : (change < 0 ? .better : .worse)
        case .higher: verdict = abs(change) < band ? .same : (change > 0 ? .better : .worse)
        case .inside(let lo, let hi):
            func off(_ x: Double) -> Double { x < lo ? lo - x : (x > hi ? x - hi : 0) }
            let d = off(c) - off(p)
            verdict = (off(c) == 0 && off(p) == 0) || abs(d) < band ? .same : (d < 0 ? .better : .worse)
        }
        return MetricComparison(id: def.id, period: period, current: c, previous: p, change: change, band: band,
                                verdict: verdict, arrow: arrow, currentDays: curPts.count, previousDays: prevPts.count,
                                sources: sources, note: note)
    }

    static func aggregate(_ xs: [Double], _ a: MetricAggregate) -> Double? {
        guard !xs.isEmpty else { return nil }
        switch a {
        case .mean: return xs.reduce(0, +) / Double(xs.count)
        case .spread: return xs.count >= 2 ? sd(xs) : nil
        }
    }

    static func sd(_ xs: [Double]) -> Double {
        guard xs.count >= 2 else { return 0 }
        let m = xs.reduce(0, +) / Double(xs.count)
        return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
    }

    /// Half a standard deviation of a period mean over the last 4 weeks (SD of days / √n), never below the
    /// metric's floor. Without 5 days of history: 10% of the previous value.
    static func noiseBand(_ s: MetricSeries, before start: Date, n: Int, calendar cal: Calendar, previous: Double) -> Double {
        let from = cal.date(byAdding: .day, value: -noiseWindow, to: start) ?? start
        let hist = s.points.values.filter { $0.day >= from && $0.day < start }.map(\.value)
        if s.def.aggregate == .spread { return s.def.noiseFloor }
        guard hist.count >= 5 else { return max(s.def.noiseFloor, abs(previous) * 0.1) }
        return max(s.def.noiseFloor, 0.5 * sd(hist) / Double(max(1, n)).squareRoot())
    }

    /// Daily values for a chart or sparkline, oldest first; nil where there's no data (never drawn as zero).
    public static func daily(_ s: MetricSeries, last n: Int, now: Date, calendar cal: Calendar) -> [(Date, Double?)] {
        let today = cal.startOfDay(for: now)
        return (0..<n).reversed().compactMap { i in
            cal.date(byAdding: .day, value: -i, to: today).map { ($0, s.points[$0]?.value) }
        }
    }

    /// 7-day rolling mean of the days that have data (needs 3 of the 7).
    public static func rolling(_ values: [(Date, Double?)], window: Int = 7) -> [(Date, Double?)] {
        values.indices.map { i in
            let w = values[max(0, i - window + 1)...i].compactMap(\.1)
            return (values[i].0, w.count >= 3 ? w.reduce(0, +) / Double(w.count) : nil)
        }
    }
}

// MARK: - Building the series from app data

public struct MetricsInput {
    public var days: [Date]
    public var screen: [ScreenPoint?]
    public var screenDays: [ScreenDay]
    public var health: [HealthDay]
    public var moods: [MoodEntry]
    public var items: [WorkItem]
    public var progress: [ProgressEntry]
    /// The log (v1.2): work done is tracked time on tasks and studying.
    public var entries: [Entry]
    public var categories: CategoryTree
    public var now: Date
    public var dayRules: DayRuleBook
    /// Planned study minutes per day (PlanHistory).
    public var planned: [Date: Int]
    public var sleepNeed: Int
    /// Minutes away from home per day (`PlaceTime.awayMinutes`) and the planned bedtime of each night (`PlanHistory`).
    public var away: [Date: Int]
    public var plannedBed: [String: Date]

    public init(days: [Date], screen: [ScreenPoint?], screenDays: [ScreenDay] = [], health: [HealthDay], moods: [MoodEntry],
                items: [WorkItem], progress: [ProgressEntry], entries: [Entry], categories: CategoryTree = CategoryTree(),
                now: Date, dayRules: DayRuleBook = DayRuleBook(),
                planned: [Date: Int], sleepNeed: Int, away: [Date: Int] = [:], plannedBed: [String: Date] = [:]) {
        self.entries = entries
        self.categories = categories
        self.now = now
        self.dayRules = dayRules
        self.away = away
        self.plannedBed = plannedBed
        self.days = days
        self.screen = screen
        self.screenDays = screenDays
        self.health = health
        self.moods = moods
        self.items = items
        self.progress = progress
        self.planned = planned
        self.sleepNeed = sleepNeed
    }
}

public enum MetricsBuilder {
    /// Everything that can be computed from what Productium already stores. Pickups, first pickup and notifications come from
    /// screenshots; time out and bed-on-time get their points once Part H stores those signals.
    public static func series(_ x: MetricsInput, calendar cal: Calendar) -> [MetricID: MetricSeries] {
        var out: [MetricID: MetricSeries] = [:]
        func put(_ id: MetricID, _ pts: [MetricPoint], def: MetricDef? = nil, soFar: ((Date, Date) -> Double?)? = nil) {
            out[id] = MetricSeries(def: def ?? .of(id), points: pts, calendar: cal, soFar: soFar)
        }
        let days = x.days.map { cal.startOfDay(for: $0) }

        var scrolling: [MetricPoint] = [], total: [MetricPoint] = []
        for p in x.screen.compactMap({ $0 }) {
            let src: MetricSource = p.source == .screenshot ? .screenshot : p.source == .average ? .average : .estimated
            scrolling.append(MetricPoint(day: p.day, value: Double(p.scrolling), source: src))
            if let t = p.total { total.append(MetricPoint(day: p.day, value: Double(t), source: src)) }
        }
        put(.scrolling, scrolling)
        put(.screenTotal, total)
        // From Screen Time screenshots (v1.1 H1). A day shows only if a screenshot gave the number.
        func shot(_ id: MetricID, _ v: (ScreenDay) -> Int?) {
            put(id, x.screenDays.compactMap { d in
                guard d.source == "screenshot", let n = v(d) else { return nil }
                return MetricPoint(day: cal.startOfDay(for: d.day), value: Double(n), source: .screenshot)
            })
        }
        shot(.pickups) { $0.pickups }
        shot(.firstPickup) { $0.firstPickup }
        shot(.notifications) { $0.notifications }
        put(.scrollOpens, x.screenDays.filter { $0.source == "shortcuts" && $0.unlockRequests > 0 }
            .map { MetricPoint(day: $0.day, value: Double($0.unlockRequests), source: .measured) })

        let health = Dictionary(x.health.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { _, b in b })
        // Sleep the plan merely assumed is not data: those nights have no number.
        func src(_ h: HealthDay) -> MetricSource? {
            switch h.sleepSource {
            case .health?, nil: return .measured
            case .checkIns?: return .stated
            case .motion?: return .estimated
            case .plan?: return nil
            }
        }
        put(.sleep, days.compactMap { d in
            guard let h = health[d], let m = h.sleepMinutes, let s = src(h) else { return nil }
            return MetricPoint(day: d, value: Double(m), source: s)
        }, def: .sleep(need: x.sleepNeed))
        // Regularity: how much the middle of the night moves (minutes from noon, so midnight doesn't wrap).
        put(.sleepRegularity, days.compactMap { d in
            guard let h = health[d], let s = src(h), let bed = h.bedtime, let wake = h.wake, wake > bed else { return nil }
            let mid = bed.addingTimeInterval(wake.timeIntervalSince(bed) / 2)
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: cal.startOfDay(for: mid.addingTimeInterval(-12 * 3600)))!
            return MetricPoint(day: d, value: mid.timeIntervalSince(noon) / 60, source: s)
        })
        put(.steps, days.compactMap { d in health[d]?.steps.map { MetricPoint(day: d, value: Double($0), source: .measured) } })
        put(.daylight, days.compactMap { d in health[d]?.daylightMinutes.map { MetricPoint(day: d, value: Double($0), source: .measured) } })
        put(.outside, days.compactMap { d in x.away[d].map { MetricPoint(day: d, value: Double($0), source: .measured) } })
        // In bed on time: 100 on a night the bedtime was within half an hour of the plan, else 0 (a percentage of nights).
        put(.bedOnTime, days.compactMap { d in
            guard let h = health[d], src(h) != nil, let bed = h.bedtime, let planned = x.plannedBed[CapacityLearner.dayKey(d, cal)] else { return nil }
            return MetricPoint(day: d, value: bed <= planned.addingTimeInterval(30 * 60) ? 100 : 0, source: src(h) ?? .estimated)
        })
        put(.exercise, days.compactMap { d in
            guard let h = health[d], let m = h.exerciseMinutes ?? h.workoutMinutes else { return nil }
            return MetricPoint(day: d, value: Double(max(h.exerciseMinutes ?? 0, h.workoutMinutes ?? 0)), source: .measured)
        })
        put(.restingHeartRate, days.compactMap { d in health[d]?.restingHeartRate.map { MetricPoint(day: d, value: $0, source: .measured) } })

        let moodsByDay = Dictionary(grouping: x.moods) { cal.startOfDay(for: $0.at) }
        put(.mood, days.compactMap { d in moodsByDay[d].map { ms in
            MetricPoint(day: d, value: Double(ms.map(\.mood).reduce(0, +)) / Double(ms.count), source: .stated) } })
        put(.energy, days.compactMap { d in
            let es = (moodsByDay[d] ?? []).compactMap(\.energy)
            return es.isEmpty ? nil : MetricPoint(day: d, value: Double(es.reduce(0, +)) / Double(es.count), source: .stated)
        })

        // Focus: a day with nothing planned and nothing done has no number (a weekend off isn't a zero).
        let focusSoFar: (Date, Date) -> Double? = { day, cutoff in
            let ps = x.progress.filter { $0.at <= cutoff }
            return Double(WorkDone.minutes(on: day, entries: x.entries, tree: x.categories, now: min(cutoff, x.now), book: x.dayRules,
                                           progress: ps, calendar: cal))
        }
        var focus: [MetricPoint] = [], planDone: [MetricPoint] = []
        for d in days {
            let done = WorkDone.minutes(on: d, entries: x.entries, tree: x.categories, now: x.now, book: x.dayRules, progress: x.progress, calendar: cal)
            let planned = x.planned[d] ?? 0
            if done > 0 || planned > 0 { focus.append(MetricPoint(day: d, value: Double(done), source: .measured)) }
            if planned > 0 { planDone.append(MetricPoint(day: d, value: min(100, Double(done) / Double(planned) * 100), source: .measured)) }
        }
        put(.focus, focus, soFar: focusSoFar)
        put(.planDone, planDone)
        let doneByDay = Dictionary(grouping: x.items.filter { $0.isDone && $0.parentId == nil }.compactMap(\.doneAt)) { cal.startOfDay(for: $0) }
        let first = days.first ?? .distantPast
        let tracking = x.items.map(\.createdAt).min().map { cal.startOfDay(for: $0) } ?? .distantFuture
        put(.tasksDone, days.filter { $0 >= max(first, tracking) }.map { MetricPoint(day: $0, value: Double(doneByDay[$0]?.count ?? 0), source: .measured) })
        return out
    }
}

// MARK: - Export and AI context (G6)

public enum MetricsExport {
    /// One row per metric per day that has data: `metrics.csv` next to `moods.csv`.
    public static func csv(_ series: [MetricID: MetricSeries], calendar cal: Calendar) -> String {
        var rows: [[String]] = []
        for id in MetricID.allCases {
            guard let s = series[id] else { continue }
            for (day, p) in s.points.sorted(by: { $0.key < $1.key }) {
                rows.append([CapacityLearner.dayKey(day, cal), id.rawValue, String(format: "%g", p.value), p.source.rawValue])
            }
        }
        return Exporter.csv(["day", "metric", "value", "source"], rows)
    }

    /// For the insight pass: how each headline metric moved this week against last, in a line each.
    public static func summary(_ series: [MetricID: MetricSeries], now: Date, calendar cal: Calendar) -> String? {
        var lines: [String] = []
        for id in MetricID.allCases {
            guard let s = series[id], s.def.headline else { continue }
            let c = Metrics.compare(s, period: .week, now: now, calendar: cal)
            guard let cur = c.current, c.verdict != .notEnoughData else { continue }
            var l = "\(s.def.title) \(Noticed.amount(cur, s.def.unit))"
            if let p = c.previous { l += " (last week \(Noticed.amount(p, s.def.unit)), \(c.verdict.word))" }
            lines.append(l)
        }
        for n in Noticed.find(series).prefix(2) { lines.append(n.text) }
        return lines.isEmpty ? nil : "Life metrics, this week so far: " + lines.joined(separator: "; ")
    }
}

// MARK: - Noticed together (G.3)

public struct NoticedTogether: Hashable, Sendable {
    public var x: MetricID
    public var y: MetricID
    public var threshold: Double
    public var difference: Double
    public var days: Int
    public var text: String
}

public enum Noticed {
    public static let minDays = 14
    /// Cohen's d between the two groups of days; small effects aren't worth a sentence.
    public static let minEffect = 0.5

    static let pairs: [(MetricID, MetricID)] = [
        (.sleep, .focus), (.sleep, .mood), (.scrolling, .focus), (.scrolling, .mood), (.scrolling, .sleep),
        (.steps, .mood), (.daylight, .sleep), (.focus, .mood), (.pickups, .focus),
    ]

    /// Splits your days at the median of `x` and compares `y` between the halves. Worded as noticed, never as a cause.
    public static func find(_ series: [MetricID: MetricSeries], pairs: [(MetricID, MetricID)]? = nil) -> [NoticedTogether] {
        var out: [NoticedTogether] = []
        for (xi, yi) in pairs ?? Self.pairs {
            guard let xs = series[xi], let ys = series[yi] else { continue }
            let both = xs.points.compactMap { d, p in ys.points[d].map { (p.value, $0.value) } }
            guard both.count >= minDays else { continue }
            let sortedX = both.map(\.0).sorted()
            let median = friendly(sortedX[sortedX.count / 2], xs.def.unit)
            let hi = both.filter { $0.0 >= median }.map(\.1), lo = both.filter { $0.0 < median }.map(\.1)
            guard hi.count >= 5, lo.count >= 5 else { continue }
            let mh = hi.reduce(0, +) / Double(hi.count), ml = lo.reduce(0, +) / Double(lo.count)
            let pooled = ((Metrics.sd(hi) * Metrics.sd(hi) * Double(hi.count - 1) + Metrics.sd(lo) * Metrics.sd(lo) * Double(lo.count - 1))
                          / Double(hi.count + lo.count - 2)).squareRoot()
            let diff = mh - ml
            guard pooled > 0, abs(diff) / pooled >= minEffect, abs(diff) >= ys.def.noiseFloor else { continue }
            out.append(NoticedTogether(x: xi, y: yi, threshold: median, difference: diff, days: both.count,
                                       text: sentence(xs.def, median, ys.def, diff)))
        }
        return out.sorted { abs($0.difference / max(0.01, series[$0.y]!.def.noiseFloor)) > abs($1.difference / max(0.01, series[$1.y]!.def.noiseFloor)) }
    }

    /// A threshold people say out loud: 8h not 8h 7m, 8k steps not 8,213.
    static func friendly(_ v: Double, _ u: MetricUnit) -> Double {
        let step: Double
        switch u {
        case .minutes: step = v >= 120 ? 30 : 10
        case .count: step = v >= 2000 ? 500 : v >= 100 ? 10 : 1
        case .percent: step = 10
        case .clock: step = 15
        case .rating: step = 0.5
        case .bpm: step = 1
        }
        return (v / step).rounded() * step
    }

    public static func amount(_ v: Double, _ u: MetricUnit) -> String {
        switch u {
        case .minutes: return minutesLabel(Int(v.rounded()))
        case .count: return v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v.rounded()))"
        case .percent: return "\(Int(v.rounded()))%"
        case .clock: return TimeOfDay(minutes: Int(v.rounded())).label
        case .rating: return String(format: "%.1f", v)
        case .bpm: return "\(Int(v.rounded())) bpm"
        }
    }

    static func sentence(_ x: MetricDef, _ t: Double, _ y: MetricDef, _ diff: Double) -> String {
        let cond = x.unit == .minutes ? "On days with \(amount(t, x.unit))+ of \(x.title.lowercased())"
            : "On days with \(amount(t, x.unit))+ \(x.title.lowercased())"
        let more = diff > 0 ? "more" : "less"
        let what: String
        switch y.unit {
        case .rating: what = "your \(y.title.lowercased()) was \(String(format: "%.1f", abs(diff))) points \(diff > 0 ? "higher" : "lower")"
        case .minutes: what = "you had \(amount(abs(diff), .minutes)) \(more) \(y.title.lowercased())"
        default: what = "\(y.title.lowercased()) was \(amount(abs(diff), y.unit)) \(diff > 0 ? "higher" : "lower")"
        }
        return "Noticed: \(cond), \(what)."
    }
}
