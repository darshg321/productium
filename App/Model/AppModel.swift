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
    @ObservationIgnored private var undoSnapshot: AppState?
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
        state = Persistence.load()
        callLog = CallLogStore.load()
        aboutMe = AboutMeStore.load()
    }

    // The Inbox draft survives tab changes, backgrounding and relaunch: text in state, images as files.
    static var draftsURL: URL { SharedConfig.containerURL.appendingPathComponent("drafts", isDirectory: true) }
    @ObservationIgnored private var draftImageCache: [String: (UIImage, AIImage)] = [:]

    var draftText: String {
        get { state.draft.text }
        set { state.draft.text = newValue; save() }
    }

    var draftImages: [(file: String, image: UIImage, ai: AIImage)] {
        state.draft.imageFiles.compactMap { file in
            if let c = draftImageCache[file] { return (file, c.0, c.1) }
            guard let data = try? Data(contentsOf: Self.draftsURL.appendingPathComponent(file)), let img = UIImage(data: data) else { return nil }
            let ai = AIImage(mediaType: "image/jpeg", base64: data.base64EncodedString())
            draftImageCache[file] = (img, ai)
            return (file, img, ai)
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
            Persistence.save(snapshot)
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
        if state.onboarded { Task { await refresh() } }
    }

    func foreground() {
        Friction.ended(by: .productium)
        state.appOpens.append(Date())
        if let link = SharedConfig.defaults.string(forKey: SharedConfig.Key.pendingDeepLink) {
            deepLink = link
            SharedConfig.defaults.removeObject(forKey: SharedConfig.Key.pendingDeepLink)
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
        learnRoutines()
        learnCapacities()
        if let note = state.taper.update(days: state.screen, now: Date(), calendar: cal) {
            toast = note
        }
        state.prune(now: Date())
        recordMissedBlocks()
        replan()
        if full {
            serverOnline = await ClaudeClient.shared.ping()
            await weeklyReviewIfDue()
            await reflectIfDue()
            await refreshServerUsage()
            await refreshSubscription()
        }
    }

    var itemsById: [UUID: WorkItem] { Dictionary(uniqueKeysWithValues: state.items.map { ($0.id, $0) }) }

    func replan() {
        let now = Date()
        var locked: [PlannedBlock] = []
        if let f = state.focus, var b = state.plan.blocks.first(where: { $0.id == f.blockId }) {
            b.end = max(b.end, now.addingTimeInterval(60))
            locked = [b]
        } else if let cur = state.plan.current(at: now), cur.isStudy, !state.outcomes.contains(where: { $0.blockId == cur.id }) {
            locked = [cur]
        }
        let input = PlannerInput(now: now, calendar: cal, items: state.items, commitments: state.commitments,
                                 events: shownEvents + state.oneOffs, preferences: state.prefs, learned: state.learned,
                                 health: state.health, moods: state.moods, locked: locked, routines: state.routines,
                                 exceptions: state.exceptions, horizonDays: 14, policy: state.policy, beliefs: state.beliefs)
        PlanHistory.record(previous: state.plan, into: &state.planHistory, now: now, calendar: cal)
        state.plan = Planner.merge(previous: state.plan, new: Planner.plan(input), now: now, calendar: cal)
        save()
        applyPlanEffects()
    }

    private func applyPlanEffects() {
        let plan = state.plan
        let now = Date()
        let nudges = nudgeInput(now: now)
        dueGap = GapDetector.due(gapInput(now: now), calendar: cal)
        if state.integrations.notifications { scheduleGapQuestion(now: now) }
        if state.integrations.notifications {
            NotificationService.schedule(NudgePlanner.plan(nudges))
            NotificationService.scheduleHousekeeping(freeTier: Signature.isFreeTier, expiry: signatureExpiry)
        }
        let n = state.prefs.nudges
        SharedConfig.defaults.set(n.scrollCheckIns && state.integrations.notifications ? n.level.scrollCheckIns : [],
                                  forKey: SharedConfig.Key.scrollCheckIns)
        Task { await AlarmService.scheduleNudges(NudgePlanner.alarms(nudges)) }
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

    func nudgeInput(now: Date = Date()) -> NudgeInput {
        let answered = Set(state.outcomes.filter { $0.plannedStart > now.addingTimeInterval(-2 * 86400) }.map(\.blockId))
        let snoozed = Set(state.snoozed.filter { $0.value > now }.map(\.key))
        return NudgeInput(now: now, calendar: cal, plan: state.plan, items: state.items, settings: state.prefs.nudges,
                          startedBlockId: state.focus?.blockId, answeredBlockIds: answered, snoozedBlockIds: snoozed,
                          markerPrompts: markerPrompts(), timeLabel: { $0.formatted(date: .omitted, time: .shortened) },
                          policy: state.policy)
    }

    var currentBlock: PlannedBlock? { state.plan.current(at: Date()) }

    func todayBlocks(_ date: Date = Date()) -> [PlannedBlock] {
        state.plan.blocks(on: date, calendar: cal).filter { $0.kind != .sleep }
    }

    var pendingOutcomes: [PlannedBlock] {
        let now = Date()
        let answered = Set(state.outcomes.map(\.blockId))
        return state.plan.blocks.filter { $0.isStudy && $0.end <= now && $0.end > now.addingTimeInterval(-36 * 3600) && !answered.contains($0.id) }
    }

    var activeWarnings: [PlanWarning] {
        state.plan.warnings.filter { !state.dismissed.contains($0.message) }
    }

    func logOutcome(blockId: UUID, status: OutcomeStatus, actualMinutes: Int? = nil, reason: String? = nil) {
        guard !state.outcomes.contains(where: { $0.blockId == blockId }),
              let b = state.plan.blocks.first(where: { $0.id == blockId }) else { return }
        let actual = actualMinutes ?? (status == .done ? b.minutes : status == .partial ? b.minutes / 2 : 0)
        let idx = b.itemId.flatMap { id in state.items.firstIndex { $0.id == id } }
        let o = BlockOutcome(blockId: blockId, itemId: b.itemId, kind: idx.map { state.items[$0].kind }, plannedStart: b.start,
                             plannedMinutes: b.minutes, actualMinutes: actual, status: status)
        state.outcomes.append(o)
        state.snoozed[blockId] = nil
        NotificationService.cancel(blockId: blockId)
        state.learned.record(outcome: o, calendar: cal)
        if let i = idx { state.items[i].completedMinutes += actual }
        if status == .skipped {
            Avoidance.record(reason == nil ? .skipped : .cantToday, itemId: b.itemId, in: &state.items, at: Date(), reason: reason, blockId: blockId)
            toast = "No problem. It's been moved to a better slot."
        }
        replan()
    }

    func startFocus(_ b: PlannedBlock) {
        let end = max(b.end, Date().addingTimeInterval(Double(b.minutes) * 60))
        state.focus = FocusSession(blockId: b.id, itemId: b.itemId, title: b.title, startedAt: Date(), plannedEnd: end)
        state.snoozed[b.id] = nil
        NotificationService.cancel(blockId: b.id)
        AlarmService.cancelNudge(blockId: b.id)
        if state.integrations.screenTime { ScreenTimeService.shared.focusNow(true, title: b.title, ends: end) }
        LiveActivityService.update(current: PlannedBlock(id: b.id, kind: b.kind, start: Date(), end: end, title: b.title), next: nil)
        save()
    }

    func startNowOrNext() {
        guard state.focus == nil else { return }
        let now = Date()
        if let b = state.plan.current(at: now), b.isStudy { startFocus(b); return }
        if let n = state.plan.next(after: now), n.isStudy, n.start.timeIntervalSince(now) < 90 * 60 { startFocus(n); return }
        if let n = state.plan.next(after: now), n.isStudy, let item = n.itemId.flatMap({ id in state.items.first { $0.id == id } }) {
            focusNow(on: item)
        }
    }

    func startFocus(blockId: UUID) {
        guard state.focus == nil else { return }
        if let b = state.plan.blocks.first(where: { $0.id == blockId }), b.isStudy, b.end > Date() { startFocus(b) }
        else { startNowOrNext() }
    }

    func resetRoutine(_ id: String) {
        guard let i = state.routines.firstIndex(where: { $0.id == id }) else { return }
        state.routines[i].samples = []
        state.routines[i].stated = nil
        state.routines[i].learnedFrom = []
        replan()
    }

    func recordMissedBlocks() {
        Avoidance.recordMissed(pendingOutcomes.filter { !state.snoozed.keys.contains($0.id) }, in: &state.items, at: Date())
    }

    func snooze(blockId: UUID, minutes: Int = 10) {
        guard let b = state.plan.blocks.first(where: { $0.id == blockId }) else { return }
        state.snoozed[blockId] = Date().addingTimeInterval(Double(minutes) * 60)
        Avoidance.record(.snoozed, itemId: b.itemId, in: &state.items, at: Date(), blockId: blockId)
        NotificationService.snooze(blockId: blockId, title: b.title, minutes: minutes)
        AlarmService.cancelNudge(blockId: blockId)
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
        guard let f = state.focus else { return }
        let elapsed = max(1, Int(Date().timeIntervalSince(f.startedAt) / 60))
        state.focus = nil
        if state.integrations.screenTime { ScreenTimeService.shared.focusNow(false) }
        logOutcome(blockId: f.blockId, status: status, actualMinutes: elapsed)
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
        if it.completedMinutes >= 10 {
            state.learned.recordCompletion(kind: it.kind, estimated: it.estimateMinutes, actual: it.completedMinutes)
        }
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
        MarkerLog.add(evs, to: &state.markers)
        learnRoutines(days: 1)
        if source != .geofence { offerPlace(after: evs) }
        if evs.contains(where: { $0.category == .sleep }) { estimateSleep(); replan() } else { save() }
    }

    // Places that learn themselves: ask to save a place you've just said you're at, or keep returning to.
    var placeOffer: PlaceOffer?

    func recordVisit(_ v: PlaceVisit) {
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

    private func offerPlace(after evs: [TimelineEvent]) {
        guard placeOffer == nil, LocationService.shared.status != .denied,
              var offer = PlaceSuggester.offer(after: evs, places: state.places, commitments: state.commitments,
                                               declined: state.declinedPlaces) else { return }
        Task {
            guard let fix = await LocationService.shared.currentLocation() else { return }
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
              state.focus == nil else { return }
        let now = Date()
        if let b = state.plan.current(at: now), b.isStudy, !state.outcomes.contains(where: { $0.blockId == b.id }) {
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

    var signatureExpiry: Date? { Signature.expiry }

    func logMood(_ mood: Int, energy: Int?, note: String?) {
        state.moods.append(MoodEntry(mood: mood, energy: energy, note: note))
        replan()
    }

    var supportSuggested: Bool { Wellbeing.supportSuggested(moods: state.moods, now: Date()) }

    var todayMood: MoodEntry? { state.moods.filter { cal.isDateInToday($0.at) }.max { $0.at < $1.at } }

    private func syncHealth() async {
        guard state.integrations.health else { return }
        state.integrations.healthNeedsRequest = await HealthService.shared.requestNeeded()
        let days = await HealthService.shared.days(back: 21, calendar: cal)
        guard !days.isEmpty else { return }
        var byDay = Dictionary(state.health.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for d in days { byDay[cal.startOfDay(for: d.day)] = d }
        state.health = byDay.values.sorted { $0.day < $1.day }
        let mids = HealthService.freeDayMidpoints(Array(state.health.suffix(28)), prefs: state.prefs, cal: cal)
        if let c = LearnedModel.chronotype(fromFreeDaySleepMidpointsHours: mids) { state.learned.inferredChronotype = c }
    }

    private func syncMotion() async {
        guard state.integrations.motion else { return }
        let now = Date()
        let from = now.addingTimeInterval(-7 * 86400)
        let samples = await MotionService.shared.samples(from: from, to: now)
        guard !samples.isEmpty else { return }
        let fresh = MotionTimeline.spans(samples, until: now, previous: state.motion)
        state.motion = MotionTimeline.merge(state.motion, with: fresh, from: samples.map(\.at).min() ?? from)
        for i in 0...7 {
            guard let day = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: now)) else { continue }
            state.routines = MotionTimeline.learnRoutines(state.motion, day: day, commitments: state.commitments,
                                                          exceptions: state.exceptions, routines: state.routines, calendar: cal)
        }
    }

    /// Calendar events that are one of your activities (CS club) are shown once, as the activity.
    var shownEvents: [FixedEvent] {
        EventMatch.withoutActivityTwins(state.events, commitments: state.commitments, exceptions: state.exceptions, calendar: cal)
    }

    func isSchoolDay(_ d: Date) -> Bool {
        SchoolDay.isSchoolDay(d, prefs: state.prefs, commitments: state.commitments, exceptions: state.exceptions, calendar: cal)
    }

    /// The last `n` finished days: planned and done study, and the free time kept after school.
    func dayRecords(back n: Int) -> [DayRecord] {
        let today = cal.startOfDay(for: Date())
        let days = (1...n).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        return CapacityLearner.records(days: days, planHistory: state.planHistory, outcomes: state.outcomes, progress: state.progress,
                                       markers: state.markers, isSchoolDay: isSchoolDay,
                                       eveningFree: { d in
                                           let segs = self.segments(on: d)
                                           guard let end = segs.filter({ [.school, .activities].contains($0.category) }).map(\.end).max() else { return nil }
                                           return segs.filter { $0.category == .free && $0.start >= end }.reduce(0) { $0 + $1.minutes }
                                       }, calendar: cal)
    }

    /// Moments the phone was in use: app opens, scrolling, and check-ins typed or tapped.
    var phoneUse: [Date] {
        state.appOpens + Friction.log.sessions.flatMap { [$0.openedAt] + ($0.endedAt.map { [$0] } ?? []) }
            + state.markers.filter { $0.source != .geofence && $0.source != .inferred }.map(\.at)
    }

    /// Changes the state the box and proposals work on, about-me included.
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
        state.beliefs = CapacityLearner.learn(state.beliefs, days: dayRecords(back: CapacityLearner.window), outcomes: state.outcomes,
                                              markers: state.markers, now: Date(), calendar: cal)
    }

    var healthStatus: HealthStatus {
        HealthStatus.resolve(wantsHealth: state.integrations.health, requestNeeded: state.integrations.healthNeedsRequest,
                             days: state.health)
    }

    func estimateSleep() {
        let today = cal.startOfDay(for: Date())
        let days = (0..<14).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        state.health = SleepEstimator.fill(state.health, days: days, markers: state.markers, motion: state.motion,
                                           phoneUse: phoneUse, sleepNeedMinutes: state.prefs.sleepNeedMinutes, calendar: cal)
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
        guard state.integrations.screenTime else { return }
        var byDay = Dictionary(state.screen.map { (cal.startOfDay(for: $0.day), $0) }, uniquingKeysWith: { $1 })
        for d in ScreenTimeService.shared.usageDays(back: 21) where d.distractingMinutes > 0 || byDay[d.day] == nil {
            byDay[cal.startOfDay(for: d.day)] = d
        }
        state.screen = byDay.values.sorted { $0.day < $1.day }
    }

    /// Pairs complete a routine sample as soon as the end marker exists; learned marker ids stop a pair counting twice.
    private func learnRoutines(days: Int = 7) {
        let today = cal.startOfDay(for: Date())
        for i in 0..<days {
            guard let day = cal.date(byAdding: .day, value: -i, to: today) else { continue }
            let evs = state.markers.filter { cal.isDate($0.at, inSameDayAs: day) }
            guard !evs.isEmpty else { continue }
            let wake = state.health.first { cal.isDate($0.day, inSameDayAs: day) }?.wake
            state.routines = RoutineLearner.learn(day: evs, healthWake: wake, routines: state.routines)
        }
    }

    func reflectIfDue(asked question: String? = nil) async {
        let now = Date()
        state.proposals.expire(now: now)
        let since = now.addingTimeInterval(-14 * 86400)
        let deferrals = Reflection.deferrals(items: state.items, since: since)
        let days = dayRecords(back: 14)
        let weeklyDue = state.reflectionAt.map { now.timeIntervalSince($0) > 6.5 * 86400 } ?? (state.outcomes.count >= 5)
        guard let trigger = Reflection.trigger(now: now, lastRun: state.reflectionAt, deferrals: deferrals, days: days,
                                               weeklyDue: weeklyDue, asked: question != nil,
                                               paused: state.proposals.isPaused(now: now), budgetAllows: aiAllowed(.reflection),
                                               calendar: cal) else { return }
        busy.insert("reflection")
        defer { busy.remove("reflection") }
        let convos = state.archive.conversations.suffix(5).compactMap(\.title) + state.conversation.turns.suffix(5).map { String($0.text.prefix(120)) }
        let user = Reflection.request(now: now, aboutMe: aboutMe, beliefs: state.beliefs, routines: state.routines, deferrals: deferrals,
                                      days: days, policy: state.policy, feedback: state.proposals.feedback, conversations: convos,
                                      items: state.items, trigger: trigger, question: question, calendar: cal)
        guard let out = try? await ClaudeClient.shared.structured(
            feature: .reflection, system: Reflection.system(), user: user, schema: Reflection.schema, as: Reflection.Output.self,
            maxTokens: 1500, model: AIModel.opus, effort: "medium", accept: { !$0.note.isEmpty }) else { return }
        state.reflectionAt = now
        let run = ReflectionRun(at: now, note: out.note, model: AIModel.opus)
        let drafts = Reflection.drafts(out, runId: run.id, items: state.items, now: now, model: AIModel.opus, calendar: cal)
        var ds = state.dumpState
        ds.aboutMe = aboutMe
        state.proposals.submit(run, drafts, state: ds, now: now)
        if drafts.isEmpty { toast = out.note }
        save()
    }

    func approveProposal(_ id: UUID) {
        let now = Date()
        guard editDumpState({ state.proposals.approve(id, in: &$0, now: now, calendar: cal) }) else { return }
        replan()
    }

    func approveRun(_ runId: UUID) {
        for p in state.proposals.pending where p.runId == runId { approveProposal(p.id) }
    }

    func rejectProposal(_ id: UUID) { state.proposals.reject(id, now: Date()); save() }

    func rejectRun(_ runId: UUID) {
        for p in state.proposals.pending where p.runId == runId { state.proposals.reject(p.id, now: Date()) }
        save()
    }

    func neverChange(_ id: UUID) { state.proposals.neverChange(id, now: Date()); save() }

    func revertProposal(_ id: UUID) {
        let now = Date()
        guard editDumpState({ state.proposals.revert(id, in: &$0, now: now) }) else { return }
        replan()
    }

    var dueGap: MysteryGap?

    func gapInput(now: Date = Date()) -> GapInput {
        GapInput(now: now, day: dayInputs(cal.startOfDay(for: now)), scrolling: Friction.log.sessions, phoneUse: phoneUse,
                        plan: state.plan, focusing: state.focus != nil, log: state.gaps)
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
        if let markers = GapAnswer.markers(for: text, gap: gap, commitments: state.commitments, known: known, calendar: cal) {
            MarkerLog.add(markers, to: &state.markers)
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
        return DayInputs(day: day, events: state.markers, commitments: state.commitments,
                         fixedEvents: shownEvents + state.oneOffs, routines: state.routines, outcomes: state.outcomes, itemsById: itemsById,
                         health: state.health.first { cal.isDate($0.day, inSameDayAs: day) },
                         nextHealth: state.health.first { cal.isDate($0.day, inSameDayAs: next) },
                         screen: state.screen.first { cal.isDate($0.day, inSameDayAs: day) }, prefs: state.prefs,
                         exceptions: state.exceptions, motion: state.motion, scrollSessions: Friction.log.sessions,
                         scrollingApps: state.scrollingApps, progress: state.progress)
    }

    func setScrolling(_ app: String, _ on: Bool) {
        state.scrollingApps[app] = on
        state.screen = state.screen.map { $0.recomputed(state.scrollingApps) }
        state.screenAverages = state.screenAverages.map { $0.recomputed(state.scrollingApps) }
        replan()
    }

    func dayTotals(last n: Int, includeToday: Bool = false) -> [DayTotals] {
        let today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { i -> DayTotals? in
            guard let d = cal.date(byAdding: .day, value: -(i + (includeToday ? 0 : 1)), to: today) else { return nil }
            let planned = PlanHistory.plannedMinutes(on: d, history: state.planHistory, plan: state.plan, outcomes: state.outcomes, calendar: cal)
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
        for t in state.items where t.kind.isMemoryBased && !t.isDone && !t.topics.isEmpty && t.due.timeIntervalSinceNow < 14 * 86400
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

    func weeklyReviewIfDue(force: Bool = false) async {
        guard aiAllowed(.review) else { return }
        if let at = state.reviewAt, Date().timeIntervalSince(at) < (force ? 600 : 6.5 * 86400) { return }
        guard force || state.outcomes.count >= 5 else { return }
        busy.insert("review")
        defer { busy.remove("review") }
        let summary = Insights.summarize(dayTotals(last: 7), learned: state.learned)
        let ctx = Prompts.context(now: Date(), items: state.items, plan: state.plan, summary: summary, moods: state.moods,
                                  taper: state.taper, learned: state.learned, calendar: cal, aboutMe: aboutMe)
        guard let r = try? await ClaudeClient.shared.structured(feature: .review, system: Prompts.weeklyReview(), user: ctx,
                                                               schema: Schemas.weeklyReview, as: WeeklyReview.self,
                                                               maxTokens: 500, accept: { !$0.headline.isEmpty }) else { return }
        state.review = r
        state.reviewAt = Date()
        save()
    }

    var undoTurnId: UUID?
    @ObservationIgnored private var undoAboutMe: AboutMe?

    @discardableResult
    func dump(_ raw: String, images: [AIImage] = []) async -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return false }
        busy.insert("dump")
        defer { busy.remove("dump") }
        let now = Date()
        let today = cal.startOfDay(for: now)
        let context = Prompts.dumpContext(DumpContextInput(now: now, calendar: cal, state: state.dumpState,
                                                           calendarEvents: shownEvents, todaySegments: segments(on: today),
                                                           plan: state.plan, warnings: activeWarnings, aboutMe: aboutMe))
        let convo = state.conversation
        let content = ConversationPolicy.userContent(for: convo, text: text, images: images, fullContext: context)
        let req = convo.request(system: Prompts.dump(), tool: ConversationPolicy.tool(schema: Schemas.dump),
                                userContent: content, maxTokens: 3000)
        do {
            let (result, res, tokens) = try await ClaudeClient.shared.send(req, feature: .box) { DumpResult.read($0) }
            undoSnapshot = state
            undoAboutMe = aboutMe
            let before = Set(state.items.map(\.id))
            let itemsBefore = state.items
            let turnId = UUID()
            let report = editDumpState { DumpApplier.apply(result, to: &$0, now: now, calendar: cal, writer: .box, turnId: turnId) }
            Avoidance.recordDueMoves(before: itemsBefore, after: &state.items, at: now, reason: text)
            estimateSleep()
            var reply = result.reply
            if reply.isEmpty { reply = report.changes.isEmpty ? "I couldn't find anything to change in that. Try saying it another way." : "Done." }
            if res.isTruncated { reply += " That was a lot at once, so I may have missed the end. Check the list and send the rest again." }
            let turn = ConversationTurn(id: turnId, at: now, text: text, images: images, userContent: content,
                                        assistantContent: res.rawContent ?? .array([]), reply: reply,
                                        applied: AppliedReport(changes: report.changes, problems: report.problems),
                                        callId: callLog.calls.last { $0.feature == .box && $0.ok }?.id, tokens: tokens,
                                        context: context)
            state.conversation.add(turn)
            undoTurnId = report.changes.isEmpty ? nil : turn.id
            replan()
            for item in state.items where !before.contains(item.id) { followUp(new: item) }
            return true
        } catch {
            let ai = error as? AIError
            let msg = ai?.errorDescription ?? "Couldn't reach your Claude server. Check that Tailscale is on, then send again."
            state.conversation.add(ConversationTurn(at: now, text: text, images: images, userContent: content, reply: msg,
                                                    callId: callLog.calls.last { $0.feature == .box }?.id, failed: true,
                                                    detail: ai?.detail ?? (ai == nil ? error.localizedDescription : nil),
                                                    context: context))
            save()
            if let d = ai?.detail {
                try? Data(d.utf8).write(to: Persistence.url.deletingLastPathComponent().appendingPathComponent("last-ai-error.txt"))
            }
            return false
        }
    }

    func undo() {
        guard let snap = undoSnapshot, let id = undoTurnId else { return }
        let convo = state.conversation, archive = state.archive
        state = snap
        if let me = undoAboutMe { aboutMe = me }
        state.conversation = convo
        state.archive = archive
        if let i = state.conversation.turns.firstIndex(where: { $0.id == id }) {
            state.conversation.turns[i].applied.problems.append("The student undid all of these changes")
            state.conversation.turns[i].applied.changes = state.conversation.turns[i].applied.changes.map { "(undone) " + $0 }
        }
        undoSnapshot = nil
        undoTurnId = nil
        replan()
    }

    func clearConversation() {
        state.archive.archive(state.conversation, now: Date())
        state.conversation = Conversation(startedAt: Date())
        undoSnapshot = nil
        undoTurnId = nil
        save()
    }

    func resumeConversation(_ id: UUID) {
        guard var c = state.archive.remove(id) else { return }
        state.archive.archive(state.conversation, now: Date())
        c.archivedAt = nil
        state.conversation = c
        undoSnapshot = nil
        undoTurnId = nil
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
        undoSnapshot = nil
        undoTurnId = nil
        if state.integrations.location { LocationService.shared.monitor(state.places) }
        replan()
        toast = "Restored from the export."
    }

    func deleteEverything() {
        ScreenTimeService.shared.disable()
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

    static var isFreeTier: Bool {
        #if FREE_TIER
        return true
        #else
        return false
        #endif
    }
}
