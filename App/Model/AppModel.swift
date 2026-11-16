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
    /// What the last brain dump did, shown under the box with Undo.
    var receipt: Receipt?
    @ObservationIgnored private var undoSnapshot: AppState?
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
        let input = PlannerInput(now: now, calendar: cal, items: state.items, commitments: state.commitments,
                                 events: state.events + state.oneOffs, preferences: state.prefs, learned: state.learned,
                                 health: state.health, moods: state.moods, locked: locked, routines: state.routines,
                                 exceptions: state.exceptions, horizonDays: 14)
        state.plan = Planner.merge(previous: state.plan, new: Planner.plan(input), now: now, calendar: cal)
        save()
        applyPlanEffects()
    }

    private func applyPlanEffects() {
        let plan = state.plan
        let now = Date()
        if state.integrations.notifications {
            NotificationService.schedule(plan: plan, prefs: state.prefs, items: state.items, suggestions: markerPrompts())
            NotificationService.scheduleHousekeeping(freeTier: Signature.isFreeTier, expiry: signatureExpiry)
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
        followUp(new: item)
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

    /// When this sideloaded build stops launching (free signing lasts 7 days).
    var signatureExpiry: Date? { Signature.expiry }

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
                         fixedEvents: state.events + state.oneOffs, routines: state.routines, outcomes: state.outcomes, itemsById: itemsById,
                         health: state.health.first { cal.isDate($0.day, inSameDayAs: day) },
                         nextHealth: state.health.first { cal.isDate($0.day, inSameDayAs: next) },
                         screen: state.screen.first { cal.isDate($0.day, inSameDayAs: day) }, prefs: state.prefs,
                         exceptions: state.exceptions)
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

    // MARK: - Brain dump (the main way anything gets in or gets fixed)

    struct Receipt: Equatable {
        var input: String
        var reply: String
        var changes: [String]
        var canUndo: Bool
        var failed: Bool
    }

    /// Anything at all: deadlines, corrections, what happened, how they feel, a question,
    /// screenshots (Screen Time, assignment sheets, timetables). Haiku reads it in context
    /// and returns actions. The device applies them, then shows what changed, with Undo.
    @discardableResult
    func dump(_ raw: String, images: [AIImage] = []) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return false }
        busy.insert("dump")
        defer { busy.remove("dump") }
        let now = Date()
        let today = cal.startOfDay(for: now)
        let context = Prompts.dumpContext(now: now, calendar: cal, items: state.items, commitments: state.commitments,
                                          exceptions: state.exceptions, routines: state.routines,
                                          todaySegments: segments(on: today),
                                          todayMarkers: state.markers.filter { cal.isDate($0.at, inSameDayAs: now) },
                                          plan: state.plan)
        let message = "Context:\n\(context)\n\nStudent wrote:\n\(text.isEmpty ? "(screenshots only)" : text)"
        let history = Array(state.chat.suffix(4))
        do {
            let req = AIRequest(tier: .fast, system: Prompts.dump(),
                                messages: history + [AIMessage(role: "user", content: message, images: images)],
                                schema: Schemas.dump)
            let res = try await ClaudeClient.shared.complete(req)
            guard let structured = res.structured, let result = try? structured.decode(DumpResult.self) else { throw AIError.decoding }
            undoSnapshot = state
            let before = Set(state.items.map(\.id))
            var ds = state.dumpState
            let changes = DumpApplier.apply(result, to: &ds, now: now, calendar: cal)
            state.dumpState = ds
            state.chat += [AIMessage(role: "user", content: text.isEmpty ? "(screenshots)" : text),
                           AIMessage(role: "assistant", content: result.reply)]
            receipt = Receipt(input: text, reply: result.reply, changes: changes, canUndo: !changes.isEmpty, failed: false)
            replan()
            for item in state.items where !before.contains(item.id) { followUp(new: item) }
            return true
        } catch {
            let msg = (error as? AIError)?.errorDescription ?? "Couldn't reach your Claude server. Check that Tailscale is on, then send again."
            receipt = Receipt(input: text, reply: msg, changes: [], canUndo: false, failed: true)
            return false
        }
    }

    func undo() {
        guard let snap = undoSnapshot else { return }
        let chat = state.chat
        state = snap
        state.chat = chat
        undoSnapshot = nil
        receipt?.canUndo = false
        receipt?.changes = ["Undone"]
        replan()
    }

    /// Long projects get broken into steps; tests with topics get flashcards.
    private func followUp(new item: WorkItem) {
        if [.application, .essay, .project].contains(item.kind), item.due.timeIntervalSinceNow > 10 * 86400, item.parentId == nil {
            Task { await decompose(item.id) }
        }
        if item.kind.isMemoryBased, !item.topics.isEmpty { Task { await makeCards(for: item) } }
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

/// Reads the provisioning profile embedded in a sideloaded/dev build to find when it expires.
enum Signature {
    static var expiry: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>ExpirationDate</key>"),
              let open = text.range(of: "<date>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex) else { return nil }
        return ISO8601DateFormatter().date(from: String(text[open.upperBound..<close.lowerBound]))
    }

    static var isFreeTier: Bool {
        #if FREE_TIER
        return true
        #else
        return false
        #endif
    }
}
