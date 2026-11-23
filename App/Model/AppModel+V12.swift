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
        clearPlannedSessions(of: id)
        state.taskHistory.add(TaskHistory.record(state.items[i], cleared: true, why: why, entries: state.entries, now: Date(), calendar: cal))
        if running?.taskId == id { stopRunning(source: "clear") }
        log(.log, "task_cleared", ["title": state.items[i].title, "why": why ?? ""])
        toast = "Cleared. It's counted, so Productium learns from it."
        toastUndo = id
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
        let days = (month.map { m in stride(from: m.start, to: min(m.end, now), by: 86400).map { $0 } } ?? []).filter(isTracked)
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

    /// The first day you used Productium (see `AppState.trackingSince`).
    var trackingStart: Date { cal.startOfDay(for: state.trackingSince ?? Date()) }

    /// A day the log can say something about. Health and Screen Time from before it still count; the log doesn't.
    func isTracked(_ day: Date) -> Bool { cal.startOfDay(for: day) >= trackingStart }

    /// The day's score, or nil for a day before you used Productium.
    func trackedScore(_ day: Date) -> DayScore? { isTracked(day) ? dayScore(day) : nil }

    func dayScore(_ day: Date) -> DayScore {
        DayScore.make(day, asked: state.dayPlans[DayKeys.key(day, cal)] ?? [:], entries: state.entries, items: state.items,
                      tree: state.categories, now: Date(), book: state.dayRules, calendar: cal)
    }

    /// Today's score against the median of your similar days (the last 4 same weekdays): (score, usual, label, top differences).
    func scoreVsUsual(_ now: Date) -> (Int, Int, String, [String])? {
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)
        let same = (1...28).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            .filter { cal.component(.weekday, from: $0) == weekday && isTracked($0) }.prefix(4)
        let scores = same.map { dayScore($0).score }.sorted()
        guard scores.count >= 3 else { return nil }
        let usual = scores[scores.count / 2]
        let minutes = { (d: Date) in
            DayCompare.minutes(d, entries: self.state.entries, tree: self.state.categories, now: Date(), book: self.state.dayRules, calendar: self.cal)
        }
        let diffs = DayCompare.changes(today: minutes(today), usual: same.map(minutes), tree: state.categories)
            .map { "\($0.name) \($0.minutes >= 0 ? "+" : "−")\(minutesLabel(abs($0.minutes)))" }
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

    /// E2: the address names a new place when nothing better does (a school, "12 Oak St").
    func nameFromMap(_ p: Place) async {
        guard let found = await LocationService.shared.lookup(latitude: p.latitude, longitude: p.longitude),
              let i = state.placeBook.places.firstIndex(where: { $0.id == p.id }) else { return }
        state.placeBook.setPOI(p.id, found.name)
        state.placeBook.places[i].address = found.address
        save()
    }

    private static var lookingUp = false
    /// Every place gets its street address (a few per refresh: the geocoder is rate-limited).
    func fillAddresses() async {
        guard !Self.lookingUp else { return }
        Self.lookingUp = true
        defer { Self.lookingUp = false }
        for p in state.placeBook.places.filter({ $0.address == nil }).sorted(by: { $0.visits > $1.visits }).prefix(8) {
            await nameFromMap(p)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    /// Places you go to that you haven't named yet, most visited first (Today asks one at a time).
    var placesToName: [Place] {
        state.placeBook.places.filter { !$0.confirmed && $0.visits >= 2 && !state.dismissed.contains("place:\($0.id)") }
            .sorted { $0.visits > $1.visits }
    }

    func skipNaming(_ id: UUID) {
        state.dismissed.insert("place:\(id)")
        save()
    }

    func renamePlace(_ id: UUID, _ name: String) { state.placeBook.name(id, name); save() }

    /// H2: two places that are the same spot become one (the first keeps its name; time there moves with it).
    func mergePlace(_ gone: UUID, into keep: UUID) {
        var es = state.entries
        state.placeBook.merge(keep, gone, entries: &es)
        state.entries = es
        log(.sensor, "places_merged")
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
        aiWorking = "Sorting categories"
        defer { aiWorking = nil }
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
        toast = run.lines.count == 1 ? run.lines[0] : "Tidied categories: \(run.lines.prefix(2).joined(separator: ", "))…"
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

    // MARK: M7: filing with Apple's on-device model when no rule fits

    func fileOnDevice(_ id: UUID) async {
        guard let e = state.entries.first(where: { $0.id == id }) else { return }
        let tree = state.categories
        let paths = tree.nodes.filter { !tree.isUnder($0.id, CategoryTree.school) }.map { tree.pathText($0.id) }
        guard let path = await OnDeviceModel.categorise(e.title, paths: paths),
              let node = tree.nodes.first(where: { tree.pathText($0.id) == path }),
              let i = state.entries.firstIndex(where: { $0.id == id }), state.entries[i].category == CategoryTree.other else { return }
        state.entries[i].category = node.id
        state.categoryRules.learn(e.title, node.id, byYou: false, at: Date())
        if let b = state.quickStarts.buttons.first(where: { $0.key == CategoryRules.key(e.title) }) {
            state.quickStarts.recategorise(b.id, to: node.id)
        }
        log(.ai, "on_device_filed", ["title": e.title, "path": path])
        save()
    }

    // MARK: Screenshots (M5 / M6)

    /// A new screenshot, read on the phone. Screen Time: applied here, one receipt line; unreadable Screen Time: the box
    /// gets the image; homework-looking: offered as a task (Add sends it to the box).
    func screenshot(text: String, image: UIImage) {
        if let reading = ScreenOCR.parse(text),
           !reading.apps.isEmpty || reading.period == "week" || reading.pickups != nil || reading.notifications != nil {
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

    // MARK: Apps (the "Opened an App" / "Closed an App" automations)

    /// An app opened (any app, from the automation): its session starts, the log updates now, not at the next refresh.
    func appOpened(_ app: String) {
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines)
        // E1: the automation's App field left as the word "App": Settings → Screen Time says how to fix it.
        if AppKinds.isPlaceholder(name) {
            LocalStore.defaults.set(Date().timeIntervalSince1970, forKey: LocalStore.Key.appLiteralAt)
            return
        }
        LocalStore.defaults.removeObject(forKey: LocalStore.Key.appLiteralAt)
        guard !name.lowercased().hasPrefix("productium") else { return }
        ScrollingApps.register([(name, nil)], into: &state.scrollingApps)
        let scrolling = ScrollingApps.isScrolling(name, state.scrollingApps)
        Friction.update { $0.seen(name, at: Date(), scrolling: scrolling) }
        rebuildAppEntries()
    }

    /// When the "Opened an App" automation last sent the word "App" instead of the app's name (nil once fixed).
    var appLiteralSeen: Date? {
        let t = LocalStore.defaults.double(forKey: LocalStore.Key.appLiteralAt)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// v1.5 repairs at launch: start buttons made from misread titles; sessions, entries and the list entry 1.4 made
    /// from the word "App" (E1).
    func launchRepairs() {
        let removed = Friction.update { log -> Int in
            let before = log.sessions.count
            log.sessions.removeAll { AppKinds.isPlaceholder($0.app) && $0.scrolling != nil }
            return before - log.sessions.count
        }
        if state.quickStarts.hideTimeWordButtons() > 0 { save() }
        // C1: sessions planned before 1.5 were titled "Reading · 2 of 5".
        for i in state.entries.indices where state.entries[i].source == .plan {
            if let r = state.entries[i].title.range(of: #"\s*·\s*\d+\s*(of|/)\s*\d+$"#, options: .regularExpression) {
                state.entries[i].title = String(state.entries[i].title[..<r.lowerBound])
            }
        }
        let stale = state.scrollingApps.keys.filter { AppKinds.isPlaceholder($0) && $0.lowercased() != "scrolling app" }
        guard removed > 0 || !stale.isEmpty else { return }
        for k in stale { state.scrollingApps[k] = nil }
        state.entries.removeAll { $0.source == .sensor && AppKinds.isPlaceholder($0.title) && $0.title.lowercased() != "scrolling app" }
        if let id = state.categories.children(CategoryTree.scrolling).first(where: { $0.name == "App" })?.id,
           !state.entries.contains(where: { $0.category == id }) {
            state.categories.nodes.removeAll { $0.id == id }
        }
        log(.sensor, "app_literal_dropped", ["sessions": "\(removed)", "apps": stale.joined(separator: ",")])
        save()
    }

    /// App sessions as sensor entries: Scrolling › the app, Messaging, or nothing (it still counts as screen time).
    /// Assumed until you say yes; what you track yourself wins over them.
    @discardableResult
    func rebuildAppEntries(save shouldSave: Bool = true) -> [UUID] {
        let now = Date()
        var tree = state.categories
        let list = state.scrollingApps, rules = state.categoryRules
        var entries = state.entries
        let ids = EntryBuilder.apps(Friction.log.sessions, entries: &entries, now: now, since: now.addingTimeInterval(-3 * 86400)) {
            AppKinds.category(for: $0.app, list: list, rules: rules, tree: &tree, pausedApp: $0.scrolling == nil)
        }
        if tree != state.categories { state.categories = tree }
        if entries != state.entries { state.entries = entries }
        if shouldSave { save() }
        return ids
    }

    /// Today's minutes per app from the automations (every app once "Opened an App" is set up).
    func appMinutesToday() -> [(app: String, minutes: Int)] {
        Friction.log.minutes(on: Date(), calendar: cal).filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    func appKind(_ app: String) -> CategoryID? {
        if ScrollingApps.isScrolling(app, state.scrollingApps) { return CategoryTree.scrolling }
        return AppKinds.isMessaging(app) ? CategoryTree.messaging : nil
    }

    func setScrollingApps(_ ticked: Set<String>) {
        for app in ScrollingApps.common { state.scrollingApps[app] = ticked.contains(app) }
        for app in ticked { state.scrollingApps[app] = true }
        state.screen = state.screen.map { $0.recomputed(state.scrollingApps) }
        state.screenAverages = state.screenAverages.map { $0.recomputed(state.scrollingApps) }
        save()
    }

    func addFeedback(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        state.feedback.append(Feedback(at: Date(), text: t, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String))
        log(.lifecycle, "feedback", ["chars": "\(t.count)"])
        save()
    }

    /// How much of `day` (awake) has something in it already.
    func plannedShare(_ day: Date) -> PlannedShare {
        PlannedShare.make(day, entries: state.entries, tree: state.categories, now: Date(), book: state.dayRules, calendar: cal)
    }

    /// The last 7 days, for Review → Your Week.
    func weekRecap() -> WeekRecap? {
        let today = cal.startOfDay(for: Date())
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }.filter(isTracked)
        let before = (7..<35).compactMap { cal.date(byAdding: .day, value: -$0, to: today) }.compactMap(trackedScore)
        return WeekRecap.make(days: days, scores: days.map(dayScore), before: before, entries: state.entries, tree: state.categories,
                              moods: state.moods, now: Date(), book: state.dayRules, calendar: cal)
    }

    // MARK: The daily pipeline (called from refresh)

    func refreshLog() async {
        let now = Date()
        // B2: scroll sessions, places on entries, nights; H1: tasks past due end as dropped.
        let scrolled = rebuildAppEntries(save: false)
        let placed = EntryBuilder.places(&state.entries, visits: state.trace.visits, book: state.placeBook,
                                         since: now.addingTimeInterval(-3 * 86400), now: now)
        Task { await fillAddresses() }
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
