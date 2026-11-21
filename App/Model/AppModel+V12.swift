import Foundation
import SwiftUI
import UIKit
import ProductiumCore

// v1.2 model actions the new screens and services use. Everything that changes time goes through the box's own
// applier (`applyUI`), so the rules (overlaps, approval, Undo-able receipts) are the same whether it was typed, tapped,
// swiped, inferred or answered from a notification.

extension AppModel {
    // MARK: Applying

    /// A tap or swipe: applied as the box would (approved, since you did it), logged, replanned. No conversation turn.
    @discardableResult
    func applyUI(_ ops: [BoxOp], what: String, quiet: Bool = false) -> BoxReceipt {
        let now = Date()
        var bs = boxState(entries: state.entries)
        let r = BoxApplier.apply(ops, to: &bs, now: now, calendar: cal, approved: true)
        absorb(bs, plan: [])
        log(.log, "ui", ["what": what, "lines": r.lines.joined(separator: " | "), "problems": r.problems.joined(separator: " | ")])
        if !quiet { if let p = r.problems.first { toast = p } else if let l = r.lines.last { toast = l } }
        afterLogChange()
        replan()
        return r
    }

    // MARK: Entries (B7, C4, O11)

    /// Every occurrence on a day, as every screen shows it (skipped ones too, for the sheet).
    func dayEntries(_ day: Date, includeSkipped: Bool = false) -> [DayEntry] {
        Days.on(day, state.entries, now: Date(), book: state.dayRules, calendar: cal, includeSkipped: includeSkipped)
            .filter { cal.isDate($0.start, inSameDayAs: day) || $0.end > cal.startOfDay(for: day) }
    }

    /// Swipe right: yes, it happened.
    func confirm(_ d: DayEntry) {
        applyUI([BoxOp(.entry, .confirm, ref: d.ref)], what: "confirm", quiet: true)
        Haptics.tap()
    }

    /// Swipe left: no, it didn't (then "what instead?").
    func reject(_ d: DayEntry) {
        applyUI([BoxOp(.entry, .skip, ref: d.ref)], what: "reject", quiet: true)
        Haptics.tap()
    }

    /// One long swipe: everything assumed from the start of `range` to its end is confirmed ("school as usual").
    func confirmAll(in range: DateInterval) {
        var es = state.entries
        let refs = Days.confirm(in: range, entries: &es, now: Date(), book: state.dayRules, calendar: cal)
        state.entries = es
        log(.log, "confirm_range", ["count": "\(refs.count)"])
        toast = refs.isEmpty ? "Nothing to confirm there" : "Confirmed \(refs.count)"
        Haptics.success()
        replan()
    }

    /// The entry sheet's Save: one change, as the box would make it. A new category is a correction (C4).
    func save(_ d: DayEntry, title: String, start: Date, end: Date?, category: CategoryID, topics: [String], note: String?) {
        var f = BoxFields()
        if title != d.title { f.title = title }
        if start != d.start { f.start = QuickParse.stamp(start, cal) }
        if let end, end != d.end, !d.running { f.end = QuickParse.stamp(end, cal) }
        if category != d.category { f.category = category }
        if topics != d.entry.topics { f.topics = topics }
        if note != d.entry.note { f.note = note ?? "" }
        let r = applyUI([BoxOp(.entry, .change, ref: d.ref, f)], what: "edit")
        if category != d.category {
            state.categoryRules.correct(title, from: d.category, to: category, at: Date())
            let changed = Set(r.before.keys)
            for i in state.entries.indices where changed.contains(state.entries[i].id) && state.entries[i].category == category {
                state.entries[i].filedByYou = true
            }
            save()
        }
    }

    /// "Also move the 14 other 'Shower' entries?" Returns how many moved.
    @discardableResult
    func moveSimilar(title: String, to category: CategoryID) -> Int {
        let k = CategoryRules.key(title)
        var n = 0
        for i in state.entries.indices where CategoryRules.key(state.entries[i].title) == k && state.entries[i].category != category
            && state.entries[i].source != .plan {
            state.entries[i].category = category
            state.entries[i].filedByYou = true
            n += 1
        }
        state.categoryRules.learn(title, category, byYou: true, at: Date())
        log(.log, "move_similar", ["title": title, "count": "\(n)"])
        replan()
        return n
    }

    func similarCount(_ title: String, besides id: UUID, category: CategoryID) -> Int {
        let k = CategoryRules.key(title)
        return state.entries.filter { $0.id != id && $0.source != .plan && CategoryRules.key($0.title) == k && $0.category != category }.count
    }

    func remove(_ d: DayEntry) { applyUI([BoxOp(.entry, .remove, ref: d.ref)], what: "remove") }

    // MARK: Tasks (D3, H5)

    /// Starting a task = starting an entry with its id (D3).
    func startTask(_ item: WorkItem) {
        applyUI([BoxOp(.task, .start, ref: Ref.task(item.id))], what: "start task", quiet: true)
        Haptics.start()
    }

    /// Clear = "not doing this": counts as dropped (or partly), with an optional why (H5). Delete is `delete(_:)`.
    func clear(_ id: UUID, why: String?) {
        guard let i = state.items.firstIndex(where: { $0.id == id }) else { return }
        state.items[i].state = .dropped
        state.items[i].doneAt = Date()
        state.taskHistory.add(TaskHistory.record(state.items[i], cleared: true, why: why, entries: state.entries, now: Date(), calendar: cal))
        if running?.taskId == id { stopRunning(source: "clear") }
        log(.log, "task_cleared", ["title": state.items[i].title, "why": why ?? ""])
        toast = "Cleared. It's counted, so Productium learns from it."
        replan()
    }

    /// What the track record says about a task like this (H2), for its sheet and the add-task reply.
    func trackWarning(for item: WorkItem) -> String? { state.taskHistory.warning(for: item) }

    // MARK: Goals (I)

    var goalsAll: [Goal] { Goals.all(state.goals) }

    func progress(_ g: Goal, at day: Date? = nil) -> GoalProgress {
        Goals.progress(g, entries: state.entries, tree: state.categories, items: state.items, now: Date(), book: state.dayRules,
                       calendar: cal, at: day)
    }

    var suggestedGoals: [Goal] {
        Goals.suggest(entries: state.entries, tree: state.categories, existing: state.goals, now: Date(), book: state.dayRules, calendar: cal)
    }

    func addGoal(_ g: Goal) {
        var g = g
        g.origin = g.origin == .builtIn ? .you : g.origin
        state.goals.removeAll { $0.measure == g.measure && $0.period == g.period && $0.direction == g.direction }
        state.goals.append(g)
        log(.log, "goal_added", ["title": g.title, "target": "\(g.target)", "origin": g.origin.rawValue])
        save()
    }

    func removeGoal(_ id: UUID) { state.goals.removeAll { $0.id == id }; save() }

    /// Closing a goal, keeping a limit, a fully tracked day, beating your usual: checked after each replan, each once a day.
    func checkGoalMoments() {
        let now = Date()
        let month = cal.dateInterval(of: .month, for: now)
        let days = month.map { m in stride(from: m.start, to: min(m.end, now), by: 86400).map { $0 } } ?? []
        for g in state.goals where g.active && g.direction == .atLeast {
            let p = progress(g)
            if p.met {
                let n = g.period == .day ? Goals.daysMet(g, days: days, entries: state.entries, tree: state.categories, items: state.items,
                                                        now: now, book: state.dayRules, calendar: cal) : nil
                celebrate(.goalClosed(title: g.title, weekly: g.period == .week, daysThisMonth: n))
            }
        }
        // At bedtime: limits kept, the tracking goal, and the day vs your usual (G1b).
        guard let bed = state.plan.blocks.first(where: { $0.kind == .sleep && cal.isDate($0.start, inSameDayAs: now) })?.start,
              now >= bed.addingTimeInterval(-20 * 60), now < bed.addingTimeInterval(3 * 3600) else { return }
        for g in state.goals where g.active && g.direction == .atMost && g.period == .day {
            let p = progress(g)
            if p.met { celebrate(.limitKept(title: g.title, minutes: p.value, limit: g.target)) }
        }
        if progress(Goal.trackingGaps).met {
            let n = Goals.daysMet(Goal.trackingGaps, days: days, entries: state.entries, tree: state.categories, items: state.items,
                                  now: now, book: state.dayRules, calendar: cal)
            celebrate(.trackedDay(daysThisMonth: max(1, n)))
        }
        if let (score, usual, label, diffs) = scoreVsUsual(now) {
            celebrate(.beatUsual(score: score, usual: usual, label: label, differences: diffs))
        }
    }

    // MARK: Day score and the forecast (G.0a, G.0c)

    func dayScore(_ day: Date) -> DayScore {
        DayScore.make(day, asked: state.dayPlans[DayKeys.key(day, cal)] ?? [:], entries: state.entries, items: state.items,
                      tree: state.categories, now: Date(), book: state.dayRules, calendar: cal)
    }

    var forecast: DayForecast? {
        DayForecast.make(entries: state.entries, tree: state.categories, now: Date(), isSchoolDay: isSchoolDay,
                         book: state.dayRules, calendar: cal)
    }

    func verdict(_ f: DayForecast) -> ForecastVerdict {
        let today = Days.dayInterval(Date(), cal)
        var soFar: [CategoryID: Int] = [:]
        for s in TimeLog.past(state.entries, in: today, now: Date(), book: state.dayRules, calendar: cal) {
            let p = state.categories.path(s.category)
            soFar[p.count >= 2 ? p[1].id : (p.first?.id ?? s.category), default: 0] += s.minutes
        }
        return ForecastVerdict.make(f, actualSoFar: soFar, tree: state.categories, goals: state.goals, now: Date(), calendar: cal)
    }

    /// Today's score against the median of your similar days (the last 4 same weekdays): (score, usual, label, top differences).
    func scoreVsUsual(_ now: Date) -> (Int, Int, String, [String])? {
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)
        let same = (1...28).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            .filter { cal.component(.weekday, from: $0) == weekday }.prefix(4)
        let scores = same.map { dayScore($0).score }.sorted()
        guard scores.count >= 3 else { return nil }
        let usual = scores[scores.count / 2]
        let diffs = forecast.map { verdict($0).differences.map { "\($0.name) \($0.minutes >= 0 ? "+" : "−")\(minutesLabel(abs($0.minutes)))" } } ?? []
        return (dayScore(today).score, usual, "usual \(DateFormatter.local("EEEE", cal).string(from: today))", diffs)
    }

    // MARK: Places (E)

    /// A visit from iOS (or a geofence): kept in the history, clustered into places, the open one is "here".
    func noteVisit(_ v: PlaceVisit) {
        state.trace.add(v)
        state.visits = Array(state.trace.visits.suffix(200))
        let made = state.placeBook.cluster([v].filter { $0.departure != nil }, now: Date())
        if let p = made.first { Task { await nameFromMap(p) } }
        log(.sensor, "visit", ["arrival": "\(v.arrival)", "departure": v.departure.map { "\($0)" } ?? "open",
                               "place": state.placeBook.place(for: v)?.title ?? "new"])
        save()
    }

    /// E2: Apple's map data names a new place when nothing better does (Starbucks, a school).
    func nameFromMap(_ p: Place) async {
        guard let poi = await LocationService.shared.pointOfInterest(latitude: p.latitude, longitude: p.longitude) else { return }
        state.placeBook.setPOI(p.id, poi)
        save()
    }

    func renamePlace(_ id: UUID, _ name: String) { state.placeBook.name(id, name); save() }

    func forgetPlace(_ id: UUID) {
        var es = state.entries
        state.placeBook.forget(id, entries: &es)
        state.entries = es
        save()
    }

    /// Settings → Privacy: the whole location history, places and every entry's place.
    func forgetLocationHistory() {
        state.trace = LocationTrace()
        state.visits = []
        state.placeBook = PlaceBook()
        for i in state.entries.indices { state.entries[i].placeId = nil }
        log(.sensor, "location_forgotten")
        toast = "Location history forgotten."
        save()
    }

    func placeName(_ id: UUID?) -> String? { id.flatMap { pid in state.placeBook.places.first { $0.id == pid }?.title } }

    // MARK: Categories (C4, K4)

    func renameCategory(_ id: CategoryID, _ name: String) {
        applyUI([BoxOp(.category, .change, ref: id, BoxFields(title: name))], what: "rename category")
    }

    func recolourCategory(_ id: CategoryID, _ colour: String) {
        applyUI([BoxOp(.category, .change, ref: id, BoxFields(colour: colour))], what: "recolour category", quiet: true)
    }

    func mergeCategory(_ id: CategoryID, into: CategoryID) {
        applyUI([BoxOp(.category, .remove, ref: id, BoxFields(category: into))], what: "merge category")
        state.categoryRules.remap(id, to: into)
    }

    /// The taxonomy pass (C5): at most daily, when new leaves filled up or weekly.
    func taxonomyPass() async {
        let now = Date()
        guard TaxonomyPass.due(tree: state.categories, entries: state.entries, log: state.taxonomy, now: now), aiAllowed(.taxonomy) else { return }
        state.taxonomy.lastRun = now
        guard let out = try? await ClaudeClient.shared.structured(
            feature: .taxonomy, system: TaxonomyPass.system(),
            user: TaxonomyPass.request(tree: state.categories, entries: state.entries, rules: state.categoryRules, now: now, calendar: cal),
            schema: TaxonomyPass.schema, as: TaxonomyPass.Output.self, maxTokens: 1200, accept: { _ in true }) else { return }
        var tree = state.categories, es = state.entries, rules = state.categoryRules
        let (run, refused) = TaxonomyPass.apply(out.ops, tree: &tree, entries: &es, rules: &rules, now: now)
        log(.ai, "taxonomy", ["applied": run?.lines.joined(separator: " | ") ?? "", "refused": refused.joined(separator: " | ")])
        guard let run else { return }
        state.categories = tree
        state.entries = es
        state.categoryRules = rules
        state.taxonomy.runs.append(run)
        state.taxonomy.runs = Array(state.taxonomy.runs.suffix(30))
        save()
    }

    func revertTaxonomy(_ id: UUID) {
        guard let i = state.taxonomy.runs.firstIndex(where: { $0.id == id && !$0.reverted }) else { return }
        var tree = state.categories, es = state.entries
        TaxonomyPass.revert(state.taxonomy.runs[i], tree: &tree, entries: &es)
        state.categories = tree
        state.entries = es
        state.taxonomy.runs[i].reverted = true
        replan()
    }

    /// "Never change this": the node becomes yours, so the pass leaves it alone.
    func pinCategory(_ id: CategoryID) {
        if let i = state.categories.nodes.firstIndex(where: { $0.id == id }) { state.categories.nodes[i].yours = true; save() }
    }

    // MARK: Alarms (J3)

    /// Every alarm you'd hear: your own (entries with an alarm), the wake alarm, and the generated ones.
    var entryAlarmList: [Entry] {
        state.entries.filter { $0.alert?.kind == .alarm && $0.source != .plan }.sorted { $0.start < $1.start }
    }

    func removeAlarm(_ e: Entry) {
        applyUI([BoxOp(.entry, .change, ref: EntryRef.entry(e.id), BoxFields(alert: "none"))], what: "alarm off")
    }

    // MARK: Inferences (N)

    func signals(now: Date) async -> [Signal] {
        let since = now.addingTimeInterval(-2 * 86400)
        var steps: [StepBucket] = []
        for s in state.motion where s.end > since && (s.kind == .walking || s.kind == .running) && s.minutes >= 8 {
            if let n = await MotionService.shared.steps(from: s.start, to: s.end) { steps.append(StepBucket(start: s.start, end: s.end, steps: n)) }
        }
        let plugs = (LocalStore.defaults.array(forKey: LocalStore.Key.chargingTimes) as? [Double] ?? [])
            .map { (Date(timeIntervalSince1970: $0), true) }.filter { $0.0 > since }
        let workouts = state.integrations.health ? await HealthService.shared.workouts(since: since) : []
        return Signals.make(visits: state.trace.visits.filter { ($0.departure ?? now) > since.addingTimeInterval(-12 * 86400) },
                            book: state.placeBook, motion: state.motion.filter { $0.end > since }, steps: steps,
                            pickups: phoneUse.filter { $0 > since }, charger: plugs, alarms: state.inference.alarmStops,
                            workouts: workouts, nights: state.health.suffix(3))
    }

    /// N: run the detectors; sure ones log themselves (as sensor time you can fix), fairly sure ones become the one
    /// question, guesses are left as hints.
    func runInferences() async {
        let now = Date()
        let sig = await signals(now: now)
        let input = InferenceInput(now: now, calendar: cal, signals: sig, entries: state.entries, tree: state.categories,
                                   book: state.placeBook, dayRules: state.dayRules, learner: state.inference.learner,
                                   done: Set(state.inference.done.keys))
        let found = InferenceEngine.run(input)
        for i in found where i.band == .auto { applyInference(i, answer: nil) }
        if let q = InferenceAnswers.next(found), !state.inference.pending.contains(where: { $0.id == q.id }) {
            state.inference.pending = [q]
            log(.sensor, "question", ["kind": q.kind.rawValue, "evidence": q.evidence.joined(separator: "; ")])
        }
        if !found.isEmpty { log(.sensor, "inferences", ["auto": "\(found.filter { $0.band == .auto }.count)", "ask": "\(found.filter { $0.band == .ask }.count)",
                                                       "hint": "\(found.filter { $0.band == .hint }.count)"]) }
    }

    /// Logs a sure inference as `sensor` time (adds become sensor entries; skips and changes go through the box).
    func applyInference(_ i: Inference, answer: String?) {
        state.inference.done[i.id] = Date()
        let ops = answer.map { InferenceAnswers.ops(for: $0, i, calendar: cal) } ?? i.proposal
        var rest: [BoxOp] = []
        for (k, op) in ops.enumerated() {
            if answer == nil, op.noun == .entry, op.verb == .add, let title = op.fields.title,
               let s = op.fields.start.flatMap({ AIMapper.parseDate($0, timeZone: cal.timeZone) }),
               let e = op.fields.end.flatMap({ AIMapper.parseDate($0, timeZone: cal.timeZone) }) {
                var tree = state.categories
                let cat = TimeQueryEngine.categoryId(op.fields.category ?? "", tree)
                    ?? addPath(op.fields.category ?? CategoryTree.other, &tree)
                state.categories = tree
                let id = Entry.sensorId("inference|\(i.id)|\(k)")
                guard !state.entries.contains(where: { $0.id == id }) else { continue }
                state.entries.append(Entry(id: id, title: title, start: s, end: e, category: cat, note: i.evidence.joined(separator: "; "),
                                           source: .sensor, createdAt: Date()))
            } else {
                rest.append(op)
            }
        }
        if !rest.isEmpty { applyUI(rest, what: "inference \(i.kind.rawValue)", quiet: answer == nil) }
        log(.sensor, "inference_applied", ["kind": i.kind.rawValue, "answer": answer ?? "auto"])
        save()
    }

    private func addPath(_ path: String, _ tree: inout CategoryTree) -> CategoryID {
        var parent: CategoryID?
        for n in path.components(separatedBy: "›").map({ $0.trimmingCharacters(in: .whitespaces) }) where !n.isEmpty {
            parent = tree.find(n, under: parent)?.id ?? tree.add(n, under: parent)?.id ?? parent
        }
        return parent ?? CategoryTree.other
    }

    /// The question waiting now, as a notification (N7).
    func questionNudges(now: Date) -> [PlannedNudge] {
        guard let q = state.inference.pending.first, let text = q.question else { return [] }
        let plan = q.kind == .contradiction
        return [PlannedNudge(id: plan ? "track.qplan" : "track.qyes", kind: .question, at: now.addingTimeInterval(60), title: text,
                             body: q.evidence.joined(separator: " · "), window: q.interval)]
    }

    /// An answer from the card or the notification. "Something else" goes to the box as text.
    func answerQuestion(action: String, id: String, text: String) {
        guard let q = state.inference.pending.first else { return }
        let reply: String
        switch action {
        case "q.sick": reply = "Sick"
        case "q.noSchool": reply = "No school today"
        case "q.skipped": reply = "Skipped"
        case "q.yes": reply = q.answers.first ?? "Yes"
        default: reply = "Something else"
        }
        resolveQuestion(q, reply)
        if action == "q.reply" && !text.isEmpty {
            Task { await submit(text, source: .notification, context: q.question) }
        }
    }

    func resolveQuestion(_ q: Inference, _ answer: String) {
        state.inference.pending.removeAll { $0.id == q.id }
        let yes = q.answers.contains(answer) && answer != q.answers.last || answer == "Yes" || answer == "Start it"
        state.inference.learner.answered(q.kind, yes: q.kind == .contradiction ? true : yes)
        state.inference.answers.append(.init(id: q.id, kind: q.kind, answer: answer, at: Date()))
        applyInference(q, answer: answer)
        NotificationService.clearDelivered(prefixes: ["track.q"])
    }

    func dismissQuestion() {
        guard let q = state.inference.pending.first else { return }
        state.inference.pending = []
        state.inference.done[q.id] = Date()
        state.inference.learner.answered(q.kind, yes: false)
        save()
    }

    /// N4: an alarm's stop button, or the Shortcuts "alarm stopped" automation.
    func alarmStopped(ringAt: Date?) {
        let stop = AlarmStop(ringAt: ringAt, stoppedAt: Date())
        state.inference.alarmStops.append(stop)
        log(.alarm, "stopped", ["ringAt": ringAt.map { "\($0)" } ?? "", "snooze": stop.snoozeMinutes.map { "\($0)" } ?? ""])
        Task { await runInferences(); replan() }
    }

    // MARK: Screenshots (M5 / M6)

    /// A new screenshot, read on the phone. Screen Time: applied here, one receipt line; unreadable Screen Time: the box
    /// gets the image; homework-looking: offered as a task (Add sends it to the box).
    func screenshot(text: String, image: UIImage) {
        if let reading = ScreenOCR.parse(text), !reading.apps.isEmpty || reading.period == "week" {
            var me = aboutMe
            let r = BoxSideOps.apply([BoxOp(.screen_time, .add, BoxFields(screen: reading.box))], to: &state, aboutMe: &me, now: Date(), calendar: cal)
            log(.sensor, "screenshot_read", ["lines": r.lines.joined(separator: " | "), "problems": r.problems.joined(separator: " | ")])
            toast = "Read Screen Time from a screenshot" + (r.lines.first.map { ": \($0)" } ?? "")
            replan()
        } else if ScreenOCR.isScreenTime(text) || ScreenOCR.looksLikeAssignment(text) {
            guard let jpg = image.jpegData(compressionQuality: 0.7) else { return }
            let isScreen = ScreenOCR.isScreenTime(text)
            log(.sensor, "screenshot_offer", ["screenTime": "\(isScreen)"])
            if isScreen {
                Task { await submit("(A Screen Time screenshot the phone couldn't read.)",
                                    images: [AIImage(mediaType: "image/jpeg", base64: jpg.base64EncodedString())], source: .share) }
            } else {
                screenshotOffer = AIImage(mediaType: "image/jpeg", base64: jpg.base64EncodedString())
            }
        }
    }

    // MARK: The daily pipeline (called from refresh)

    func refreshLog() async {
        let now = Date()
        // B2: scroll sessions, places on entries, nights; H1: tasks past due end as dropped.
        let scrolled = EntryBuilder.scrolling(Friction.log.sessions, entries: &state.entries, now: now, since: now.addingTimeInterval(-3 * 86400))
        let placed = EntryBuilder.places(&state.entries, visits: state.trace.visits, book: state.placeBook,
                                         since: now.addingTimeInterval(-3 * 86400), now: now)
        let named = state.placeBook.nameFromEntries(state.entries, tree: state.categories)
        let expired = state.taskHistory.expire(state.items, entries: state.entries, now: now, calendar: cal)
        log(.log, "rebuild", level: .debug,
            ["scroll": "\(scrolled.count)", "placed": "\(placed)", "named": "\(named.count)", "expired": "\(expired.count)"])
        await runInferences()
        await ReminderService.shared.sync(self)
    }
}

// MARK: - Haptics (D2 / I4) and donations (M4)

enum Haptics {
    static func start() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func stop() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { g.impactOccurred() }
    }
    static func tap() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
