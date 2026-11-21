import Foundation
import ProductiumCore

// v1.2 O9 everyday set (start, stop, log, add, done, skip, confirm, mood), the A1–A3 regressions, the new nouns
// (goal, place, category), the H2 warning, K1's removed form actions, and the exception set (sick week, half day,
// teacher moved a class, exam week, phone taken at 10, rained-out practice, a trip). World: Wed 18 Nov 2026 (even).

enum V12More {
    typealias W = World

    static func entries(_ s: BoxState, _ f: (Entry) -> Bool) -> [Entry] { s.entries.filter(f) }
    static func has(_ s: String, _ words: [String]) -> Bool { words.contains { s.lowercased().contains($0) } }
    static func stamp(_ d: Date) -> String { QuickParse.stamp(d, W.cal) }

    static let everyday: [V12Case] = [
        V12Case(id: "e-start-shower", why: "plain start: a running entry, filed under Essentials", now: W.at(18, 21), setup: { $0 = W.base() },
                turns: ["starting shower"],
                reference: [[BoxOp(.entry, .start, BoxFields(title: "Shower", category: "essentials.shower"))]],
                check: { s in
                    var e = Expect()
                    let r = TimeLog.running(s.entries)
                    e.that(r?.title.lowercased().contains("shower") == true, "Shower is running: \(String(describing: r?.title))")
                    e.that(r.map { s.categories.isUnder($0.category, CategoryTree.essentials) } == true, "filed under Essentials: \(r?.category ?? "-")")
                    return e.fails
                }),
        V12Case(id: "e-log-volleyball", why: "B5: told afterwards, an exact past stretch", now: W.at(18, 18), setup: { $0 = W.base() },
                turns: ["3 to 5 I was at volleyball"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "Volleyball", start: "15:00", end: "17:00", category: "Work › Extracurricular › Volleyball"))]],
                check: { s in
                    var e = Expect()
                    let v = s.entries.first { $0.title.lowercased().contains("volleyball") }
                    e.that(v?.start == W.at(18, 15) && v?.end == W.at(18, 17), "15:00–17:00: \(String(describing: v.map { "\(W.hm($0.start))–\($0.end.map(W.hm) ?? "")" }))")
                    e.that(v.map { s.categories.isUnder($0.category, CategoryTree.extracurricular) } == true, "under Extracurricular: \(v?.category ?? "-")")
                    return e.fails
                }),
        V12Case(id: "e-tiktok-like", why: "B5: vague end ('like 11:30'), scrolling is one category (a Saturday, so the morning is free)",
                now: W.at(21, 14), setup: { $0 = W.base() },
                turns: ["I was on TikTok from 10 till like 11:30"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "TikTok", start: "10:00", end: "11:30", category: CategoryTree.scrolling))]],
                check: { s in
                    var e = Expect()
                    let t = s.entries.first { $0.title.lowercased().contains("tiktok") }
                    e.that(t?.start == W.at(21, 10) && t?.end == W.at(21, 11, 30), "Sat 10:00–11:30")
                    e.that(t?.category == CategoryTree.scrolling, "Unproductive › Scrolling: \(t?.category ?? "-")")
                    return e.fails
                }),
        V12Case(id: "e-that-was-actually", why: "B5: a correction to the entry just logged", now: W.at(18, 18), setup: { $0 = W.base() },
                turns: ["3 to 5 I was at volleyball", "actually it started at 3:30"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "Volleyball", start: "15:00", end: "17:00", category: "Work › Extracurricular › Volleyball"))], []],
                check: { s in
                    var e = Expect()
                    let v = s.entries.filter { $0.title.lowercased().contains("volleyball") }
                    e.that(v.count == 1 && v[0].start == W.at(18, 15, 30) && v[0].end == W.at(18, 17), "one Volleyball 15:30–17:00: \(v.map { W.hm($0.start) })")
                    return e.fails
                },
                referenceFor: { turn, s in
                    turn == 0 ? [BoxOp(.entry, .add, BoxFields(title: "Volleyball", start: "15:00", end: "17:00", category: "Work › Extracurricular › Volleyball"))]
                        : [BoxOp(.entry, .change, ref: EntryRef.entry(s.entries.first { $0.title == "Volleyball" }!.id), BoxFields(start: "15:30", end: "17:00"))]
                }),
        V12Case(id: "e-add-task", why: "K1: adding a task is a box path (no form)", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["bio quiz friday on cells, about an hour to study"],
                reference: [[BoxOp(.task, .add, BoxFields(title: "Bio quiz: cells", topics: ["cells"], due: "2026-11-20 08:30", minutes: 60, kind: "quiz"))]],
                check: { s in
                    var e = Expect()
                    let q = s.items.first { $0.title.lowercased().contains("bio") }
                    e.that(q?.kind == .quiz, "a quiz: \(String(describing: q?.kind))")
                    e.that(q.map { W.cal.isDate($0.due, inSameDayAs: W.at(20, 12)) } == true, "due Friday 20th")
                    e.that(q.map { (45...90).contains($0.estimateMinutes) } == true, "about an hour: \(String(describing: q?.estimateMinutes))")
                    return e.fails
                }),
        V12Case(id: "e-edit-task", why: "K1: editing a task is a box path", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["the data quiz needs 3 hours not 2"],
                reference: [[BoxOp(.task, .change, ref: W.ref(W.quiz), BoxFields(minutes: 180))]],
                check: { s in s.items.first { $0.id == W.quiz }?.estimateMinutes == 180 ? [] : ["quiz is 180 min"] }),
        V12Case(id: "e-task-done", why: "done by name", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["finished the annotated bibliography"],
                reference: [[BoxOp(.task, .done, ref: W.ref(W.bibliography))]],
                check: { s in s.items.first { $0.id == W.bibliography }?.isDone == true ? [] : ["bibliography done"] }),
        V12Case(id: "e-skip-dinner", why: "one day of a series skipped, the series kept", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["no family dinner tonight"],
                reference: [], check: { s in
                    var e = Expect()
                    let d = s.entries.first { $0.title == "Dinner" && $0.repeats != nil }
                    e.that(d != nil, "the Dinner series is kept")
                    e.that(!W.on(18, s, now: W.at(18, 16)).contains { $0.title == "Dinner" }, "no dinner on the 18th")
                    e.that(W.on(19, s, now: W.at(18, 16)).contains { $0.title == "Dinner" }, "dinner tomorrow as usual")
                    return e.fails
                },
                referenceFor: { _, s in [BoxOp(.entry, .skip, ref: EntryRef.entry(s.entries.first { $0.title == "Dinner" }!.id, occurrence: "2026-11-18"))] }),
        V12Case(id: "e-confirm-school", why: "yes to assumed time", now: W.at(18, 15, 30), setup: { $0 = W.base() },
                turns: ["school was normal today"],
                reference: [], check: { s in
                    let school = W.on(18, s, now: W.at(18, 15, 30)).filter { s.categories.isUnder($0.category, CategoryTree.school) }
                    return school.allSatisfy { $0.mark == .confirmed } && !school.isEmpty ? [] : ["today's periods confirmed: \(school.map { "\($0.title) \(String(describing: $0.mark))" })"]
                },
                referenceFor: { _, s in
                    W.on(18, s, now: W.at(18, 15, 30)).filter { s.categories.isUnder($0.category, CategoryTree.school) }.map { BoxOp(.entry, .confirm, ref: $0.ref) }
                }),
        V12Case(id: "e-mood", why: "a mood, not a fact or a task", now: W.at(18, 20), setup: { $0 = W.base() },
                turns: ["feeling pretty good today, like 4/5"],
                reference: [[BoxOp(.mood, .add, BoxFields(mood: 4))]],
                check: { s in s.items.count == 6 ? [] : ["no task made"] },
                replyCheck: { _, ops in ops.contains { $0.noun == .mood && $0.fields.mood == 4 } ? [] : ["mood 4 sent: \(ops.map { "\($0.noun) \($0.verb)" })"] }),
        // A1–A3 regressions.
        V12Case(id: "a1-delete-what-you-made", why: "A1: the AI must be able to remove what it just made", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["add a study session for bio at 7 tonight for 45 min", "actually delete that"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "Bio study", start: "19:00", end: "19:45", category: CategoryTree.studying))], []],
                check: { s in s.entries.contains { $0.title.lowercased().contains("bio") && $0.start == W.at(18, 19) } ? ["the bio session is still there"] : [] },
                replyCheck: { _, ops in ops.contains { $0.verb == .add || $0.verb == .start } ? [] : ["the session was made in turn 1"] },
                referenceFor: { turn, s in
                    turn == 0 ? [BoxOp(.entry, .add, BoxFields(title: "Bio study", start: "19:00", end: "19:45", category: CategoryTree.studying))]
                        : [BoxOp(.entry, .remove, ref: EntryRef.entry(s.entries.first { $0.title == "Bio study" }!.id))]
                }),
        V12Case(id: "a1-started-event", why: "A1: an event that has started can still be changed", now: W.at(18, 21, 45), setup: { $0 = W.base() },
                turns: ["valorant got cancelled, never happened"],
                reference: [], check: { s in
                    let v = W.on(18, s, now: W.at(18, 21, 45)).filter { $0.title.hasPrefix("Valorant") && $0.mark != .skipped }
                    return v.isEmpty ? [] : ["Valorant still counts: \(v.map(\.title))"]
                },
                referenceFor: { _, s in [BoxOp(.entry, .skip, ref: EntryRef.entry(s.entries.first { $0.title.hasPrefix("Valorant") }!.id))] }),
        // New nouns.
        V12Case(id: "i2-goal", why: "I2: a goal from plain words", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["my goal is 10 hours of studying a week"],
                reference: [[BoxOp(.goal, .add, BoxFields(category: CategoryTree.studying, target: 600, period: "week"))]],
                check: { s in
                    guard let g = s.goals.first else { return ["no goal"] }
                    var e = Expect()
                    e.that(g.target == 600 && g.period == .week && g.direction == .atLeast, "10h a week, at least: \(g.target) \(g.period)")
                    if case .category(let c) = g.measure { e.that(s.categories.isUnder(c, CategoryTree.work), "counts studying: \(c)") } else { e.that(false, "a category goal") }
                    return e.fails
                }),
        V12Case(id: "e3-this-is-the-library", why: "E3: naming the place you're at", now: W.at(18, 16),
                setup: { s in s = W.base(); s.here = PlaceVisit(latitude: 43.66, longitude: -79.39, arrival: W.at(18, 15, 30)) },
                turns: ["this is the library"],
                reference: [[BoxOp(.place, .add, BoxFields(title: "Library"))]],
                check: { s in s.here.flatMap { s.places.place(for: $0) }?.title.lowercased().contains("library") == true ? [] : ["the place here is Library"] }),
        V12Case(id: "c3-volleyball-under-extracurricular", why: "C3: moving a category", now: W.at(18, 16),
                setup: { s in s = W.base(); s.categories.add("Volleyball", under: CategoryTree.free) },
                turns: ["put volleyball under extracurricular"],
                reference: [[BoxOp(.category, .change, ref: "free.volleyball", BoxFields(category: CategoryTree.extracurricular))]],
                check: { s in
                    let v = s.categories.nodes.filter { $0.name == "Volleyball" }
                    return v.count == 1 && s.categories.isUnder(v[0].id, CategoryTree.extracurricular) ? [] : ["one Volleyball, under Extracurricular: \(v.map { s.categories.pathText($0.id) })"]
                }),
        V12Case(id: "k1-colour", why: "K1: colours are a box path", now: W.at(18, 16),
                setup: { s in s = W.base(); s.categories.add("Volleyball", under: CategoryTree.extracurricular) },
                turns: ["make volleyball green"],
                reference: [[BoxOp(.category, .change, ref: "work.extracurricular.volleyball", BoxFields(colour: "green"))]],
                check: { s in s.categories.node("work.extracurricular.volleyball")?.colour == "green" ? [] : ["Volleyball is green"] }),
        V12Case(id: "k1-add-activity", why: "K1: a weekly activity is a repeating entry", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["I have piano lessons every tuesday 5 to 6"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "Piano lesson", start: "17:00", end: "18:00", day: "2026-11-24",
                                                         category: "Work › Extracurricular › Piano", repeats: .weekdays([3])))]],
                check: { s in
                    let tue = W.on(24, s, now: W.at(18, 16)).filter { $0.title.lowercased().contains("piano") }
                    let tue2 = Days.on(W.at(1, 12).addingTimeInterval(86400 * 30), s.entries, now: W.at(18, 16), calendar: W.cal).filter { $0.title.lowercased().contains("piano") }
                    return tue.count == 1 && W.hm(tue[0].start) == "17:00" && W.hm(tue[0].end) == "18:00" && !tue2.isEmpty ? [] : ["piano Tue 17–18 every week: \(tue.map { W.hm($0.start) })"]
                }),
        // H2: the warning for a usually-dropped kind, and none for a usually-finished one.
        V12Case(id: "h2-warn-reading", why: "H2: adding a kind they usually drop gets the facts and a first step", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["add reading chapters 7-8 of gatsby for friday, about 40 min"],
                reference: [[BoxOp(.task, .add, BoxFields(title: "Gatsby chapters 7–8", due: "2026-11-20 08:30", minutes: 40, kind: "reading",
                                                        firstStep: "Read the first 5 pages of chapter 7"))]],
                check: { s in s.items.contains { $0.title.lowercased().contains("gatsby") && $0.firstStep != nil } ? [] : ["Gatsby task with a first step"] },
                trackRecord: ["reading: dropped 4 of 5, put off 2× on average, worked on after 21:00", "essay: dropped 0 of 4"],
                // The numbers are the app's (`TaskHistory.note`); the model only has to flag it.
                replyCheck: { reply, _ in has(reply, ["dropped", "4 of", "4 out of", "usually", "often", "put off", "slip"]) ? [] : ["the reply flags that readings usually get dropped: \(reply)"] },
                referenceReply: "Added. You've dropped 4 of your last 5 readings, so I named a small first step."),
        V12Case(id: "h2-no-warn-essay", why: "H2: a kind they usually finish gets nothing extra", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["add a history essay due next friday, maybe 3 hours"],
                reference: [[BoxOp(.task, .add, BoxFields(title: "History essay", due: "2026-11-27 08:30", minutes: 180, kind: "essay"))]],
                check: { s in s.items.contains { $0.title.lowercased().contains("history") } ? [] : ["history essay added"] },
                trackRecord: ["reading: dropped 4 of 5, put off 2× on average, worked on after 21:00", "essay: dropped 0 of 4"],
                replyCheck: { reply, _ in has(reply, ["dropped", "usually drop"]) ? ["no warning for essays: \(reply)"] : [] },
                referenceReply: "Added the history essay, due Friday the 27th."),
    ]

    static let exceptions: [V12Case] = [
        V12Case(id: "x-sick-week", why: "a sick week: school skipped for the rest of the week", now: W.at(18, 9), setup: { $0 = W.base() },
                turns: ["im sick, no school for the rest of the week"],
                reference: [[18, 19, 20].map { BoxOp(.entry, .skip, BoxFields(day: W.key($0), category: CategoryTree.school)) }],
                check: { s in
                    let left = [18, 19, 20].flatMap { d in W.on(d, s, now: W.at(18, 9)).filter { s.categories.isUnder($0.category, CategoryTree.school) } }
                    let mon = W.on(23, s, now: W.at(18, 9)).filter { s.categories.isUnder($0.category, CategoryTree.school) }
                    return left.isEmpty && !mon.isEmpty ? [] : ["no school Wed–Fri (\(left.count) left), back Monday (\(mon.count))"]
                }),
        V12Case(id: "x-half-day", why: "early dismissal: tomorrow's school ends at 11:30", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["early dismissal tomorrow, school ends at 11:30"],
                reference: [], check: { s in
                    let thu = W.on(19, s, now: W.at(18, 16)).filter { s.categories.isUnder($0.category, CategoryTree.school) }
                    let after = thu.filter { $0.end > W.at(19, 11, 30) }
                    return !thu.isEmpty && after.isEmpty ? [] : ["Thu school ends by 11:30: \(thu.map { "\($0.title) \(W.hm($0.start))–\(W.hm($0.end))" })"]
                },
                referenceFor: { _, s in
                    W.on(19, s, now: W.at(18, 16)).filter { s.categories.isUnder($0.category, CategoryTree.school) && $0.end > W.at(19, 11, 30) }.map { o in
                        o.start >= W.at(19, 11, 30) ? BoxOp(.entry, .skip, ref: o.ref) : BoxOp(.entry, .change, ref: o.ref, BoxFields(end: "11:30"))
                    }
                }),
        V12Case(id: "x-teacher-moved-math", why: "one day of a series moved", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["math is moved to 1:30 tomorrow, same length"],
                reference: [], check: { s in
                    let m = W.on(19, s, now: W.at(18, 16)).filter { $0.title.contains("Math") }
                    let fri = W.on(20, s, now: W.at(18, 16)).filter { $0.title.contains("Math") }
                    return m.count == 1 && W.hm(m[0].start) == "13:30" && fri.first.map { W.hm($0.start) } == "9:46" ? []
                        : ["Thu Math at 13:30 only, Fri unchanged: \(m.map { W.hm($0.start) }) \(fri.map { W.hm($0.start) })"]
                },
                referenceFor: { _, s in
                    let o = W.on(19, s, now: W.at(18, 16)).first { $0.title.contains("Math") }!
                    return [BoxOp(.entry, .change, ref: o.ref, BoxFields(start: "13:30"))]
                }),
        V12Case(id: "x-exam-week", why: "a rule for a while", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["next week is exam week, keep study blocks to 45 min"],
                reference: [[BoxOp(.rule, .add, BoxFields(from: "2026-11-23", until: "2026-11-27", text: "Exam week: 45-minute blocks",
                                                        limits: PlannerLimits(maxBlockMinutes: 45)))]],
                check: { s in
                    let r = s.rules.first { $0.limits.maxBlockMinutes == 45 }
                    let ev = DayRuleEvaluator(book: s.dayRules, calendar: W.cal)
                    return r != nil && Rules.limits(s.rules, on: W.at(24, 12), ev).maxBlockMinutes == 45
                        && Rules.limits(s.rules, on: W.at(19, 12), ev).maxBlockMinutes == nil ? [] : ["45-min blocks next week only"]
                }),
        V12Case(id: "x-phone-taken-at-10", why: "no study or reminders after 10 tonight", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["my phone is getting taken at 10 tonight so dont plan anything after that"],
                reference: [[BoxOp(.rule, .add, BoxFields(from: "2026-11-18", until: "2026-11-18", text: "Phone taken at 10",
                                                        limits: PlannerLimits(noStudyAfter: TimeOfDay(22))))]],
                check: { s in
                    let plan = W.plan(s, now: W.at(18, 16))
                    let late = plan.blocks.filter { $0.isStudy && W.cal.isDate($0.start, inSameDayAs: W.at(18, 12)) && $0.end > W.at(18, 22) }
                    return late.isEmpty && !s.rules.isEmpty ? [] : ["no study after 22:00 tonight: \(late.map { W.hm($0.end) })"]
                }),
        V12Case(id: "x-rained-out", why: "today's practice didn't happen", now: W.at(18, 17),
                setup: { s in
                    s = W.base()
                    s.entries.append(Entry(title: "Soccer practice", start: W.at(18, 16), end: W.at(18, 17, 30), category: CategoryTree.extracurricular,
                                           repeats: Repeat(.weekdays([4])), source: .you, createdAt: W.at(10, 9)))
                },
                turns: ["practice got rained out"],
                reference: [], check: { s in
                    let today = W.on(18, s, now: W.at(18, 17)).filter { $0.title.contains("Soccer") }
                    let next = W.on(25, s, now: W.at(18, 17)).filter { $0.title.contains("Soccer") }
                    return today.isEmpty && !next.isEmpty ? [] : ["no practice today, next week as usual"]
                },
                referenceFor: { _, s in [BoxOp(.entry, .skip, ref: EntryRef.entry(s.entries.first { $0.title == "Soccer practice" }!.id, occurrence: "2026-11-18"))] }),
        V12Case(id: "x-trip", why: "away for the weekend", now: W.at(18, 16), setup: { $0 = W.base() },
                turns: ["going to montreal this weekend, leaving saturday 8am and back sunday 9pm"],
                reference: [[BoxOp(.entry, .add, BoxFields(title: "Montreal trip", start: "2026-11-21 08:00", end: "2026-11-22 21:00", category: CategoryTree.free))]],
                check: { s in
                    let away = Days.expand(s.entries, in: DateInterval(start: W.at(21, 12), end: W.at(21, 12, 1)), now: W.at(18, 16), calendar: W.cal)
                        .filter { $0.title.lowercased().contains("montreal") || $0.title.lowercased().contains("trip") }
                    let sun = Days.expand(s.entries, in: DateInterval(start: W.at(22, 20), end: W.at(22, 20, 1)), now: W.at(18, 16), calendar: W.cal)
                        .filter { $0.title.lowercased().contains("montreal") || $0.title.lowercased().contains("trip") }
                    return !away.isEmpty && !sun.isEmpty ? [] : ["the trip covers Sat noon and Sun 20:00"]
                }),
    ]
}
