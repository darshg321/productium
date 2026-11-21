import Foundation
import SwiftUI
import Observation
import UserNotifications
import ProductiumCore

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var state: AppState
    var toast: String?
    var busy: Set<String> = []
    var serverOnline: Bool?
    var serverUsage: ServerUsage?
    var subscription: SubscriptionStatus?
    var callLog: AICallLog
    var aboutMe: AboutMe {
        didSet { AboutMeStore.save(aboutMe) }
    }
    @ObservationIgnored private var callLogSave: Task<Void, Never>?
    var deepLink: String?
    let cal = Calendar.current
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: Date = .distantPast

    init() {
        var loaded = Persistence.load()
        loaded.screen = loaded.screen.recomputed(loaded.scrollingApps)
        loaded.screenAverages = loaded.screenAverages.recomputed(loaded.scrollingApps)
        state = loaded
        callLog = CallLogStore.load()
        aboutMe = AboutMeStore.load()
        if let e = Persistence.loadError {
            state.telemetry.record(.storage, "decode_failed", level: .error, ["error": e])
            Persistence.loadError = nil
        }
    }

    /// One line in the development log (Part T). Call at decisions and boundaries, not in loops.
    func log(_ area: TelemetryEvent.Area, _ name: String, level: TelemetryEvent.Level = .info, _ detail: [String: String] = [:]) {
        state.telemetry.record(area, name, level: level, at: Date(), detail)
    }

    // The Inbox draft survives tab changes, backgrounding and relaunch: text in state, images as files.
    static var draftsURL: URL { LocalStore.containerURL.appendingPathComponent("drafts", isDirectory: true) }
    @ObservationIgnored private var draftImageCache: [String: (UIImage, AIImage)] = [:]

    var draftText: String {
        get { state.draft.text }
        set { state.draft.text = newValue; save() }
    }

    struct DraftImage: Identifiable {
        let file: String
        let image: UIImage
        let ai: AIImage
        var id: String { file }
    }

    var draftImages: [DraftImage] {
        state.draft.imageFiles.compactMap { file in
            if let c = draftImageCache[file] { return DraftImage(file: file, image: c.0, ai: c.1) }
            guard let data = try? Data(contentsOf: Self.draftsURL.appendingPathComponent(file)), let img = UIImage(data: data) else { return nil }
            let ai = AIImage(mediaType: "image/jpeg", base64: data.base64EncodedString())
            draftImageCache[file] = (img, ai)
            return DraftImage(file: file, image: img, ai: ai)
        }
    }

    func addDraftImages(_ jpegs: [Data]) {
        try? FileManager.default.createDirectory(at: Self.draftsURL, withIntermediateDirectories: true)
        for data in jpegs {
            let file = UUID().uuidString + ".jpg"
            guard (try? data.write(to: Self.draftsURL.appendingPathComponent(file), options: .atomic)) != nil else { continue }
            state.draft.imageFiles.append(file)
        }
        Persistence.save(state)
    }

    func removeDraftImage(_ file: String) {
        state.draft.imageFiles.removeAll { $0 == file }
        draftImageCache[file] = nil
        try? FileManager.default.removeItem(at: Self.draftsURL.appendingPathComponent(file))
        save()
    }

    /// Only after a successful send.
    func clearDraft() {
        for f in state.draft.imageFiles { try? FileManager.default.removeItem(at: Self.draftsURL.appendingPathComponent(f)) }
        draftImageCache = [:]
        state.draft = Draft()
        save()
    }

    func save() {
        saveTask?.cancel()
        let snapshot = state
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            if let e = Persistence.save(snapshot) {
                await MainActor.run { AppModel.shared.log(.storage, "save_failed", level: .error, ["error": e]) }
            }
        }
    }

    func launch() {
        ClaudeClient.shared.onUsage = { [weak self] feature, model, tokens, callId in
            self?.recordUsage(feature, model: model, tokens: tokens, callId: callId)
        }
        ClaudeClient.shared.onCall = { [weak self] call in self?.logCall(call) }
        NotificationService.register()
        LocationService.shared.onTransition = { [weak self] place, entered in
            Task { @MainActor in self?.handleGeofence(place, entered: entered) }
        }
        if state.integrations.health {
            HealthService.shared.observeSleep { [weak self] in Task { @MainActor in await self?.refresh(full: false) } }
        }
        LocationService.shared.onVisit = { [weak self] visit in
            Task { @MainActor in self?.recordVisit(visit) }
        }
        if state.integrations.location {
            LocationService.shared.monitor(state.places)
            LocationService.shared.visitsWanted = true
            LocationService.shared.monitorVisits(true)
        }
        log(.lifecycle, "launch", ["onboarded": "\(state.onboarded)", "entries": "\(state.entries.count)"])
        Task { await UpdateChecker.shared.checkIfDue() }
        if state.onboarded { Task { await refresh() } }
    }

    func foreground() {
        Friction.ended(by: .productium)
        state.appOpens.append(Date())
        log(.lifecycle, "foreground")
        if let link = LocalStore.defaults.string(forKey: LocalStore.Key.pendingDeepLink) {
            deepLink = link
            LocalStore.defaults.removeObject(forKey: LocalStore.Key.pendingDeepLink)
        }
        if Date().timeIntervalSince(lastRefresh) > 5 * 60 { Task { await refresh() } } else { replan() }
    }

    func refresh(full: Bool = true) async {
        lastRefresh = Date()
        await syncHealth()
        await syncMotion()
        estimateSleep()
        syncCalendar()
        syncScreen()
        learnCapacities()
        if let note = state.taper.update(days: state.screen, now: Date(), calendar: cal) {
            toast = note
        }
        state.prune(now: Date())
        recordMissedBlocks()
        replan()
        if full {
            serverOnline = await ClaudeClient.shared.ping()
            await insightPass()
            await refreshServerUsage()
            await refreshSubscription()
        }
    }

    /// The timetable as `Commitment`s, for the readers that haven't moved to entries yet (marker parsing, place offers,
    /// motion routine learning, calendar twins). Entries are the source of truth.
    var legacyCommitments: [Commitment] { Timetable.commitments(from: state.entries, tree: state.categories, calendar: cal) }

    /// The log as instants (starts and ends) over the last `days` days, for the estimators that work on instants.
    func recentCheckIns(days: Int = 21) -> [CheckIn] {
        let now = Date()
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: now)) ?? now
        return CheckIns.derive(state.entries, tree: state.categories, in: DateInterval(start: start, end: now), now: now,
                               book: state.dayRules, calendar: cal)
    }

    /// How long getting ready and the trips to and from school take, read from the log (O4: not stored).
    var routines: [Routine] {
        Routine.fromLog(state.entries, tree: state.categories, now: Date(), book: state.dayRules, calendar: cal)
    }

    var itemsById: [UUID: WorkItem] { Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) }) }

    func replan() {
        let now = Date()
        let started = ContinuousClock.now
        var locked: [PlannedBlock] = []
        if var b = Sessions.block(for: running, in: state.plan, now: now) {
            b.end = max(b.end, now.addingTimeInterval(60))
            locked = [b]
        } else if let cur = state.plan.current(at: now), cur.isStudy, !Sessions.isWorked(cur, entries: state.entries, now: now) {
            locked = [cur]
        }
        let input = plannerInput(now: now, locked: locked)
        PlanHistory.record(previous: state.plan, into: &state.planHistory, now: now, calendar: cal)
        PlanHistory.recordBedtimes(plan: state.plan, into: &state.plannedBedtimes, now: now, calendar: cal)
        state.plan = Planner.merge(previous: state.plan, new: Planner.plan(input), now: now, calendar: cal)
        // O3: the plan's future blocks are `plan` entries; what each day asked for is kept at its first plan.
        PlanEntries.replace(in: &state.entries, with: PlanEntries.from(state.plan, items: state.items, now: now, calendar: cal), now: now)
        // N / B2: phone use during planned Sleep becomes sensor entries, and Sleep starts after the last pickup.
        let uses = Friction.log.sessions.compactMap { s in s.endedAt.map { EntryBuilder.PhoneUse(start: s.openedAt, end: $0) } }
        let written = EntryBuilder.phoneAfterBedtime(uses, entries: &state.entries, now: now)
        if !written.isEmpty { log(.sensor, "phone_after_bedtime", ["entries": "\(written.count)"]) }
        let todayKey = DayKeys.key(now, cal)
        if state.dayPlans[todayKey] == nil { state.dayPlans[todayKey] = Accountability.asked(by: state.plan, on: now, calendar: cal) }
        let took = started.duration(to: .now)
        log(.planner, "replan", [
            "ms": "\(Int(took.components.seconds * 1000 + took.components.attoseconds / 1_000_000_000_000_000))",
            "blocks": "\(state.plan.blocks.count)", "warnings": "\(state.plan.warnings.count)",
            "warningText": state.plan.warnings.map(\.message).joined(separator: " | "),
            "shortfalls": state.plan.shortfalls.map { "\(Ref.task($0.key)) \($0.value)m" }.sorted().joined(separator: ", "),
        ].filter { !$0.value.isEmpty })
        save()
        applyPlanEffects()
    }

    func plannerInput(now: Date, locked: [PlannedBlock] = []) -> PlannerInput {
        PlannerInput(now: now, calendar: cal, items: state.items,
                     preferences: state.prefs, learned: state.learned,
                     health: state.health, moods: state.moods, locked: locked, routines: routines,
                     horizonDays: 14, policy: state.policy, beliefs: state.beliefs,
                     dayRules: state.dayRules,
                     entries: state.entries, rules: state.rules, categories: state.categories)
    }

    private func applyPlanEffects() {
        let plan = state.plan
        let now = Date()
        let nudges = nudgeInput(now: now)
        dueGap = GapDetector.due(gapInput(now: now), calendar: cal)
        if state.integrations.notifications { scheduleGapQuestion(now: now) }
        if state.integrations.notifications {
            let planned = NudgePlanner.plan(nudges)
            log(.notification, "scheduled", ["count": "\(planned.count)", "next": planned.first.map { "\($0.title) at \($0.at)" } ?? "none"])
            NotificationService.schedule(planned)
            NotificationService.scheduleHousekeeping(expiry: signatureExpiry)
        }
        let n = state.prefs.nudges
        LocalStore.defaults.set(n.scrollCheckIns && state.integrations.notifications ? n.level.scrollCheckIns : [],
                                  forKey: LocalStore.Key.scrollCheckIns)
        syncAlarms(nudges)
        if state.integrations.calendarExport { CalendarService.shared.export(plan: plan) }
    }

    /// Both alarm toggles feed one wanted list; an off toggle means its alarms are cancelled, not left behind.
    func syncAlarms(_ input: NudgeInput? = nil) {
        // O4: the wake alarm is the planned Sleep's alert; your own alarms are entries' alerts (approved only, J).
        let entryAlarms = AlarmPlanner.entryAlarms(state.entries, now: Date(), allowed: state.integrations.alarms,
                                                   wake: state.prefs.wakeAlarms, book: state.dayRules, calendar: cal)
        AlarmService.sync(AlarmPlanner.desired(input ?? nudgeInput(), entryAlarms: entryAlarms))
    }

    func nudgeInput(now: Date = Date()) -> NudgeInput {
        let answered = Sessions.worked(plan: state.plan, entries: state.entries, now: now)
        let snoozed = Set(state.snoozed.filter { $0.value > now }.map(\.key))
        return NudgeInput(now: now, calendar: cal, plan: state.plan, items: state.items, settings: state.prefs.nudges,
                          startedBlockId: Sessions.block(for: running, in: state.plan, now: now)?.id, answeredBlockIds: answered, snoozedBlockIds: snoozed,
                          markerPrompts: markerPrompts(), timeLabel: { $0.formatted(date: .omitted, time: .shortened) },
                          policy: state.policy, dayRules: state.dayRules)
    }

    var currentBlock: PlannedBlock? { state.plan.current(at: Date()) }

    func todayBlocks(_ date: Date = Date()) -> [PlannedBlock] {
        state.plan.blocks(on: date, calendar: cal).filter { $0.kind != .sleep }
    }

    /// Study blocks that ended in the last 36 hours with no time tracked on them and no answer ("No") yet.
    var pendingOutcomes: [PlannedBlock] {
        Sessions.pending(plan: state.plan, entries: state.entries, now: Date()).filter { state.snoozed[$0.id] == nil }
    }

    var activeWarnings: [PlanWarning] {
        state.plan.warnings.filter { !state.dismissed.contains($0.message) }
    }

    /// How a planned block went. Done / partly = time tracked on the task (an entry); "No" is remembered so the block
    /// isn't asked about or counted as missed twice. Learning, put-off history and the reward moment follow.
    func logOutcome(blockId: UUID, status: OutcomeStatus, actualMinutes: Int? = nil, reason: String? = nil) {
        guard let b = state.plan.blocks.first(where: { $0.id == blockId }), !Sessions.isWorked(b, entries: state.entries, now: Date()) else { return }
        let actual = actualMinutes ?? (status == .done ? b.minutes : status == .partial ? b.minutes / 2 : 0)
        let idx = b.itemId.flatMap { id in state.items.firstIndex { $0.id == id } }
        if status != .skipped, actual > 0 {
            let item = idx.map { state.items[$0] }
            let e = Entry(title: b.title, start: b.start, end: b.start.addingTimeInterval(Double(actual) * 60),
                          category: item?.category ?? CategoryTree.studying, taskId: b.itemId, source: .you, createdAt: Date())
            var entries = state.entries
            TimeLog.insert(e, now: Date(), entries: &entries, calendar: cal)
            state.entries = entries
        } else if status == .skipped {
            state.snoozed[blockId] = Date().addingTimeInterval(40 * 3600)
        }
        let result = SessionResult(itemId: b.itemId, kind: idx.map { state.items[$0].kind }, plannedStart: b.start,
                                   plannedMinutes: b.minutes, actualMinutes: actual, status: status)
        NotificationService.cancel(blockId: blockId)
        state.learned.record(session: result, calendar: cal)
        if status != .skipped, let i = idx { state.items[i].completedMinutes += actual }
        log(.log, "session", ["block": b.title, "status": status.rawValue, "minutes": "\(actual)"])
        if status == .skipped {
            Avoidance.record(reason == nil ? .skipped : .cantToday, itemId: b.itemId, in: &state.items, at: Date(), reason: reason, blockId: blockId)
            toast = "No problem. It's been moved to a better slot."
        }
        replan()
    }

    // MARK: Focus: a running entry on a task

    /// What the full-screen focus view shows: the running entry that's on a task, and the block it's for.
    struct FocusInfo {
        var entry: Entry
        var block: PlannedBlock?
        var plannedEnd: Date
        var title: String { entry.title }
        var startedAt: Date { entry.start }
    }

    var running: Entry? { TimeLog.running(state.entries) }

    var focus: FocusInfo? {
        guard let e = running, e.taskId != nil else { return nil }
        let block = Sessions.block(for: e, in: state.plan, now: Date())
        let planned = block.map { max($0.end, e.start.addingTimeInterval(Double($0.minutes) * 60)) }
            ?? e.start.addingTimeInterval(state.learned.focusMinutes * 60)
        return FocusInfo(entry: e, block: block, plannedEnd: planned)
    }

    func startFocus(_ b: PlannedBlock) {
        let now = Date()
        let item = b.itemId.flatMap { id in state.items.first { $0.id == id } }
        let e = Entry(title: b.title, start: now, end: nil, category: item?.category ?? CategoryTree.studying,
                      topics: item?.topics ?? [], taskId: b.itemId, source: .you, createdAt: now)
        var entries = state.entries
        TimeLog.start(e, at: now, now: now, entries: &entries, calendar: cal)
        state.entries = entries
        state.snoozed[b.id] = nil
        NotificationService.cancel(blockId: b.id)
        log(.log, "focus_start", ["block": b.title])
        syncAlarms()
        save()
    }

    func startNowOrNext() {
        guard focus == nil else { return }
        let now = Date()
        if let b = state.plan.current(at: now), b.isStudy { startFocus(b); return }
        if let n = state.plan.next(after: now), n.isStudy, n.start.timeIntervalSince(now) < 90 * 60 { startFocus(n); return }
        if let n = state.plan.next(after: now), n.isStudy, let item = n.itemId.flatMap({ id in state.items.first { $0.id == id } }) {
            focusNow(on: item)
        }
    }

    func startFocus(blockId: UUID) {
        guard focus == nil else { return }
        if let b = state.plan.blocks.first(where: { $0.id == blockId }), b.isStudy, b.end > Date() { startFocus(b) }
        else { startNowOrNext() }
    }

    func recordMissedBlocks() {
        Avoidance.recordMissed(pendingOutcomes.filter { !state.snoozed.keys.contains($0.id) }, in: &state.items, at: Date())
    }

    func snooze(blockId: UUID, minutes: Int = 10) {
        guard let b = state.plan.blocks.first(where: { $0.id == blockId }) else { return }
        state.snoozed[blockId] = Date().addingTimeInterval(Double(minutes) * 60)
        Avoidance.record(.snoozed, itemId: b.itemId, in: &state.items, at: Date(), blockId: blockId)
        NotificationService.snooze(blockId: blockId, title: b.title, minutes: minutes)
        syncAlarms()
        save()
    }

    func focusNow(on item: WorkItem) {
        let mins = Int(state.learned.focusMinutes.rounded())
        let b = PlannedBlock(kind: item.kind.isMemoryBased ? .review : .work, start: Date(), end: Date().addingTimeInterval(Double(mins) * 60),
                             title: item.title, itemId: item.id, hint: "Started on your own. Nice.")
        state.plan.blocks.append(b)
        state.plan.blocks.sort { $0.start < $1.start }
        startFocus(b)
    }

    func endFocus(_ status: OutcomeStatus) {
        guard let f = focus else { return }
        let now = Date()
        let elapsed = max(1, Int(now.timeIntervalSince(f.startedAt) / 60))
        let item = f.entry.taskId.flatMap { id in state.items.first { $0.id == id } }
        func percent(_ done: Int) -> Int? { item.flatMap { $0.estimateMinutes > 0 ? min(100, done * 100 / $0.estimateMinutes) : nil } }
        let before = percent(item?.completedMinutes ?? 0)
        let totalBefore = state.entries.filter { $0.taskId != nil && $0.source != .plan && !$0.isRunning }
            .reduce(0) { $0 + $1.minutes(now: now) }
        var entries = state.entries
        if status == .skipped {
            // Couldn't focus: nothing was done, so nothing is logged.
            entries.removeAll { $0.id == f.entry.id }
        } else {
            TimeLog.stop(at: now, entries: &entries, calendar: cal)
        }
        state.entries = entries
        let idx = item.flatMap { it in state.items.firstIndex { $0.id == it.id } }
        let result = SessionResult(itemId: item?.id, kind: item?.kind, plannedStart: f.startedAt,
                                   plannedMinutes: f.block?.minutes ?? elapsed, actualMinutes: status == .skipped ? 0 : elapsed, status: status)
        state.learned.record(session: result, calendar: cal)
        if status != .skipped, let i = idx { state.items[i].completedMinutes += elapsed }
        if let b = f.block {
            NotificationService.cancel(blockId: b.id)
            if status == .skipped {
                state.snoozed[b.id] = now.addingTimeInterval(40 * 3600)
                Avoidance.record(.skipped, itemId: b.itemId, in: &state.items, at: now, reason: nil, blockId: b.id)
                toast = "No problem. It's been moved to a better slot."
            }
        }
        log(.log, "focus_end", ["status": status.rawValue, "minutes": "\(elapsed)"])
        replan()
        let after = percent(state.items.first { $0.id == item?.id }?.completedMinutes ?? 0)
        celebrate(.focusEnded(status: status, minutes: elapsed, title: item?.title, percentBefore: before, percentAfter: after,
                              freeAfterMinutes: nil, totalFocusMinutesBefore: totalBefore))
        let today = state.plan.blocks(on: now, calendar: cal).filter(\.isStudy)
        let worked = Sessions.worked(plan: state.plan, entries: state.entries, now: now)
        if status != .skipped, !today.isEmpty, today.allSatisfy({ worked.contains($0.id) }) {
            celebrate(.planFinished(freeMinutesLeft: nil))
        }
    }

    /// A moment for something the student did toward their goals (never for opening the app). `Rewards.respond`
    /// decides whether there is one, how big, and keeps the budget. Shown by `RootView`, and Off means nothing.
    func celebrate(_ event: RewardEvent) {
        guard let m = Rewards.respond(to: event, log: &state.rewards, settings: state.rewardSettings, now: Date(), calendar: cal) else { return }
        rewardMoment = m
        save()
    }

    func add(_ item: WorkItem) {
        let dup = state.items.contains {
            $0.title.lowercased() == item.title.lowercased() && cal.isDate($0.due, inSameDayAs: item.due)
        }
        guard !dup else { return }
        state.items.append(item)
        followUp(new: item)
    }

    func addManually(_ item: WorkItem) {
        state.items.append(item)
        replan()
        followUp(new: item)
    }

    func reopen(_ id: UUID) {
        guard let i = state.items.firstIndex(where: { $0.id == id }), state.items[i].isDone else { return }
        state.items[i].isDone = false
        state.items[i].doneAt = nil
        if let p = state.items[i].parentId, let j = state.items.firstIndex(where: { $0.id == p }) {
            state.items[j].isDone = false
            state.items[j].doneAt = nil
        }
        replan()
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
        let stepsLeft = it.parentId.map { p in state.items.filter { $0.parentId == p && $0.isOpen }.count } ?? 0
        let daysEarly = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: it.due)).day ?? 0)
        celebrate(.itemDone(title: it.title, isStep: it.parentId != nil, stepsLeft: stepsLeft, daysEarly: daysEarly))
        if it.completedMinutes >= 10 {
            state.learned.recordCompletion(kind: it.kind, estimated: it.estimateMinutes, actual: it.completedMinutes)
        }
        if let p = it.parentId, !state.items.contains(where: { $0.parentId == p && $0.isOpen }) { complete(p) }
        replan()
    }

    func delete(_ id: UUID) {
        state.items.removeAll { $0.id == id || $0.parentId == id }
        replan()
    }

    func logMarker(_ phrase: String, source: MarkerSource = .manual, at: Date = Date()) {
        let evs = MarkerParser.parse(phrase, at: at, commitments: legacyCommitments, calendar: cal, source: source)
        guard !evs.isEmpty else { return }
        var entries = state.entries, tree = state.categories
        CheckIns.apply(evs, to: &entries, tree: &tree, now: Date(), calendar: cal)
        state.entries = entries
        state.categories = tree
        log(.log, "check_in", ["phrase": phrase, "source": source.rawValue, "events": "\(evs.count)"])
        if source != .geofence { offerPlace(after: evs) }
        if evs.contains(where: { $0.category == .sleep }) { estimateSleep(); replan() } else { save() }
    }

    // Places that learn themselves: ask to save a place you've just said you're at, or keep returning to.
    var placeOffer: PlaceOffer?
    /// The celebration being shown now (cleared by `RootView` after a few seconds).
    var rewardMoment: RewardMoment?

    func recordVisit(_ v: PlaceVisit) {
        log(.sensor, "visit", ["arrival": "\(v.arrival)", "departure": v.departure.map { "\($0)" } ?? "open"])
        guard let i = state.visits.firstIndex(where: { $0.arrival == v.arrival }) else {
            state.visits = Array((state.visits + [v]).suffix(120))
            offerFrequentPlace()
            return
        }
        state.visits[i] = v
        offerFrequentPlace()
    }

    private func offerFrequentPlace() {
        save()
        guard placeOffer == nil else { return }
        let declined = state.declinedPlaces.compactMap { id -> (Double, Double)? in
            let p = id.split(separator: "_")
            guard p.count == 3, p[0] == "visit", let a = Double(p[1]), let b = Double(p[2]) else { return nil }
            return (a / 1000, b / 1000)
        }
        if let offer = PlaceSuggester.frequent(state.visits, places: state.places, declinedSpots: declined, calendar: cal),
           !state.declinedPlaces.contains(offer.id) {
            placeOffer = offer
        }
    }

    private func offerPlace(after evs: [CheckIn]) {
        guard placeOffer == nil, LocationService.shared.status != .denied,
              let found = PlaceSuggester.offer(after: evs, places: state.places, commitments: legacyCommitments,
                                               declined: state.declinedPlaces) else { return }
        Task {
            guard let fix = await LocationService.shared.currentLocation() else { return }
            var offer = found
            offer.latitude = fix.coordinate.latitude
            offer.longitude = fix.coordinate.longitude
            placeOffer = offer
        }
    }

    func acceptPlaceOffer(name: String? = nil) {
        guard let o = placeOffer, let lat = o.latitude, let lon = o.longitude else { placeOffer = nil; return }
        let chosen = (name ?? o.name).trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty else { return }
        let id = o.needsName ? PlaceSuggester.slug(chosen) : o.id
        state.places.removeAll { $0.id == id }
        state.places.append(SavedPlace(id: id, name: chosen, latitude: lat, longitude: lon))
        state.integrations.location = true
        LocationService.shared.visitsWanted = true
        LocationService.shared.requestAlways()
        LocationService.shared.monitor(state.places)
        placeOffer = nil
        toast = "\(chosen) saved. Arriving and leaving will be noticed."
        save()
    }

    func declinePlaceOffer() {
        if let o = placeOffer { state.declinedPlaces.insert(o.id) }
        placeOffer = nil
        save()
    }

    private func handleGeofence(_ place: String, entered: Bool) {
        log(.sensor, "geofence", ["place": place, "entered": "\(entered)"])
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
        if place == "home" && entered { arrivedHome() }
    }

    private func arrivedHome() {
        if state.integrations.notifications, let intent = state.policy.intentions.first(where: {
            $0.trigger == .arriveHome && ($0.weekdays.isEmpty || $0.weekdays.contains(cal.component(.weekday, from: Date())))
        }) {
            NotificationService.notify("You're home", intent.text, deeplink: "productium://now")
            return
        }
        guard state.integrations.notifications, state.prefs.nudges.arrivingHome, state.prefs.nudges.level != .gentle,
              focus == nil else { return }
        let now = Date()
        if let b = state.plan.current(at: now), b.isStudy, !Sessions.isWorked(b, entries: state.entries, now: now) {
            NotificationService.notify("Welcome home", "\(b.title) is on now, until \(b.end.hm). Start when you're in the door.",
                                       deeplink: "productium://now", blockId: b.id)
        } else if let n = state.plan.blocks.first(where: { $0.isStudy && $0.start > now && $0.start < now.addingTimeInterval(2 * 3600) }) {
            let mins = Int(n.start.timeIntervalSince(now) / 60)
            NotificationService.notify("Welcome home", "\(mins) minutes free, then \(n.title) at \(n.start.hm). Snack, change, then start.",
                                       deeplink: "productium://now", blockId: n.id)
        }
    }

    private func markerPrompts() -> [(Date, String)] {
        guard !state.integrations.location else { return [] }
        var out: [(Date, String)] = []
        let now = Date()
        for d in 0...1 {
            guard let day = cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: now)) else { continue }
            let wd = cal.component(.weekday, from: day)
            let school = legacyCommitments.filter { $0.kind == .school && $0.weekdays.contains(wd) }
            guard let first = school.min(by: { $0.start < $1.start }), let last = school.max(by: { $0.end < $1.end }) else { continue }
            let rs = routines
            let to = rs.first { $0.id == "to_school" }
            let from = rs.first { $0.id == "from_school" }
            if let to, to.samples.count < 5, let s = cal.date(bySettingHour: first.start.hour, minute: first.start.minute, second: 0, of: day) {
                out.append((s.addingTimeInterval(-Double(to.minutes + 5) * 60), "Left home"))
            }
            if let from, from.samples.count < 5, let e = cal.date(bySettingHour: last.end.hour, minute: last.end.minute, second: 0, of: day) {
                out.append((e.addingTimeInterval(Double(from.minutes) * 60), "Home"))
            }
        }
        return out.filter { $0.0 > now }
    }

    var signatureExpiry: Date? { Signature.expiry }

    func logMood(_ mood: Int, energy: Int?, note: String?) {
        state.moods.append(MoodEntry(mood: mood, energy: energy, note: note))
        if state.integrations.health { HealthService.shared.logStateOfMind(mood) }
        replan()
    }

    var supportSuggested: Bool { Wellbeing.supportSuggested(moods: state.moods, now: Date()) }

    var todayMood: MoodEntry? { state.moods.filter { cal.isDateInToday($0.at) }.max { $0.at < $1.at } }

    private func syncHealth() async {
        guard state.integrations.health else { return }
        state.integrations.healthNeedsRequest = await HealthService.shared.requestNeeded()
        let days = await HealthService.shared.days(back: 21, calendar: cal)
        log(.health, "read", ["days": "\(days.count)", "needsRequest": "\(state.integrations.healthNeedsRequest)"])
        guard !days.isEmpty else { return }
        var byDay = Dictionary(state.health.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for d in days { byDay[cal.startOfDay(for: d.day)] = d }
        state.health = byDay.values.sorted { $0.day < $1.day }
        // Moods logged elsewhere (Apple Watch, the Health app) come in once, unless one is already there within 10 minutes.
        for (at, mood) in await HealthService.shared.stateOfMind(back: 14)
        where !state.moods.contains(where: { abs($0.at.timeIntervalSince(at)) < 600 }) {
            state.moods.append(MoodEntry(at: at, mood: mood, note: "From Health"))
        }
        state.moods.sort { $0.at < $1.at }
        let mids = HealthService.freeDayMidpoints(Array(state.health.suffix(28)), prefs: state.prefs, cal: cal)
        if let c = LearnedModel.chronotype(fromFreeDaySleepMidpointsHours: mids) { state.learned.inferredChronotype = c }
    }

    private func syncMotion() async {
        guard state.integrations.motion else { return }
        let now = Date()
        let from = now.addingTimeInterval(-7 * 86400)
        let samples = await MotionService.shared.samples(from: from, to: now)
        log(.sensor, "motion_read", ["samples": "\(samples.count)"])
        guard !samples.isEmpty else { return }
        let fresh = MotionTimeline.spans(samples, until: now, previous: state.motion)
        state.motion = MotionTimeline.merge(state.motion, with: fresh, from: samples.map(\.at).min() ?? from)
    }

    func isSchoolDay(_ d: Date) -> Bool {
        Days.isSchoolDay(d, entries: state.entries, tree: state.categories, prefs: state.prefs, book: state.dayRules, calendar: cal)
    }

    /// The last `n` finished days: planned and done study, and the free time kept after school.
    func dayRecords(back n: Int) -> [DayRecord] {
        let today = cal.startOfDay(for: Date())
        let days = (1...n).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        return CapacityLearner.records(days: days, planHistory: state.planHistory, dayPlans: state.dayPlans, entries: state.entries,
                                       tree: state.categories, book: state.dayRules, now: Date(), progress: state.progress,
                                       isSchoolDay: isSchoolDay,
                                       eveningFree: { d in
                                           let segs = self.segments(on: d)
                                           guard let end = segs.filter({ [.school, .activities].contains($0.category) }).map(\.end).max() else { return nil }
                                           return segs.filter { $0.category == .free && $0.start >= end }.reduce(0) { $0 + $1.minutes }
                                       }, calendar: cal)
    }

    /// Moments the phone was in use: app opens, scrolling, and check-ins typed or tapped.
    var phoneUse: [Date] {
        state.appOpens + Friction.log.sessions.flatMap { [$0.openedAt] + ($0.endedAt.map { [$0] } ?? []) }
            + state.entries.filter { $0.source == .you && $0.repeats == nil && $0.createdAt > Date().addingTimeInterval(-21 * 86400) }.map(\.createdAt)
    }

    /// Changes the state the box and the insight pass work on, about-me included.
    @discardableResult
    func editDumpState<T>(_ change: (inout DumpState) -> T) -> T {
        var ds = state.dumpState
        ds.aboutMe = aboutMe
        let result = change(&ds)
        state.dumpState = ds
        if ds.aboutMe != aboutMe { aboutMe = ds.aboutMe }
        return result
    }

    private func learnCapacities() {
        state.beliefs = CapacityLearner.learn(state.beliefs, days: dayRecords(back: CapacityLearner.window), entries: state.entries,
                                              tree: state.categories, book: state.dayRules, now: Date(), calendar: cal)
    }

    var healthStatus: HealthStatus {
        HealthStatus.resolve(wantsHealth: state.integrations.health, requestNeeded: state.integrations.healthNeedsRequest,
                             days: state.health)
    }

    func estimateSleep() {
        let today = cal.startOfDay(for: Date())
        let days = (0..<14).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        // First Pickup from Screen Time screenshots: you woke at or before it.
        var pickups: [Date: Date] = [:]
        for d in state.screen {
            if let m = d.firstPickup, d.source == "screenshot" {
                pickups[cal.startOfDay(for: d.day)] = cal.date(byAdding: .minute, value: m, to: cal.startOfDay(for: d.day))
            }
        }
        // The last time the charger went in between 6 pm the evening before and 3 am.
        let plugs = (LocalStore.defaults.array(forKey: LocalStore.Key.chargingTimes) as? [Double] ?? []).map { Date(timeIntervalSince1970: $0) }
        var charging: [Date: Date] = [:]
        for d in days.map({ cal.startOfDay(for: $0) }) {
            let from = d.addingTimeInterval(-6 * 3600), to = d.addingTimeInterval(3 * 3600)
            if let t = plugs.filter({ $0 >= from && $0 <= to }).max() { charging[d] = t }
        }
        state.health = SleepEstimator.fill(state.health, days: days, markers: recentCheckIns(), motion: state.motion,
                                           phoneUse: phoneUse, sleepNeedMinutes: state.prefs.sleepNeedMinutes, calendar: cal,
                                           firstPickups: pickups, charging: charging)
    }

    private func syncCalendar() {
        guard state.integrations.calendarImport, CalendarService.shared.authorized else { return }
        let events = CalendarService.shared.events(days: 14)
        let start = cal.startOfDay(for: Date())
        CalendarEntries.merge(events, into: &state.entries,
                              window: DateInterval(start: start, end: start.addingTimeInterval(14 * 86400)),
                              book: state.dayRules, now: Date(), calendar: cal)
        log(.sensor, "calendar_read", ["events": "\(events.count)"])
        for cand in CalendarService.shared.deadlineCandidates(days: 30) {
            if let i = state.items.firstIndex(where: { $0.externalId == cand.externalId }) {
                state.items[i].due = cand.due
            } else {
                add(cand)
            }
        }
    }

    private func syncScreen() {
        let screen = state.screen, now = Date(), cal = self.cal
        ScrollingApps.register(Friction.log.sessions.map { ($0.app, nil) }, into: &state.scrollingApps)
        let measured = Friction.update { log in
            log.resolve(now: now)
            log.calibrate(with: screen, calendar: cal)
            return log.screenDays(before: now, calendar: cal)
        }
        if !measured.isEmpty {
            state.screen = state.screen.merging(measured: measured, calendar: cal).map { $0.recomputed(state.scrollingApps) }
        }
    }

    /// The weekly note and the quiet insight pass (v1.1 D.2): one Sonnet call. The note is shown; the changes are
    /// applied at once and only listed in What Productium Thinks → Changes. `force` is pull-to-refresh.
    func insightPass(force: Bool = false, asked question: String? = nil) async {
        let now = Date()
        guard !busy.contains("review") else { return }
        let deferrals = InsightPass.deferrals(items: state.items, since: now.addingTimeInterval(-14 * 86400))
        let days = dayRecords(back: 14)
        let weeklyDue: Bool
        if let at = state.reviewAt {
            weeklyDue = now.timeIntervalSince(at) > (force ? 600 : 6.5 * 86400)
        } else {
            weeklyDue = force || state.entries.filter { $0.taskId != nil && $0.source != .plan }.count >= 5
        }
        guard let trigger = InsightPass.trigger(now: now, lastRun: state.insightAt, deferrals: deferrals, days: days,
                                                weeklyDue: weeklyDue, asked: question != nil, budgetAllows: aiAllowed(.review),
                                                calendar: cal) else { return }
        busy.insert("review")
        defer { busy.remove("review") }
        let convos = state.archive.conversations.suffix(5).compactMap(\.title) + state.conversation.turns.suffix(5).map { String($0.text.prefix(120)) }
        let input = InsightInput(now: now, calendar: cal, trigger: trigger, question: question, aboutMe: aboutMe,
                                 beliefs: state.beliefs, routines: routines, deferrals: deferrals, days: days,
                                 summary: Insights.summarize(dayTotals(last: 7), learned: state.learned), policy: state.policy,
                                 feedback: state.changes.feedback, changes: state.changes.changeSummary(now: now),
                                 conversations: convos, items: state.items, plan: state.plan, moods: state.moods,
                                 taper: state.taper, learned: state.learned,
                                 dayRules: state.dayRules,
                                 metrics: MetricsExport.summary(metricSeries(), now: now, calendar: cal))
        guard let out = try? await ClaudeClient.shared.structured(
            feature: .review, system: InsightPass.system(), user: InsightPass.request(input), schema: InsightPass.schema,
            as: InsightPass.Output.self, maxTokens: 1500, accept: { !$0.headline.isEmpty }) else { return }
        state.insightAt = now
        state.review = out.review
        state.reviewAt = now
        let model = AIFeature.review.route.model
        let run = InsightRun(at: now, note: out.headline, model: model)
        var drafts = InsightPass.drafts(out, runId: run.id, items: state.items, now: now, model: model, calendar: cal)
        // F6: with four weeks of data, celebrations that made no difference to the next day's focus are turned down.
        let impact = RewardImpact.evaluate(log: state.rewards, entries: state.entries, tree: state.categories, now: now, calendar: cal)
        if let level = RewardImpact.turnDown(impact, settings: state.rewardSettings), let i = impact {
            drafts.append(LoggedChange(runId: run.id, change: .celebrations(to: level, from: state.rewardSettings.level),
                                       reason: "Focus the day after a celebration was \(Int(i.withMoments.rounded())) min, and \(Int(i.without.rounded())) min after none, over \(i.daysWith + i.daysWithout) days",
                                       evidence: [], model: "code", at: now))
        }
        editDumpState { state.changes.apply(run, drafts, to: &$0, now: now) }
        // J4: alarms are only proposed; they wait in Review and Settings → Alarms for Allow.
        let proposed = InsightPass.proposals(out, items: state.items, now: now, calendar: cal)
        state.approvals += proposed
        if !proposed.isEmpty { log(.ai, "alarm_proposed", ["why": proposed.map(\.why).joined(separator: " | ")]) }
        replan()
    }

    func removeReminder(_ id: UUID) {
        state.policy.intentions.removeAll { $0.id == id }
        replan()
    }

    func revertChange(_ id: UUID) {
        let now = Date()
        guard editDumpState({ state.changes.revert(id, in: &$0, now: now) }) else { return }
        replan()
    }

    func neverChange(_ id: UUID) {
        let now = Date()
        editDumpState { state.changes.neverChange(id, in: &$0, now: now) }
        replan()
    }

    func unpin(_ target: String) {
        state.changes.unpin(target)
        save()
    }

    var dueGap: MysteryGap?

    func gapInput(now: Date = Date()) -> GapInput {
        GapInput(now: now, day: dayInputs(cal.startOfDay(for: now)), scrolling: Friction.log.sessions, phoneUse: phoneUse,
                 plan: state.plan, focusing: focus != nil, log: state.gaps,
                 explained: state.visits.map { v in DateInterval(start: v.arrival, end: max(v.arrival, v.departure ?? now)) })
    }

    private func scheduleGapQuestion(now: Date) {
        state.gaps.asked.removeAll { $0.answer == nil && $0.askedAt > now }
        guard let next = GapDetector.nextAsk(gapInput(now: now), calendar: cal) else {
            NotificationService.cancelGapQuestion()
            return
        }
        NotificationService.scheduleGapQuestion(GapDetector.question(next.gap, calendar: cal), start: next.gap.start,
                                                end: next.gap.end, at: next.at)
        state.gaps.asked.append(AskedGap(start: next.gap.start, end: next.gap.end, askedAt: next.at))
    }

    func dismissGap(_ gap: MysteryGap) {
        state.gaps.asked.append(AskedGap(start: gap.start, end: gap.end, askedAt: Date(), answer: ""))
        dueGap = nil
        save()
    }

    func answerGap(_ text: String, gap: MysteryGap) async {
        let known = state.gaps.asked
        var asked = state.gaps.asked.first { abs($0.start.timeIntervalSince(gap.start)) < 60 }
            ?? AskedGap(start: gap.start, end: gap.end, askedAt: Date())
        state.gaps.asked.removeAll { $0.id == asked.id }
        asked.end = gap.end
        asked.answer = text
        if let markers = GapAnswer.markers(for: text, gap: gap, commitments: legacyCommitments, known: known, calendar: cal) {
            var entries = state.entries, tree = state.categories
            CheckIns.apply(markers, to: &entries, tree: &tree, now: Date(), calendar: cal)
            state.entries = entries
            state.categories = tree
            asked.activity = markers.first?.activity
            state.gaps.asked.append(asked)
            dueGap = nil
            replan()
        } else {
            state.gaps.asked.append(asked)
            dueGap = nil
            await dump(GapAnswer.boxText(text, gap: gap, calendar: cal))
        }
    }

    func dayInputs(_ day: Date) -> DayInputs {
        let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
        return DayInputs(day: day, entries: state.entries, categories: state.categories,
                         routines: routines, itemsById: itemsById,
                         health: state.health.first { cal.isDate($0.day, inSameDayAs: day) },
                         nextHealth: state.health.first { cal.isDate($0.day, inSameDayAs: next) },
                         screen: state.screen.first { cal.isDate($0.day, inSameDayAs: day) }, prefs: state.prefs,
                         motion: state.motion, scrollSessions: Friction.log.sessions,
                         scrollingApps: state.scrollingApps, progress: state.progress, dayRules: state.dayRules)
    }

    func setScrolling(_ app: String, _ on: Bool) {
        state.scrollingApps[app] = on
        state.screen = state.screen.map { $0.recomputed(state.scrollingApps) }
        state.screenAverages = state.screenAverages.map { $0.recomputed(state.scrollingApps) }
        replan()
    }

    /// Every Life Metric as a daily series (Part G). Built on demand; it's a few hundred points.
    func metricSeries(days n: Int = 120) -> [MetricID: MetricSeries] {
        let today = cal.startOfDay(for: Date())
        let days = (0..<n).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        var planned: [Date: Int] = [:]
        for d in days {
            let m = PlanHistory.plannedMinutes(on: d, history: state.planHistory, plan: state.plan, calendar: cal)
            if m > 0 { planned[d] = m }
        }
        let x = MetricsInput(days: days, screen: ScreenSeries.daily(screen: state.screen, averages: state.screenAverages, days: days, calendar: cal),
                             screenDays: state.screen, health: state.health, moods: state.moods, items: state.items,
                             progress: state.progress, entries: state.entries, categories: state.categories, now: Date(),
                             dayRules: state.dayRules, planned: planned,
                             sleepNeed: state.prefs.sleepNeedMinutes,
                             away: PlaceTime.awayMinutes(visits: state.visits, home: state.places.first { $0.id == "home" },
                                                         now: Date(), calendar: cal),
                             plannedBed: state.plannedBedtimes)
        return MetricsBuilder.series(x, calendar: cal)
    }

    func dayTotals(last n: Int, includeToday: Bool = false) -> [DayTotals] {
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { i -> DayTotals? in
            guard let d = cal.date(byAdding: .day, value: -(i + (includeToday ? 0 : 1)), to: today) else { return nil }
            let planned = PlanHistory.plannedMinutes(on: d, history: state.planHistory, plan: state.plan, calendar: cal)
            return Insights.dayTotals(dayInputs(d), plannedStudy: planned, moods: state.moods,
                                      screenTarget: state.taper.targetMinutes, calendar: cal, now: Date())
        }
    }

    func segments(on day: Date) -> [Segment] {
        TimelineBuilder.segments(dayInputs(day), calendar: cal, now: Date())
    }

    func recordUsage(_ feature: AIFeature, model: String, tokens: TokenCount, callId: UUID? = nil) {
        state.usage.record(UsageRecord(at: Date(), feature: feature, model: model, tokens: tokens, callId: callId))
        save()
    }

    func logCall(_ call: AICall) {
        callLog.append(call)
        callLogSave?.cancel()
        let snapshot = callLog
        callLogSave = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            CallLogStore.save(snapshot)
        }
    }

    func clearCallLog() {
        callLog = AICallLog()
        CallLogStore.save(callLog)
    }

    func call(_ id: UUID?) -> AICall? { id.flatMap { id in callLog.calls.last { $0.id == id } } }

    func refreshSubscription() async {
        guard ClaudeClient.shared.isConfigured else { return }
        if let s = await ClaudeClient.shared.subscription() { subscription = s }
    }

    func aiAllowed(_ feature: AIFeature) -> Bool {
        ClaudeClient.shared.isConfigured && state.usage.allows(feature, now: Date(), calendar: cal)
    }

    var tokensToday: Int { state.usage.total(on: Date(), calendar: cal).counted }
    var usageFraction: Double { state.usage.fractionUsed(now: Date(), calendar: cal) }

    func refreshServerUsage() async {
        guard ClaudeClient.shared.isConfigured else { return }
        if let u = await ClaudeClient.shared.usage() { serverUsage = u }
    }

    func decompose(_ id: UUID) async {
        guard let item = state.items.first(where: { $0.id == id }), aiAllowed(.breakdown),
              !state.items.contains(where: { $0.parentId == id }) else { return }
        busy.insert("decompose")
        defer { busy.remove("decompose") }
        guard let d = try? await ClaudeClient.shared.structured(
            feature: .breakdown, system: Prompts.decomposition(),
            user: Prompts.decompositionRequest(item: item, now: Date(), timeZone: cal.timeZone, aboutMe: aboutMe),
            schema: Schemas.decomposition, as: Decomposition.self, maxTokens: 700,
            accept: { !$0.steps.isEmpty }) else { return }
        var added = 0
        for s in d.steps {
            let p = ParsedItem(title: "\(item.title): \(s.title)", kind: s.kind, subject: item.subject, due: s.due,
                               estimateMinutes: s.estimateMinutes, importance: item.importance, difficulty: item.difficulty, topics: nil)
            if var child = AIMapper.item(p, timeZone: cal.timeZone, parentId: item.id) {
                child.due = min(child.due, item.due)
                state.items.append(child)
                added += 1
            }
        }
        guard added > 0 else { return }
        toast = "Broke “\(item.title)” into \(added) steps."
        replan()
    }

    func makeCards(for item: WorkItem) async {
        guard aiAllowed(.flashcards), !item.topics.isEmpty else { return }
        guard let batch = try? await ClaudeClient.shared.structured(
            feature: .flashcards, system: Prompts.flashcards(),
            user: Prompts.flashcardsRequest(subject: item.subject, topics: item.topics, count: 8),
            schema: Schemas.cards, as: CardBatch.self, maxTokens: 900, cacheTTL: 86400,
            accept: { !$0.usable.isEmpty }) else { return }
        state.flashcards += batch.usable.map { Flashcard(itemId: item.id, subject: item.subject, front: $0.front, back: $0.back) }
        save()
    }

    func ensureGapContent() async {
        for t in state.items where t.kind.isMemoryBased && t.isOpen && !t.topics.isEmpty && t.due.timeIntervalSinceNow < 14 * 86400
            && !state.flashcards.contains(where: { $0.itemId == t.id }) {
            await makeCards(for: t)
        }
        guard aiAllowed(.reads), state.reads.filter({ $0.readAt == nil }).count < 2 else { return }
        let subjects = Array(Set(state.items.compactMap(\.subject))).sorted().prefix(4)
        guard let batch = try? await ClaudeClient.shared.structured(
            feature: .reads, system: Prompts.reads(),
            user: Prompts.readsRequest(interests: state.prefs.interests, subjects: Array(subjects), count: 3),
            schema: Schemas.reads, as: ReadBatch.self, maxTokens: 1100,
            accept: { !$0.usable.isEmpty }) else { return }
        state.reads += batch.usable.map { ReadPiece(title: $0.title, body: $0.body, subject: $0.subject, question: $0.question, source: "Claude") }
        save()
    }

    // MARK: The box (O6)

    var undoTurnId: UUID?
    @ObservationIgnored private var undoReceipt: BoxReceipt?
    @ObservationIgnored private var undoSide: SideSnapshot?

    /// What the side ops (`BoxSideOps`) can change; the receipt covers the rest.
    private struct SideSnapshot {
        var moods: [MoodEntry], screen: [ScreenDay], screenAverages: [ScreenDay], scrollingApps: [String: Bool]
        var prefs: Preferences, policy: BehaviourPolicy, aboutMe: AboutMe
    }

    private func clearUndo() {
        undoReceipt = nil
        undoSide = nil
        undoTurnId = nil
    }

    /// "school days Mon–Fri, sleep need 8h, sleep floor 7h, wake 6:45 on school days, notifications standard".
    var settingsLine: String {
        let p = state.prefs
        let names = cal.shortWeekdaySymbols
        let days = p.schoolDays.sorted()
        func name(_ d: Int) -> String { names[(d - 1) % 7] }
        var contiguous = days.count > 2
        for (x, y) in zip(days, days.dropFirst()) where y != x + 1 { contiguous = false }
        let school = days.isEmpty ? "none" : contiguous ? "\(name(days.first!))–\(name(days.last!))" : days.map(name).joined(separator: ", ")
        func hours(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60)h" : String(format: "%.1fh", Double(m) / 60) }
        return "school days \(school), sleep need \(hours(p.sleepNeedMinutes)), sleep floor \(hours(p.sleepFloorMinutes)), "
            + "wake \(p.schoolDayWake.hour):\(String(format: "%02d", p.schoolDayWake.minute)) on school days, notifications \(p.nudges.level.rawValue)"
    }

    private func boxState(entries: [Entry]) -> BoxState {
        BoxState(entries: entries, rules: state.rules, items: state.items, categories: state.categories,
                 dayRules: state.dayRules, sleepFloorMinutes: state.prefs.sleepFloorMinutes)
    }

    /// Writes the box's changes back. Plan entries aren't the box's: they're kept as they were and a replan renews them.
    private func absorb(_ b: BoxState, plan: [Entry]) {
        state.entries = b.entries + plan
        state.items = b.items
        state.rules = b.rules
        state.categories = b.categories
        state.dayRules = b.dayRules
    }

    @discardableResult
    func dump(_ raw: String, images: [AIImage] = []) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return false }
        busy.insert("dump")
        defer { busy.remove("dump") }
        let now = Date()
        let plan = state.entries.filter { $0.source == .plan }
        let mine = state.entries.filter { $0.source != .plan }
        let context = BoxContext.make(BoxContextInput(now: now, calendar: cal, state: boxState(entries: mine), planned: plan,
                                                      aboutMe: aboutMe.markdown, settings: settingsLine))
        let route = AIFeature.box.route
        let (req, content) = BoxTurn.request(state.conversation, context: context, text: text, images: images,
                                             model: route.model, effort: route.effort)
        do {
            let tz = cal.timeZone
            let (result, res, tokens) = try await ClaudeClient.shared.send(req, feature: .box) { BoxResult.read($0, timeZone: tz) }
            let turnId = UUID()
            let callId = callLog.calls.last { $0.feature == .box && $0.ok }?.id
            clearUndo()
            let side = SideSnapshot(moods: state.moods, screen: state.screen, screenAverages: state.screenAverages,
                                    scrollingApps: state.scrollingApps, prefs: state.prefs, policy: state.policy, aboutMe: aboutMe)
            let itemsBefore = state.items
            let beforeIds = Set(state.items.map(\.id))
            let ops = BoxSideOps.split(result.ops)
            var bs = boxState(entries: mine)
            var receipt = BoxApplier.apply(ops.box, to: &bs, now: now, calendar: cal)
            absorb(bs, plan: plan)
            var me = aboutMe
            let sideResult = BoxSideOps.apply(ops.side, to: &state, aboutMe: &me, now: now, calendar: cal)
            receipt.lines += sideResult.lines
            receipt.problems += sideResult.problems
            for f in result.facts {
                switch me.apply(f, by: .box, now: now) {
                case .success(let line): if line.hasPrefix("Noted") { receipt.lines.append(line) }
                case .failure(let why): receipt.problems.append("Didn't note “\(f.text.prefix(60))”: \(why)")
                }
            }
            if me != aboutMe { aboutMe = me }
            // Queries: the app computes every number; the reply's {q1.total} etc. are filled from the results.
            var reply = result.reply
            if !result.queries.isEmpty {
                let results = result.queries.map {
                    TimeQueryEngine.run($0, entries: state.entries, items: state.items, tree: state.categories, now: now,
                                        book: state.dayRules, calendar: cal)
                }
                reply = QueryText.fill(reply, results)
                receipt.problems += results.flatMap(\.problems)
            }
            if reply.isEmpty {
                reply = receipt.lines.isEmpty && receipt.held.isEmpty ? "I couldn't find anything to change in that. Try saying it another way." : "Done."
            }
            if res.isTruncated { reply += " That was a lot at once, so I may have missed the end. Check the list and send the rest again." }
            askForAlarmsIfWanted()
            Avoidance.recordDueMoves(before: itemsBefore, after: &state.items, at: now, reason: text)
            estimateSleep()
            BoxTurn.record(&state.conversation, at: now, text: text, content: content, response: res, result: result,
                           receipt: receipt, context: context, turnId: turnId, callId: callId, reply: reply)
            if let i = state.conversation.turns.lastIndex(where: { $0.id == turnId }) {
                state.conversation.turns[i].images = images
                state.conversation.turns[i].tokens = tokens
            }
            state.telemetry.boxTurn(receipt, turnId: turnId, message: text, ops: result.ops, at: now)
            for bad in result.unreadable { log(.gap, "unreadable_op", level: .warn, ["turn": turnId.uuidString, "op": bad]) }
            if let g = result.gap { state.telemetry.gap(g, said: reply, turnId: turnId, at: now) }
            if !receipt.lines.isEmpty || !receipt.before.isEmpty || !receipt.tasksBefore.isEmpty || !receipt.rulesBefore.isEmpty {
                undoTurnId = turnId
                undoReceipt = receipt
                undoSide = side
            }
            state.approvals += Approvals.from(receipt.held, turnId: turnId, at: now)
            replan()
            for item in state.items where !beforeIds.contains(item.id) { followUp(new: item) }
            return true
        } catch {
            let ai = error as? AIError
            let msg = ai?.errorDescription ?? "Couldn't reach your Claude server. Check that Tailscale is on, then send again."
            state.conversation.add(ConversationTurn(at: now, text: text, images: images, userContent: content, reply: msg,
                                                    callId: callLog.calls.last { $0.feature == .box }?.id, failed: true,
                                                    detail: ai?.detail ?? (ai == nil ? error.localizedDescription : nil),
                                                    context: context))
            log(.box, "failed", level: .error, ["message": text, "error": ai?.detail ?? error.localizedDescription])
            save()
            if let d = ai?.detail {
                try? Data(d.utf8).write(to: Persistence.url.deletingLastPathComponent().appendingPathComponent("last-ai-error.txt"))
            }
            return false
        }
    }

    /// The student has an alarm of their own: make sure iOS has been asked to allow alarms.
    private func askForAlarmsIfWanted() {
        guard state.entries.contains(where: { $0.source != .plan && $0.alert?.kind == .alarm }) else { return }
        Task { _ = await AlarmService.requestAuthorization() }
    }

    // MARK: Charts (F3)

    func run(_ q: TimeQuery) -> QueryResult {
        TimeQueryEngine.run(q, entries: state.entries, items: state.items, tree: state.categories, now: Date(),
                            book: state.dayRules, calendar: cal)
    }

    func pin(_ q: TimeQuery, title: String?) {
        guard !state.pinnedCharts.contains(where: { $0.query == q }) else { return }
        state.pinnedCharts.append(PinnedChart(title: title ?? "Chart", query: q, pinnedAt: Date()))
        log(.box, "chart_pinned", ["title": title ?? ""])
        toast = "Pinned to Review."
        save()
    }

    func unpin(chart id: UUID) {
        state.pinnedCharts.removeAll { $0.id == id }
        save()
    }

    /// Changes waiting for Approve / Decline (risky box ops, alarms the insight pass proposed), newest first.
    var approvals: [Approval] { Approvals.live(state.approvals, now: Date()).sorted { $0.at > $1.at } }

    /// Approve: applies the ops as they were asked (they were held, not changed). An alarm turns Full-Screen
    /// Alarms on if it was off (J2: Allow is the one tap).
    func approve(_ id: UUID) {
        guard let a = state.approvals.first(where: { $0.id == id }) else { return }
        state.approvals.removeAll { $0.id == id }
        let now = Date()
        let plan = state.entries.filter { $0.source == .plan }
        var bs = boxState(entries: state.entries.filter { $0.source != .plan })
        let receipt = BoxApplier.apply(a.ops, to: &bs, now: now, calendar: cal, approved: true)
        absorb(bs, plan: plan)
        if a.addsAlarm {
            if !state.integrations.alarms {
                state.integrations.alarms = true
                log(.alarm, "turned_on_by_allow")
            }
            Task { _ = await AlarmService.requestAuthorization() }
        }
        log(.box, "approved", ["source": a.source.rawValue, "why": a.why, "lines": receipt.lines.joined(separator: " | "),
                               "problems": receipt.problems.joined(separator: " | ")])
        toast = receipt.lines.first ?? "Done."
        replan()
    }

    func decline(_ id: UUID) {
        guard let a = state.approvals.first(where: { $0.id == id }) else { return }
        state.approvals.removeAll { $0.id == id }
        log(.box, "declined", ["source": a.source.rawValue, "why": a.why])
        save()
    }

    func undo() {
        guard let receipt = undoReceipt, let id = undoTurnId else { return }
        let plan = state.entries.filter { $0.source == .plan }
        var bs = boxState(entries: state.entries.filter { $0.source != .plan })
        BoxApplier.undo(receipt, in: &bs)
        absorb(bs, plan: plan)
        if let s = undoSide {
            state.moods = s.moods; state.screen = s.screen; state.screenAverages = s.screenAverages
            state.scrollingApps = s.scrollingApps; state.prefs = s.prefs; state.policy = s.policy
            if aboutMe != s.aboutMe { aboutMe = s.aboutMe }
        }
        if let i = state.conversation.turns.firstIndex(where: { $0.id == id }) {
            state.conversation.turns[i].applied.problems.append("The student undid all of these changes")
            state.conversation.turns[i].applied.changes = state.conversation.turns[i].applied.changes.map { "(undone) " + $0 }
        }
        log(.box, "undo", ["turn": id.uuidString])
        clearUndo()
        replan()
    }

    func clearConversation() {
        state.archive.archive(state.conversation, now: Date())
        state.conversation = Conversation(startedAt: Date())
        clearUndo()
        save()
    }

    func resumeConversation(_ id: UUID) {
        guard var c = state.archive.remove(id) else { return }
        state.archive.archive(state.conversation, now: Date())
        c.archivedAt = nil
        state.conversation = c
        clearUndo()
        save()
    }

    func deleteArchivedConversation(_ id: UUID) {
        _ = state.archive.remove(id)
        save()
    }

    private func followUp(new item: WorkItem) {
        if [.application, .essay, .project].contains(item.kind), item.due.timeIntervalSinceNow > 10 * 86400, item.parentId == nil {
            Task { await decompose(item.id) }
        }
        if item.kind.isMemoryBased, !item.topics.isEmpty { Task { await makeCards(for: item) } }
    }

    func saveAboutMe(editedText: String) {
        aboutMe = AboutMe.studentEdited(old: aboutMe.markdown, new: editedText)
    }

    func reviewCard(_ id: UUID, correct: Bool) {
        guard let i = state.flashcards.firstIndex(where: { $0.id == id }) else { return }
        let test = state.flashcards[i].itemId.flatMap { itemsById[$0]?.due }
        state.flashcards[i] = Leitner.review(state.flashcards[i], correct: correct, now: Date(), testDate: test)
        save()
    }

    func markRead(_ id: UUID) {
        if let i = state.reads.firstIndex(where: { $0.id == id }) { state.reads[i].readAt = Date(); save() }
    }

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
            ("daily-summary.csv", Data(Exporter.dailyCSV(days).utf8)),
            ("timeline.csv", Data(Exporter.segmentsCSV(segs).utf8)),
            ("tasks.csv", Data(Exporter.itemsCSV(state.items).utf8)),
            ("entries.csv", Data(Exporter.entriesCSV(state.entries, tree: state.categories).utf8)),
            ("moods.csv", Data(Exporter.moodsCSV(state.moods).utf8)),
            ("metrics.csv", Data(MetricsExport.csv(metricSeries(days: 365), calendar: cal).utf8)),
            ("plan.ics", Data(Exporter.ics(state.plan).utf8)),
        ]
        return try files.map { name, data in
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
    }

    func backupData() async throws -> Data {
        try ExportBundle.encoder().encode(await ExportService.make(self))
    }

    var backupFilename: String {
        "Productium Export \(Date().formatted(.iso8601.year().month().day()))"
    }

    func readBackup(from url: URL) throws -> RestorePreview {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let b = try ExportBundle.read(try Data(contentsOf: url))
        return RestorePreview(exportedAt: b.exportedAt, summary: b.summary, bundle: b)
    }

    func applyRestore(_ p: RestorePreview) {
        ExportService.restore(p.bundle, into: self)
        clearUndo()
        if state.integrations.location { LocationService.shared.monitor(state.places) }
        replan()
        toast = "Restored from the export."
    }

    func deleteEverything() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        clearCallLog()
        aboutMe = .empty
        state = AppState()
        Persistence.save(state)
    }
}

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
}
