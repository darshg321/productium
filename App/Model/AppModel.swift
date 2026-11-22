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
    /// A leaderboard invite opened before you picked a name (Review → Leaderboard asks for it).
    var pendingInvite: String?
    /// Dev test runner: the card id a screen should scroll to (`scroll <card>`).
    var scrollTarget: String?
    /// Bumped when an update brings setup steps (v1.4: the every-app automation, scrolling apps): onboarding shows
    /// just those once.
    static let setupVersion = 2
    var setupDone = LocalStore.defaults.integer(forKey: "setup.version")
    var needsSetup: Bool { setupDone < Self.setupVersion }

    func finishSetup() {
        setupDone = Self.setupVersion
        LocalStore.defaults.set(Self.setupVersion, forKey: "setup.version")
    }

    /// The box has the keyboard: Today holds its clock so typing never waits on the cards below.
    var boxFocused = false
    /// Review → Your Week (the recap) is open (the test runner's `review recap` opens it).
    var showRecap = false
    /// v1.3 E: prompts set to Alarm, from the last scheduling pass.
    @ObservationIgnored var promptAlarms: [PlannedAlarm] = []
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
        loaded.screenAverages = loaded.screenAverages.map { $0.repairedAverage(loaded.scrollingApps) }.recomputed(loaded.scrollingApps)
        state = loaded
        callLog = CallLogStore.load()
        aboutMe = AboutMeStore.load()
        if let e = Persistence.loadError {
            state.telemetry.record(.storage, "decode_failed", level: .error, ["error": e])
            Persistence.loadError = nil
        }
        if let from = Persistence.migratedFrom {
            state.telemetry.record(.storage, "migrated", ["from": "\(from)", "to": "\(AppState.schema)"])
            Persistence.migratedFrom = nil
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
        // A6: Health can't be read while the phone is locked; read again the moment it unlocks.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.log(.health, "unlocked")
                await self?.refresh(full: false)
            }
        }
        LocationService.shared.onVisit = { [weak self] visit in
            Task { @MainActor in self?.noteVisit(visit) }
        }
        LocationService.shared.onPoint = { [weak self] point in
            Task { @MainActor in if self?.state.trace.add(point) == true { self?.save() } }
        }
        if state.integrations.photos { ScreenshotWatcher.shared.start() }
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
        rebuildAppEntries()
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
        await refreshLog()
        learnCapacities()
        learnAdherence()
        if let note = state.taper.update(days: state.screen, now: Date(), calendar: cal) {
            toast = note
        }
        state.prune(now: Date())
        recordMissedBlocks()
        replan()
        await backupIfDue()
        if !state.outbox.items.isEmpty { await flushOutbox() }
        if full {
            serverOnline = await ClaudeClient.shared.ping()
            await insightPass()
            await taxonomyPass()
            await refreshServerUsage()
            await refreshSubscription()
            await refreshLeaderboards()
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
        checkGoalMoments()
        LocationService.shared.tracking(running != nil)
        syncNowActivity()
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
            .with(habits: Habits.detect(state.entries, tree: state.categories, now: now, calendar: cal),
                  atRisk: Set(state.items.filter { $0.isOpen && state.taskHistory.atRisk($0) }.map(\.id)))
    }

    func applyPlanEffects() {
        let plan = state.plan
        let now = Date()
        let nudges = nudgeInput(now: now)
        if state.integrations.notifications {
            state.prompts.roll(now: now)
            let buttons = startButtons(now: now).top.map(\.title)
            NotificationService.register(buttons: buttons)
            var planned = NudgePlanner.plan(nudges)
            // D4: "What are you up to?" timed by the 30-minute goal; A7: the morning sleep check; D6: the running entry
            // (only when Live Activities are off; otherwise the Lock Screen already shows it).
            let prompts = TrackPrompts.plan(TrackPromptInput(now: now, calendar: cal, entries: state.entries, plan: plan,
                                                             book: state.dayRules, log: state.prompts, buttons: buttons))
            state.prompts.scheduled = prompts.map {
                PromptLog.Asked(at: $0.at, stretchStart: $0.window?.start ?? $0.at, past: $0.id == "track.past")
            }
            planned += prompts
            if let q = TrackPrompts.sleepQuestion(entries: state.entries, now: now, log: state.prompts, calendar: cal) { planned.append(q) }
            if !RunningActivity.showing {
                planned += TrackPrompts.running(running, tree: state.categories, goalLine: goalLine(for: running), now: now)
            }
            planned += questionNudges(now: now)
            planned = state.prefs.prompts.filter(planned, liveActivity: RunningActivity.showing)
            log(.notification, "scheduled", ["count": "\(planned.count)", "prompts": "\(prompts.count)",
                                             "next": planned.filter { $0.kind != .running }.min { $0.at < $1.at }.map { "\($0.title) at \($0.at)" } ?? "none"])
            NotificationService.schedule(planned)
            promptAlarms = state.prefs.prompts.alarms(from: planned, alarmsAllowed: state.integrations.alarms)
            NotificationService.scheduleHousekeeping(expiry: signatureExpiry)
        }
        let n = state.prefs.nudges
        LocalStore.defaults.set(state.prefs.prompts.notifies(.scrollCheckIns) && state.integrations.notifications ? n.level.scrollCheckIns : [],
                                  forKey: LocalStore.Key.scrollCheckIns)
        syncAlarms(nudges)
        if state.integrations.calendarExport { CalendarService.shared.export(plan: plan) }
    }

    // MARK: Start buttons (D2)

    func startButtons(now: Date = Date()) -> QuickStarts.Ranked {
        let covered = QuickStarts.covered(today: now, items: state.items, planned: state.entries.filter { $0.source == .plan }, calendar: cal)
        return state.quickStarts.ranked(entries: state.entries, now: now, place: currentPlaceId, covered: covered,
                                        book: state.dayRules, schoolDays: state.prefs.schoolDays, calendar: cal)
    }

    /// One tap: starts it with no AI call (the same path as "starting X" typed).
    func start(_ b: QuickStart) {
        applyUI([BoxOp(.entry, .start, BoxFields(title: b.title, category: b.category, topics: b.topics.isEmpty ? nil : b.topics))],
                what: "button \(b.title)", quiet: true)
        Haptics.start()
    }

    /// Starts something by name (a notification's start button, Siri, a Shortcut): the button's filing if there's one.
    func start(title: String, at: Date? = nil, source: String) {
        var f = BoxFields(title: title)
        if let b = state.quickStarts.button(for: title), !b.removed {
            f.title = b.title
            f.category = b.category
            f.topics = b.topics.isEmpty ? nil : b.topics
        } else if let task = QuickParse.task(named: title, quickContext) {
            applyUI([BoxOp(.task, .start, ref: Ref.task(task.id))], what: "start \(task.title) (\(source))", quiet: true)
            return
        } else {
            f.category = state.categoryRules.category(for: title, tree: state.categories, scrollingApps: state.scrollingApps)
        }
        if let at { f.start = QuickParse.stamp(at, cal) }
        log(.intent, "start", ["title": title, "source": source])
        applyUI([BoxOp(.entry, .start, f)], what: "start \(title) (\(source))", quiet: true)
    }

    /// Stops the running entry (a notification's Done, Siri, a Shortcut, the Stop button).
    func stopRunning(source: String) {
        guard let r = running else { return }
        log(.intent, "stop", ["source": source])
        applyUI([BoxOp(.entry, .stop)], what: "stop (\(source))", quiet: true)
        Haptics.stop()
        // I: a work session that just ended gets its moment (minutes, or a new focus-hour milestone).
        if r.taskId != nil {
            let before = state.entries.filter { $0.taskId != nil && $0.id != r.id }
                .reduce(0) { $0 + max(0, Int((($1.end ?? $1.start).timeIntervalSince($1.start)) / 60)) }
            celebrate(.focusEnded(status: .done, minutes: Int(Date().timeIntervalSince(r.start) / 60), title: r.title,
                                  percentBefore: nil, percentAfter: nil, freeAfterMinutes: nil, totalFocusMinutesBefore: before))
        }
    }

    /// "What were you doing 3:10–4:30?" answered with a button: that stretch becomes a told entry.
    func logStretch(_ title: String, _ window: DateInterval) {
        let f = BoxFields(title: title, start: QuickParse.stamp(window.start, cal), end: QuickParse.stamp(min(window.end, Date()), cal),
                          category: state.quickStarts.button(for: title)?.category
                              ?? state.categoryRules.category(for: title, tree: state.categories, scrollingApps: state.scrollingApps))
        applyUI([BoxOp(.entry, .add, f)], what: "stretch \(title)")
    }

    /// The place you're at now (the last open visit's place), for ranking buttons and filing entries.
    var currentPlaceId: UUID? {
        guard let v = state.visits.last, v.departure == nil else { return nil }
        return state.placeBook.place(for: v)?.id
    }

    /// "Study 1h 10 of 2h" for the running entry's notification (I3), when a goal covers it.
    func goalLine(for e: Entry?) -> String? {
        guard let e else { return nil }
        return Goals.line(for: e, goals: state.goals, entries: state.entries, tree: state.categories, items: state.items,
                          now: Date(), book: state.dayRules, calendar: cal)
    }

    /// Answers to "Slept about …?" (A7): yes confirms the estimate as yours.
    func confirmSleep(_ window: DateInterval) {
        state.prompts.sleepAnswered.insert(DayKeys.key(window.end, cal))
        let f = BoxFields(title: "Sleep", start: QuickParse.stamp(window.start, cal), end: QuickParse.stamp(window.end, cal),
                          category: CategoryTree.sleep)
        applyUI([BoxOp(.entry, .add, f)], what: "slept")
    }

    /// Both alarm toggles feed one wanted list; an off toggle means its alarms are cancelled, not left behind.
    func syncAlarms(_ input: NudgeInput? = nil) {
        // O4: the wake alarm is the planned Sleep's alert; your own alarms are entries' alerts (approved only, J).
        let entryAlarms = AlarmPlanner.entryAlarms(state.entries, now: Date(), allowed: state.integrations.alarms,
                                                   wake: state.prefs.prompts[.wake] == .alarm, book: state.dayRules, calendar: cal)
        AlarmService.sync(AlarmPlanner.desired(input ?? nudgeInput(), entryAlarms: entryAlarms + promptAlarms))
    }

    func nudgeInput(now: Date = Date()) -> NudgeInput {
        let answered = Sessions.worked(plan: state.plan, entries: state.entries, now: now)
        let snoozed = Set(state.snoozed.filter { $0.value > now }.map(\.key))
        return NudgeInput(now: now, calendar: cal, plan: state.plan, items: state.items, settings: state.prefs.nudges,
                          startedBlockId: Sessions.block(for: running, in: state.plan, now: now)?.id, answeredBlockIds: answered, snoozedBlockIds: snoozed,
                          running: running, timeLabel: { $0.formatted(date: .omitted, time: .shortened) },
                          policy: state.policy, dayRules: state.dayRules, prompts: state.prefs.prompts,
                          alarmsAllowed: state.integrations.alarms, liveActivity: RunningActivity.showing)
    }


    /// Study blocks that ended in the last 36 hours with no time tracked on them and no answer ("No") yet.
    var pendingOutcomes: [PlannedBlock] {
        Sessions.pending(plan: state.plan, entries: state.entries, now: Date()).filter { state.snoozed[$0.id] == nil }
    }

    var activeWarnings: [PlanWarning] {
        state.plan.warnings.filter { !state.dismissed.contains($0.message) }
    }

    // MARK: Running entry (D3: starting a task is starting an entry with its id)

    var running: Entry? { TimeLog.running(state.entries) }

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
        afterLogChange()
        replan()
    }

    func startNowOrNext() {
        guard running?.taskId == nil else { return }
        let now = Date()
        if let b = state.plan.current(at: now), b.isStudy { startFocus(b); return }
        // The next study session, not just the next block (that's often dinner or wind-down).
        guard let n = state.plan.blocks.first(where: { $0.isStudy && $0.start > now }) else { return }
        if n.start.timeIntervalSince(now) < 90 * 60 { startFocus(n); return }
        if let item = n.itemId.flatMap({ id in state.items.first { $0.id == id } }) { focusNow(on: item) }
    }

    func startFocus(blockId: UUID) {
        guard running?.taskId == nil else { return }
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

    /// "Not Today" on a task notification (H.1): not before tomorrow (it keeps its due), counted as put off.
    func notToday(blockId: UUID) {
        guard let b = state.plan.blocks.first(where: { $0.id == blockId }), let id = b.itemId,
              let i = state.items.firstIndex(where: { $0.id == id }) else { return }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        if state.items[i].due > tomorrow { state.items[i].notBefore = tomorrow }
        Avoidance.record(.cantToday, itemId: id, in: &state.items, at: Date(), reason: "Not today", blockId: blockId)
        NotificationService.cancel(blockId: blockId)
        log(.notification, "not_today", ["task": state.items[i].title])
        replan()
    }

    func focusNow(on item: WorkItem) { startTask(item) }

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
        state.taskHistory.add(TaskHistory.record(it, cleared: false, entries: state.entries, now: Date(), calendar: cal))
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

    /// M5: a screenshot that looks like homework, waiting for Add.
    var screenshotOffer: AIImage?
    /// The celebration being shown now (cleared by `RootView` after a few seconds).
    var rewardMoment: RewardMoment?

    /// A saved region's enter / exit is a visit's arrival / departure (Part E: places are visits, not check-ins).
    private func handleGeofence(_ place: String, entered: Bool) {
        log(.sensor, "geofence", ["place": place, "entered": "\(entered)"])
        guard let p = state.places.first(where: { $0.id == place }) else { return }
        if entered {
            noteVisit(PlaceVisit(latitude: p.latitude, longitude: p.longitude, arrival: Date()))
        } else if let v = state.trace.visits.last(where: { $0.departure == nil
            && PlaceSuggester.meters($0.latitude, $0.longitude, p.latitude, p.longitude) < max(150, p.radius) }) {
            var closed = v
            closed.departure = Date()
            noteVisit(closed)
        }
        if place == "home" && entered { arrivedHome() }
        Task { await runInferences(); replan() }
    }

    private func arrivedHome() {
        if state.integrations.notifications, let intent = state.policy.intentions.first(where: {
            $0.trigger == .arriveHome && ($0.weekdays.isEmpty || $0.weekdays.contains(cal.component(.weekday, from: Date())))
        }) {
            NotificationService.notify("You're home", intent.text, deeplink: "productium://now")
            return
        }
        guard state.integrations.notifications, state.prefs.nudges.arrivingHome, state.prefs.nudges.level != .gentle,
              running == nil else { return }
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

    var signatureExpiry: Date? { Signature.expiry }

    func logMood(_ mood: Int, energy: Int?, note: String?) {
        state.moods.append(MoodEntry(mood: mood, energy: energy, note: note))
        if state.integrations.health { HealthService.shared.logStateOfMind(mood) }
        replan()
    }


    var todayMood: MoodEntry? { state.moods.filter { cal.isDateInToday($0.at) }.max { $0.at < $1.at } }

    private func syncHealth() async {
        guard state.integrations.health else { return }
        state.integrations.healthNeedsRequest = await HealthService.shared.requestNeeded()
        let (days, report) = await HealthService.shared.days(back: 21, calendar: cal)
        let now = Date()
        log(.health, "read", level: report.error == nil ? .info : .warn,
            ["days": "\(days.count)", "needsRequest": "\(state.integrations.healthNeedsRequest)",
             "sleepSamples": "\(report.sleepSamples)", "nights": "\(days.filter { $0.sleepMinutes != nil }.count)",
             "source": report.sleepSource ?? "none", "error": report.error ?? ""].filter { !$0.value.isEmpty })
        if let e = report.error {
            state.healthReads.lastError = e
            state.healthReads.lastErrorAt = now
        } else {
            state.healthReads.lastSuccess = now
            state.healthReads.lastSleepSamples = report.sleepSamples
            if let src = report.sleepSource { state.healthReads.lastSleepSource = src }
        }
        guard !days.isEmpty else { return }
        // A6: field by field, never clearing what an earlier read found.
        state.health = state.health.merging(fresh: days, calendar: cal)
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

    /// Follow-through and good hours from each finished day's log (planner energy curve, weekly note, Review).
    func learnAdherence() {
        var learned = state.learned
        let read = AdherenceLearner.learn(&learned, history: state.planHistory, entries: state.entries, items: state.items,
                                          tree: state.categories, now: Date(), calendar: cal)
        guard learned != state.learned else { return }
        state.learned = learned
        log(.planner, "adherence_learned", ["sessions": "\(read.count)", "done": "\(read.filter { $0.status == .done }.count)",
                                            "adherence": "\(Int(learned.adherence * 100))%",
                                            "goodHours": learned.goodHours().map(String.init).joined(separator: ",")])
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
        // A5 / B2: nights (measured or estimated) and naps are Sleep entries in the log.
        let written = EntryBuilder.sleep(state.health, entries: &state.entries, now: Date(), calendar: cal)
        if !written.isEmpty { log(.health, "sleep_entries", level: .debug, ["count": "\(written.count)"]) }
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
        Friction.update { $0.prune(now: now) }
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
        var x = input
        let candidates = PatternFinder.find(entries: state.entries, tree: state.categories, now: now, book: state.dayRules, calendar: cal)
        x.patterns = candidates
        x.trackRecord = state.taskHistory.summary()
        x.goals = goalsAll.map { progress($0).line }
        x.aiGoals = state.goals.filter { $0.origin == .ai }
        x.grid = GridTidy.summary(state.quickStarts, entries: state.entries, now: now)
        x.answers = state.inference.answers.suffix(8).map { "\($0.answer) (\($0.kind.rawValue), \($0.at.formatted(.dateTime.weekday(.abbreviated))))" }
        guard let out = try? await ClaudeClient.shared.structured(
            feature: .review, system: InsightPass.system(), user: InsightPass.request(x), schema: InsightPass.schema,
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
        // P2: the patterns it chose (code's numbers); I2: its own goals moved ±10%.
        state.patterns = InsightPass.patterns(out, candidates: candidates)
        for line in InsightPass.goalChanges(out, goals: &state.goals) { log(.ai, "goal_nudged", ["change": line]) }
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
        rebuildAppEntries(save: false)
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

    func boxState(entries: [Entry]) -> BoxState {
        var b = BoxState(entries: entries.filter { $0.source != .plan }, rules: state.rules, items: state.items, categories: state.categories,
                         dayRules: state.dayRules, sleepFloorMinutes: state.prefs.sleepFloorMinutes)
        b.planned = entries.filter { $0.source == .plan }
        b.goals = state.goals
        b.places = state.placeBook
        if let v = state.visits.last, v.departure == nil { b.here = v }
        return b
    }

    /// Writes the box's changes back. Plan entries it didn't touch stay as they were (a replan renews them); one it
    /// edited is yours now.
    func absorb(_ b: BoxState, plan _: [Entry]) {
        state.entries = b.entries + b.planned
        state.goals = b.goals
        state.placeBook = b.places
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
        let context = BoxContext.make(BoxContextInput(now: now, calendar: cal, state: boxState(entries: state.entries), planned: plan,
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
            var bs = boxState(entries: state.entries)
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
            // H2: the facts for a kind they usually drop are the app's own numbers.
            let added = state.items.filter { !itemsBefore.map(\.id).contains($0.id) }
            if let note = state.taskHistory.note(for: added, reply: reply) { reply += (reply.isEmpty ? "" : " ") + note }
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

    // MARK: Everyday lane (O7) and the outbox (A9)

    var quickContext: QuickContext {
        QuickContext(now: Date(), calendar: cal, entries: state.entries, items: state.items, tree: state.categories,
                     rules: state.categoryRules, scrollingApps: state.scrollingApps, book: state.dayRules, tiles: state.quickStarts.live)
    }

    /// Everything said to Productium goes through here: the box, notification replies, Siri and Shortcuts.
    /// 1. Saved to the outbox first (and to disk), so it's never lost. 2. The local fast path, no network.
    /// 3. Only then Sonnet, inside a background task. A reply from a notification always gets an answer back.
    @discardableResult
    func submit(_ raw: String, images: [AIImage] = [], source: OutboxItem.Source = .app, context: String? = nil) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return false }
        let now = Date()
        var outboxId: UUID?
        if images.isEmpty {
            outboxId = state.outbox.add(text, source: source, context: context, at: now)
            if let e = Persistence.save(state) { log(.storage, "save_failed", level: .error, ["error": e]) }
        }
        if images.isEmpty, context == nil, let q = QuickParse.parse(text, quickContext) {
            let receipt = applyQuick(q, text: text)
            if let id = outboxId { state.outbox.sent(id) }
            save()
            if source != .app { NotificationService.receipt(receipt.lines.last ?? "Done", body: receipt.problems.first) }
            return true
        }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "box") { }
        defer { UIApplication.shared.endBackgroundTask(bg) }
        let item = outboxId.flatMap { id in state.outbox.items.first { $0.id == id } }
        let ok = await dump(item?.boxText(now: Date(), calendar: cal) ?? text, images: images)
        if let id = outboxId {
            if ok { state.outbox.sent(id) } else { state.outbox.failed(id, error: "unreachable", at: Date()) }
            save()
        }
        if source != .app {
            if ok {
                let t = state.conversation.turns.last
                NotificationService.receipt(t?.applied.changes.last ?? "Done", body: t?.reply)
            } else {
                NotificationService.receipt("Saved", body: "I'll handle it when you open Productium.")
            }
        }
        log(.box, "submitted", ["source": source.rawValue, "ok": "\(ok)", "outbox": "\(state.outbox.items.count)"])
        return ok
    }

    /// A message the local fast path took: applied through the box's own applier, shown as a turn (with Undo), but
    /// never sent to the server (no assistant content, so it isn't in the conversation's history).
    @discardableResult
    func applyQuick(_ q: QuickParsed, text: String) -> BoxReceipt {
        let now = Date()
        clearUndo()
        let side = SideSnapshot(moods: state.moods, screen: state.screen, screenAverages: state.screenAverages,
                                scrollingApps: state.scrollingApps, prefs: state.prefs, policy: state.policy, aboutMe: aboutMe)
        let ops = BoxSideOps.split(q.ops)
        let plan = state.entries.filter { $0.source == .plan }
        var bs = boxState(entries: state.entries)
        var receipt = BoxApplier.apply(ops.box, to: &bs, now: now, calendar: cal)
        absorb(bs, plan: plan)
        var me = aboutMe
        let sr = BoxSideOps.apply(ops.side, to: &state, aboutMe: &me, now: now, calendar: cal)
        receipt.lines += sr.lines
        receipt.problems += sr.problems
        if q.kind == .mood, let m = q.ops.first?.fields.mood, state.integrations.health { HealthService.shared.logStateOfMind(m) }
        let turnId = UUID()
        let reply = receipt.problems.isEmpty ? (receipt.lines.last ?? "Done.") : receipt.problems.joined(separator: " ")
        state.conversation.add(ConversationTurn(id: turnId, at: now, text: text, userContent: .array([]), reply: reply,
                                                applied: AppliedReport(changes: receipt.lines, problems: receipt.problems)))
        state.telemetry.boxTurn(receipt, turnId: turnId, message: text, ops: q.ops, at: now)
        log(.box, "local", ["kind": q.kind.rawValue, "turn": turnId.uuidString])
        state.approvals += Approvals.from(receipt.held, turnId: turnId, at: now)
        undoTurnId = turnId
        undoReceipt = receipt
        undoSide = side
        afterLogChange()
        replan()
        return receipt
    }

    /// Something was started, stopped or logged: it answers any tracking prompt, the start gets a button (D2), and
    /// iOS learns the pattern (M4 donations). The Live Activity / running notification is renewed by the replan that follows.
    func afterLogChange() {
        state.prompts.answered.append(Date())
        NotificationService.clearDelivered(prefixes: ["track.", "running."])
        if let r = running {
            state.quickStarts.noteStart(r, at: Date())
            Donations.started(r.title)
            if r.category == CategoryTree.other, !r.filedByYou, OnDeviceModel.available { Task { await fileOnDevice(r.id) } }
        } else {
            Donations.stopped()
        }
    }

    /// Replies saved while offline go out now (launch, foreground, background refresh).
    func flushOutbox() async {
        for item in state.outbox.due(now: Date()) {
            guard state.outbox.items.contains(where: { $0.id == item.id }) else { continue }
            log(.box, "outbox_retry", ["attempts": "\(item.attempts)", "age": "\(Int(Date().timeIntervalSince(item.at) / 60))m"])
            if let q = QuickParse.parse(item.text, quickContext), item.context == nil {
                applyQuick(q, text: item.text)
                state.outbox.sent(item.id)
                continue
            }
            if await dump(item.boxText(now: Date(), calendar: cal)) {
                state.outbox.sent(item.id)
            } else {
                state.outbox.failed(item.id, error: "unreachable", at: Date())
                break
            }
        }
        save()
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
        var bs = boxState(entries: state.entries)
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
        var bs = boxState(entries: state.entries)
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
    }

    func saveAboutMe(editedText: String) {
        aboutMe = AboutMe.studentEdited(old: aboutMe.markdown, new: editedText)
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
            ("locations.csv", Data(Where.csv(state.trace, book: state.placeBook).utf8)),
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
