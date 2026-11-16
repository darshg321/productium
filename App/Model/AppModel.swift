import Foundation
import SwiftUI
import Observation
import UserNotifications
import ProductiumCore

/// The app's single source of truth. Views read `state` and call intent methods.
/// Every change ends in `replan()`, which rebuilds the plan and pushes it out to
/// notifications, shields, widgets, the Live Activity and alarms.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var state: AppState
    var toast: String?
    var busy: Set<String> = []
    var serverOnline: Bool?
    var deepLink: String?
    let cal = Calendar.current
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: Date = .distantPast

    init() {
        state = Persistence.load()
    }

    // MARK: - Persistence

    func save() {
        saveTask?.cancel()
        let snapshot = state
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            Persistence.save(snapshot)
        }
    }

    // MARK: - Lifecycle

    func launch() {
        NotificationService.register()
        LocationService.shared.onTransition = { [weak self] place, entered in
            Task { @MainActor in self?.handleGeofence(place, entered: entered) }
        }
        if state.integrations.health {
            HealthService.shared.observeSleep { [weak self] in Task { @MainActor in await self?.refresh(full: false) } }
        }
        if state.integrations.location { LocationService.shared.monitor(state.places) }
        if state.onboarded { Task { await refresh() } }
    }

    func foreground() {
        if let link = SharedConfig.defaults.string(forKey: SharedConfig.Key.pendingDeepLink) {
            deepLink = link
            SharedConfig.defaults.removeObject(forKey: SharedConfig.Key.pendingDeepLink)
        }
        if Date().timeIntervalSince(lastRefresh) > 5 * 60 { Task { await refresh() } } else { replan() }
    }

    /// Pull every data source, learn from it, replan.
    func refresh(full: Bool = true) async {
        lastRefresh = Date()
        await syncHealth()
        syncCalendar()
        syncScreen()
        learnFromPastDays()
        if let note = state.taper.update(days: state.screen, now: Date(), goalMinutes: state.prefs.screenTimeGoalMinutes, calendar: cal) {
            toast = note
        }
        state.prune(now: Date())
        replan()
        if full {
            serverOnline = await ClaudeClient.shared.ping()
            await ensureGapContent()
            await weeklyReviewIfDue()
        }
    }

    // MARK: - Planning

    var itemsById: [UUID: WorkItem] { Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) }) }

    func replan() {
        let now = Date()
        // Never yank the block the student is in the middle of.
        var locked: [PlannedBlock] = []
        if let f = state.focus, var b = state.plan.blocks.first(where: { $0.id == f.blockId }) {
            b.end = max(b.end, now.addingTimeInterval(60))
            locked = [b]
        } else if let cur = state.plan.current(at: now), cur.isStudy, !state.outcomes.contains(where: { $0.blockId == cur.id }) {
            locked = [cur]
        }
        let input = PlannerInput(now: now, calendar: cal, items: state.items, commitments: state.commitments, events: state.events,
                                 preferences: state.prefs, learned: state.learned, health: state.health, moods: state.moods,
                                 locked: locked, routines: state.routines, horizonDays: 14)
        state.plan = Planner.merge(previous: state.plan, new: Planner.plan(input), now: now, calendar: cal)
        save()
        applyPlanEffects()
    }

    private func applyPlanEffects() {
        let plan = state.plan
        let now = Date()
        if state.integrations.notifications {
            NotificationService.schedule(plan: plan, prefs: state.prefs, items: state.items, suggestions: markerPrompts())
        }
        if state.integrations.screenTime {
            let st = ScreenTimeService.shared
            st.configureDaily(limitMinutes: state.taper.dailyLimit, unlocksPerDay: state.taper.unlocksPerDay)
            st.configureSchedules(plan: plan, prefs: state.prefs, shieldFocus: true, shieldWindDown: true)
        }
        WidgetService.publish(plan: plan, outcomes: state.outcomes)
        if state.integrations.liveActivities {
            LiveActivityService.update(current: plan.current(at: now), next: plan.next(after: now))
        }
        if state.integrations.alarms { Task { await AlarmService.schedule(plan.wakePlans) } }
        if state.integrations.calendarExport { CalendarService.shared.export(plan: plan) }
    }

    var currentBlock: PlannedBlock? { state.plan.current(at: Date()) }

    func todayBlocks(_ date: Date = Date()) -> [PlannedBlock] {
        state.plan.blocks(on: date, calendar: cal).filter { $0.kind != .sleep }
    }

    /// Ended study blocks (last 36 h) that nobody said anything about. Asked once, in one tap.
    var pendingOutcomes: [PlannedBlock] {
        let now = Date()
        let answered = Set(state.outcomes.map(\.blockId))
        return state.plan.blocks.filter { $0.isStudy && $0.end <= now && $0.end > now.addingTimeInterval(-36 * 3600) && !answered.contains($0.id) }
    }

    var activeWarnings: [PlanWarning] {
        state.plan.warnings.filter { !state.dismissed.contains($0.message) }
    }

    // MARK: - Outcomes & focus

    func logOutcome(blockId: UUID, status: OutcomeStatus, actualMinutes: Int? = nil) {
        guard !state.outcomes.contains(where: { $0.blockId == blockId }),
              let b = state.plan.blocks.first(where: { $0.id == blockId }) else { return }
        let actual = actualMinutes ?? (status == .done ? b.minutes : status == .partial ? b.minutes / 2 : 0)
        let idx = b.itemId.flatMap { id in state.items.firstIndex { $0.id == id } }
        let o = BlockOutcome(blockId: blockId, itemId: b.itemId, kind: idx.map { state.items[$0].kind }, plannedStart: b.start,
                             plannedMinutes: b.minutes, actualMinutes: actual, status: status)
        state.outcomes.append(o)
        state.learned.record(outcome: o, calendar: cal)
        if let i = idx { state.items[i].completedMinutes += actual }
        if status == .skipped {
            // Self-compassion, not guilt: self-forgiveness reduces later procrastination (Wohl et al. 2010).
            toast = "No problem. It's been moved to a better slot."
        }
        replan()
    }

    func startFocus(_ b: PlannedBlock) {
        let end = max(b.end, Date().addingTimeInterval(Double(b.minutes) * 60))
        state.focus = FocusSession(blockId: b.id, itemId: b.itemId, title: b.title, startedAt: Date(), plannedEnd: end)
        if state.integrations.screenTime { ScreenTimeService.shared.focusNow(true, title: b.title, ends: end) }
        LiveActivityService.update(current: PlannedBlock(id: b.id, kind: b.kind, start: Date(), end: end, title: b.title), next: nil)
        save()
    }

    /// Start working on an item right now, even if it isn't planned now.
    func focusNow(on item: WorkItem) {
        let mins = Int(state.learned.focusMinutes.rounded())
        let b = PlannedBlock(kind: item.kind.isMemoryBased ? .review : .work, start: Date(), end: Date().addingTimeInterval(Double(mins) * 60),
                             title: item.title, itemId: item.id, hint: "Started on your own. Nice.")
        state.plan.blocks.append(b)
        state.plan.blocks.sort { $0.start < $1.start }
        startFocus(b)
    }

    func endFocus(_ status: OutcomeStatus) {
        guard let f = state.focus else { return }
        let elapsed = max(1, Int(Date().timeIntervalSince(f.startedAt) / 60))
        state.focus = nil
        if state.integrations.screenTime { ScreenTimeService.shared.focusNow(false) }
        logOutcome(blockId: f.blockId, status: status, actualMinutes: elapsed)
    }

    // MARK: - Items

    func add(_ item: WorkItem) {
        let dup = state.items.contains {
            $0.title.lowercased() == item.title.lowercased() && cal.isDate($0.due, inSameDayAs: item.due)
        }
        guard !dup else { return }
        state.items.append(item)
        if [.application, .essay, .project].contains(item.kind), item.due.timeIntervalSinceNow > 10 * 86400, item.parentId == nil {
            Task { await decompose(item.id) }
        }
        if item.kind.isMemoryBased, !item.topics.isEmpty { Task { await makeCards(for: item) } }
    }

    func update(_ item: WorkItem) {
        guard let i = state.items.firstIndex(where: { $0.id == item.id }) else { return }
        state.items[i] = item
        replan()
    }

    func complete(_ id: UUID) {
        guard let i = state.items.firstIndex(where: { $0.id == id }), !state.items[i].isDone else { return }
        state.items[i].isDone = true
        state.items[i].doneAt = Date()
        let it = state.items[i]
        if it.completedMinutes >= 10 {
            state.learned.recordCompletion(kind: it.kind, estimated: it.estimateMinutes, actual: it.completedMinutes)
        }
        // Finishing the last step of a project finishes the project.
        if let p = it.parentId, !state.items.contains(where: { $0.parentId == p && !$0.isDone }) { complete(p) }
        replan()
    }

    func delete(_ id: UUID) {
        state.items.removeAll { $0.id == id || $0.parentId == id }
        replan()
    }

    // MARK: - Quick input (the main way data gets in)

    /// One line of text: a check-in ("left home"), a new deadline ("bio quiz thurs"),
    /// a recurring activity ("debate tue 3:30-5"), a mood ("tired"), or several at once.
    func submit(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = Date()
        // Common check-ins are parsed on the device instantly, no network.
        let local = MarkerParser.parse(text, at: now, commitments: state.commitments, calendar: cal)
        if !local.isEmpty, text.split(separator: " ").count <= 5 {
            state.markers += local
            toast = "Logged · \(text)"
            save()
            return
        }
        guard ClaudeClient.shared.isConfigured else {
            fallbackAdd(text)
            return
        }
        busy.insert("add")
        defer { busy.remove("add") }
        do {
            let open = state.items.filter { !$0.isDone }
            let r = try await ClaudeClient.shared.structured(
                .fast, system: Prompts.quickAdd(now: now, timeZone: cal.timeZone, commitments: state.commitments, openItems: open),
                user: text, schema: Schemas.quickAdd, as: QuickAddResult.self)
            apply(r, now: now)
        } catch {
            fallbackAdd(text)
            toast = (error as? AIError)?.errorDescription ?? "Offline. Saved it as a task you can edit."
        }
    }

    private func apply(_ r: QuickAddResult, now: Date) {
        for p in r.items { if let it = AIMapper.item(p, timeZone: cal.timeZone) { add(it) } }
        for c in r.commitments { if let cm = AIMapper.commitment(c) { state.commitments.append(cm) } }
        state.markers += r.markers.map { AIMapper.marker($0, now: now) }
        for title in r.completedTitles {
            if let it = state.items.first(where: { !$0.isDone && ($0.title.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains($0.title)) }) {
                complete(it.id)
            }
        }
        if let m = r.mood { logMood(m, energy: nil, note: nil) }
        toast = r.reply
        replan()
    }

    /// No server: a keyword parse is better than losing the input.
    private func fallbackAdd(_ text: String) {
        let t = text.lowercased()
        let kind: TaskKind = t.contains("test") || t.contains("exam") ? .test : t.contains("quiz") ? .quiz
            : t.contains("essay") ? .essay : t.contains("project") ? .project : .assignment
        var due = cal.date(byAdding: .day, value: 3, to: Date())!
        let days = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        if t.contains("tomorrow") { due = cal.date(byAdding: .day, value: 1, to: Date())! }
        for (k, wd) in days where t.contains(k) {
            due = cal.nextDate(after: Date(), matching: DateComponents(weekday: wd), matchingPolicy: .nextTime) ?? due
        }
        due = cal.date(bySettingHour: kind.isMemoryBased ? 8 : 23, minute: kind.isMemoryBased ? 0 : 59, second: 0, of: due) ?? due
        add(WorkItem(title: text, kind: kind, due: due))
        toast = toast ?? "Added. Tap it in Plan to fix details."
        replan()
    }

    func logMarker(_ phrase: String, source: MarkerSource = .manual, at: Date = Date()) {
        let evs = MarkerParser.parse(phrase, at: at, commitments: state.commitments, calendar: cal, source: source)
        guard !evs.isEmpty else { return }
        state.markers += evs
        save()
    }

    private func handleGeofence(_ place: String, entered: Bool) {
        let name = state.places.first { $0.id == place }?.name ?? place
        let phrase: String
        switch (place, entered) {
        case ("home", false): phrase = "left home"
        case ("home", true): phrase = "home"
        case ("school", true): phrase = "at school"
        case ("school", false): phrase = "left school"
        default: phrase = entered ? "at \(name)" : "finished \(name)"
        }
        logMarker(phrase, source: .geofence)
    }

    /// While a routine is still being learned (and there's no geofence), prompt at the
    /// moment it usually happens. Prompts stop once ~5 samples exist.
    private func markerPrompts() -> [(Date, String)] {
        guard !state.integrations.location else { return [] }
        var out: [(Date, String)] = []
        let now = Date()
        for d in 0...1 {
            guard let day = cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: now)) else { continue }
            let wd = cal.component(.weekday, from: day)
            let school = state.commitments.filter { $0.kind == .school && $0.weekdays.contains(wd) }
            guard let first = school.min(by: { $0.start < $1.start }), let last = school.max(by: { $0.end < $1.end }) else { continue }
            let to = state.routines.first { $0.id == "to_school" }
            let from = state.routines.first { $0.id == "from_school" }
            if let to, to.samples.count < 5, let s = cal.date(bySettingHour: first.start.hour, minute: first.start.minute, second: 0, of: day) {
                out.append((s.addingTimeInterval(-Double(to.minutes + 5) * 60), "Left home"))
            }
            if let from, from.samples.count < 5, let e = cal.date(bySettingHour: last.end.hour, minute: last.end.minute, second: 0, of: day) {
                out.append((e.addingTimeInterval(Double(from.minutes) * 60), "Home"))
            }
        }
        return out.filter { $0.0 > now }
    }

    func logMood(_ mood: Int, energy: Int?, note: String?) {
        state.moods.append(MoodEntry(mood: mood, energy: energy, note: note))
        replan()
    }

    var supportSuggested: Bool { Wellbeing.supportSuggested(moods: state.moods, now: Date()) }

    var todayMood: MoodEntry? { state.moods.filter { cal.isDateInToday($0.at) }.max { $0.at < $1.at } }

    // MARK: - Syncing

    private func syncHealth() async {
        guard state.integrations.health else { return }
        let days = await HealthService.shared.days(back: 21, calendar: cal)
        guard !days.isEmpty else { return }
        var byDay = Dictionary(state.health.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for d in days { byDay[cal.startOfDay(for: d.day)] = d }
        state.health = byDay.values.sorted { $0.day < $1.day }
        let mids = HealthService.freeDayMidpoints(Array(state.health.suffix(28)), prefs: state.prefs, cal: cal)
        if let c = LearnedModel.chronotype(fromFreeDaySleepMidpointsHours: mids) { state.learned.inferredChronotype = c }
    }

    private func syncCalendar() {
        guard state.integrations.calendarImport, CalendarService.shared.authorized else { return }
        state.events = CalendarService.shared.events(days: 14)
        for cand in CalendarService.shared.deadlineCandidates(days: 30) {
            if let i = state.items.firstIndex(where: { $0.externalId == cand.externalId }) {
                state.items[i].due = cand.due
            } else {
                add(cand)
            }
        }
    }

    private func syncScreen() {
        guard state.integrations.screenTime else { return }
        var byDay = Dictionary(state.screen.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for d in ScreenTimeService.shared.usageDays(back: 21) where d.distractingMinutes > 0 || byDay[d.day] == nil {
            byDay[cal.startOfDay(for: d.day)] = d
        }
        state.screen = byDay.values.sorted { $0.day < $1.day }
    }

    /// Teach routines from finished days' check-ins (each day once).
    private func learnFromPastDays() {
        let today = cal.startOfDay(for: Date())
        for i in 1...7 {
            guard let day = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let key = SharedConfig.dayKey(day)
            guard !state.learnedDays.contains(key) else { continue }
            let evs = state.markers.filter { cal.isDate($0.at, inSameDayAs: day) }
            let wake = state.health.first { cal.isDate($0.day, inSameDayAs: day) }?.wake
            state.routines = RoutineLearner.learn(day: evs, healthWake: wake, routines: state.routines)
            state.learnedDays.insert(key)
        }
        if state.learnedDays.count > 60 {
            state.learnedDays = Set(state.learnedDays.sorted().suffix(30))
        }
    }

    // MARK: - Insights

    func dayInputs(_ day: Date) -> DayInputs {
        let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
        return DayInputs(day: day, events: state.markers, commitments: state.commitments,
                         fixedEvents: state.events, routines: state.routines, outcomes: state.outcomes, itemsById: itemsById,
                         health: state.health.first { cal.isDate($0.day, inSameDayAs: day) },
                         nextHealth: state.health.first { cal.isDate($0.day, inSameDayAs: next) },
                         screen: state.screen.first { cal.isDate($0.day, inSameDayAs: day) }, prefs: state.prefs)
    }

    func dayTotals(last n: Int, includeToday: Bool = false) -> [DayTotals] {
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { i -> DayTotals? in
            guard let d = cal.date(byAdding: .day, value: -(i + (includeToday ? 0 : 1)), to: today) else { return nil }
            let planned = state.outcomes.filter { cal.isDate($0.plannedStart, inSameDayAs: d) }.reduce(0) { $0 + $1.plannedMinutes }
            return Insights.dayTotals(dayInputs(d), plannedStudy: planned, moods: state.moods,
                                      screenTarget: state.taper.targetMinutes, calendar: cal, now: Date())
        }
    }

    func segments(on day: Date) -> [Segment] {
        TimelineBuilder.segments(dayInputs(day), calendar: cal, now: Date())
    }

    // MARK: - AI (Haiku fast, Sonnet reasoned)

    func decompose(_ id: UUID) async {
        guard let item = state.items.first(where: { $0.id == id }), ClaudeClient.shared.isConfigured,
              !state.items.contains(where: { $0.parentId == id }) else { return }
        busy.insert("decompose")
        defer { busy.remove("decompose") }
        guard let d = try? await ClaudeClient.shared.structured(
            .reason, system: Prompts.decomposition(item: item, now: Date(), timeZone: cal.timeZone),
            user: "Task: \(item.title) (\(item.kind.rawValue)). Estimated total \(item.estimateMinutes) min. Notes: \(item.notes ?? "none")",
            schema: Schemas.decomposition, as: Decomposition.self) else { return }
        for s in d.steps {
            let p = ParsedItem(title: "\(item.title): \(s.title)", kind: s.kind, subject: item.subject, due: s.due,
                               estimateMinutes: s.estimateMinutes, importance: item.importance, difficulty: item.difficulty, topics: nil)
            if var child = AIMapper.item(p, timeZone: cal.timeZone, parentId: item.id) {
                child.due = min(child.due, item.due)
                state.items.append(child)
            }
        }
        toast = "Broke “\(item.title)” into \(d.steps.count) steps."
        replan()
    }

    func makeCards(for item: WorkItem) async {
        guard ClaudeClient.shared.isConfigured, !item.topics.isEmpty else { return }
        guard let batch = try? await ClaudeClient.shared.structured(
            .fast, system: Prompts.flashcards(subject: item.subject, topics: item.topics, count: 10),
            user: "Make the cards.", schema: Schemas.cards, as: CardBatch.self, cacheTTL: 86400) else { return }
        state.flashcards += batch.cards.map { Flashcard(itemId: item.id, subject: item.subject, front: $0.front, back: $0.back) }
        save()
    }

    func ensureGapContent() async {
        guard ClaudeClient.shared.isConfigured else { return }
        for t in state.items where t.kind.isMemoryBased && !t.isDone && !t.topics.isEmpty && t.due.timeIntervalSinceNow < 14 * 86400
            && state.flashcards.filter({ $0.itemId == t.id }).count < 5 {
            await makeCards(for: t)
        }
        let unread = state.reads.filter { $0.readAt == nil }.count
        guard unread < 3 else { return }
        let subjects = Array(Set(state.items.compactMap(\.subject))).prefix(5)
        guard let batch = try? await ClaudeClient.shared.structured(
            .fast, system: Prompts.reads(interests: state.prefs.interests, subjects: Array(subjects), count: 4),
            user: "Write them.", schema: Schemas.reads, as: ReadBatch.self) else { return }
        state.reads += batch.pieces.map { ReadPiece(title: $0.title, body: $0.body, subject: $0.subject, question: $0.question, source: "Claude") }
        save()
    }

    func weeklyReviewIfDue(force: Bool = false) async {
        guard ClaudeClient.shared.isConfigured else { return }
        if !force, let at = state.reviewAt, Date().timeIntervalSince(at) < 6.5 * 86400 { return }
        guard force || state.outcomes.count >= 5 else { return }
        busy.insert("review")
        defer { busy.remove("review") }
        let summary = Insights.summarize(dayTotals(last: 7), learned: state.learned)
        let ctx = Prompts.context(now: Date(), items: state.items, plan: state.plan, summary: summary, moods: state.moods,
                                  taper: state.taper, learned: state.learned, calendar: cal)
        guard let r = try? await ClaudeClient.shared.structured(.reason, system: Prompts.weeklyReview(), user: ctx,
                                                               schema: Schemas.weeklyReview, as: WeeklyReview.self) else { return }
        state.review = r
        state.reviewAt = Date()
        save()
    }

    func applyReviewChanges() {
        guard let c = state.review?.changes else { return }
        state.prefs = AIMapper.apply(c, to: state.prefs)
        state.review?.changes = nil
        toast = "Settings adjusted."
        replan()
    }

    func ask(_ question: String) async {
        state.chat.append(AIMessage(role: "user", content: question))
        busy.insert("coach")
        defer { busy.remove("coach") }
        let summary = Insights.summarize(dayTotals(last: 7), learned: state.learned)
        let ctx = Prompts.context(now: Date(), items: state.items, plan: state.plan, summary: summary, moods: state.moods,
                                  taper: state.taper, learned: state.learned, calendar: cal)
        do {
            let reply = try await ClaudeClient.shared.text(.reason, system: Prompts.coach() + "\n\nContext:\n" + ctx,
                                                           messages: Array(state.chat.suffix(12)))
            state.chat.append(AIMessage(role: "assistant", content: reply))
        } catch {
            state.chat.append(AIMessage(role: "assistant", content: (error as? AIError)?.errorDescription ?? "Couldn't reach the server."))
        }
        save()
    }

    // MARK: - Gap mode

    func reviewCard(_ id: UUID, correct: Bool) {
        guard let i = state.flashcards.firstIndex(where: { $0.id == id }) else { return }
        let test = state.flashcards[i].itemId.flatMap { itemsById[$0]?.due }
        state.flashcards[i] = Leitner.review(state.flashcards[i], correct: correct, now: Date(), testDate: test)
        save()
    }

    func markRead(_ id: UUID) {
        if let i = state.reads.firstIndex(where: { $0.id == id }) { state.reads[i].readAt = Date(); save() }
    }

    // MARK: - Data ownership

    func exportFiles() throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("productium-export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let days = dayTotals(last: 60, includeToday: true)
        let segs = (0..<30).flatMap { i -> [Segment] in
            guard let d = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: Date())) else { return [] }
            return segments(on: d)
        }.sorted { $0.start < $1.start }
        let files: [(String, Data)] = [
            ("productium-backup.json", try Exporter.json(state.backup)),
            ("daily-summary.csv", Data(Exporter.dailyCSV(days).utf8)),
            ("timeline.csv", Data(Exporter.segmentsCSV(segs).utf8)),
            ("tasks.csv", Data(Exporter.itemsCSV(state.items).utf8)),
            ("study-sessions.csv", Data(Exporter.outcomesCSV(state.outcomes).utf8)),
            ("moods.csv", Data(Exporter.moodsCSV(state.moods).utf8)),
            ("check-ins.csv", Data(Exporter.markersCSV(state.markers).utf8)),
            ("plan.ics", Data(Exporter.ics(state.plan).utf8)),
        ]
        return try files.map { name, data in
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
    }

    func importBackup(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        state.restore(try Exporter.decodeBackup(try Data(contentsOf: url)))
        replan()
        toast = "Restored."
    }

    func deleteEverything() {
        ScreenTimeService.shared.disable()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        state = AppState()
        Persistence.save(state)
    }
}
