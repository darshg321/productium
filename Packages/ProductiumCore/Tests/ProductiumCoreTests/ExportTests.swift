import XCTest
@testable import ProductiumCore

final class ExportTests: XCTestCase {
    static func populated() -> AppState {
        var s = AppState()
        let now = Fx.mon(12)
        s.onboarded = true
        s.prefs.sleepNeedMinutes = 560
        let task = WorkItem(title: "Essay", kind: .essay, due: Fx.mon(23, plusDays: 4), completedMinutes: 30)
        s.items = [task]
        s.entries = Fx.timetable
        s.moods = [MoodEntry(at: now, mood: 4)]
        s.progress = [ProgressEntry(at: now, itemId: task.id, minutes: 30, from: 0, to: 30, source: .task)]
        s.health = [HealthDay(day: Fx.mon(0), steps: 4000)]
        s.motion = [MotionSpan(start: Fx.mon(8), end: Fx.mon(8, 14), kind: .walking, confidence: 2)]
        s.screen = [ScreenDay(day: Fx.mon(0), distractingMinutes: 131, totalMinutes: 202)]
        s.learned.adherenceSamples = 3
        s.policy.maxBlockMinutes = 45
        _ = s.beliefs.state("study.schoolDayCapacity", 120, now: now)
        s.taper.baselineMinutes = 130
        // v1.2 (B6 / E5): the log, the tree, places, the location history and everything that learns.
        let math = s.categories.add("Math", under: CategoryTree.studying, yours: true)!
        s.entries.append(Entry(title: "Math homework", start: Fx.mon(16), end: Fx.mon(17), category: math.id, topics: ["math"],
                               marks: ["2026-11-16": .confirmed], source: .you, createdAt: now))
        s.rules = [Rule(text: "No study after 9:45", limits: PlannerLimits(noStudyAfter: TimeOfDay(21, 45)), createdAt: now)]
        s.dayPlans = ["2026-11-16": [task.id: 40]]
        s.goals = [Goal(title: "Studying", measure: .category(CategoryTree.studying), period: .day, target: 120, createdAt: now)]
        s.placeBook.cluster([PlaceVisit(latitude: 43.6, longitude: -79.4, arrival: now, departure: now.addingTimeInterval(3600))], now: now)
        s.trace.add(TracePoint(at: now, latitude: 43.6, longitude: -79.4, accuracy: 30))
        s.trace.add(PlaceVisit(latitude: 43.6, longitude: -79.4, arrival: now, departure: now.addingTimeInterval(3600)))
        s.quickStarts.noteStart(Entry(title: "Shower", start: now, end: nil, category: "essentials.shower", source: .you), at: now)
        s.categoryRules.correct("Shower", from: CategoryTree.other, to: "essentials.shower", at: now)
        s.outbox.add("gym with sam", source: .notification, at: now)
        s.prompts.asked = [.init(at: now, stretchStart: now, past: false)]
        s.taskHistory.add(TaskHistory.record(task, cleared: true, why: "no time", entries: [], now: now, calendar: Fx.cal))
        s.inference.learner.answered(.walk, yes: true)
        s.inference.alarmStops = [AlarmStop(ringAt: now, stoppedAt: now.addingTimeInterval(600))]
        s.approvals = [Approval(ops: [BoxOp(.entry, .add, BoxFields(title: "Wake", start: "06:40", alert: "alarm"))], why: "alarm",
                                source: .insight, at: now)]
        s.pinnedCharts = [PinnedChart(title: "Math", query: TimeQuery(id: "q1", range: .init(last: "28d"), filter: .init(categories: ["School › Math"])), pinnedAt: now)]
        s.plan = Planner.plan(Fx.input(now: Fx.mon(7), items: [task]))
        s.places = [SavedPlace(id: "home", name: "Home", latitude: 43.6, longitude: -79.4)]
        s.integrations.health = true
        s.review = WeeklyReview(headline: "Good week", wins: ["Slept"], suggestions: [])
        s.reviewAt = now
        var c = Conversation(startedAt: now)
        c.add(ConversationTurn(at: now, text: "hi", images: [AIImage(mediaType: "image/png", base64: "aGk=")],
                               userContent: .array([.object(["type": "text", "text": "hi"])]),
                               assistantContent: .array([.object(["type": "tool_use", "id": "toolu_1", "name": "apply", "input": [:]])]),
                               reply: "Hello", applied: AppliedReport(changes: ["Added Essay"])))
        s.conversation = c
        s.archive.archive(c, now: now)
        s.appOpens = [now]
        s.insightAt = now
        s.rewardSettings = RewardSettings(level: .subtle, surpriseRate: 0.1)
        var rlog = RewardLog()
        Rewards.respond(to: .planFinished(freeMinutesLeft: 40), log: &rlog, settings: s.rewardSettings, now: now, calendar: Fx.cal)
        s.rewards = rlog
        var ds = s.dumpState
        s.changes.apply(InsightRun(at: now, note: "n", model: "sonnet"),
                        [LoggedChange(runId: UUID(), change: .knob(key: "planner.maxBlockMinutes", to: 45),
                                      reason: "r", evidence: ["e"], model: "sonnet", at: now)], to: &ds, now: now)
        s.dumpState = ds
        s.changes.pinned = ["planner.freeTimeMultiplier"]
        s.dismissed = ["a warning"]
        s.dayRules.sequences = [DaySequence(name: "school", rule: .weekdays([2, 3, 4, 5, 6]), anchor: now)]
        s.dayRules.label("exam-week", [now], calendar: Fx.cal)
        s.visits = [PlaceVisit(latitude: 43.6, longitude: -79.4, arrival: now)]
        s.declinedPlaces = ["gym"]
        s.draft = Draft(text: "half a thought", imageFiles: ["a.jpg"])
        s.usage.record(UsageRecord(at: now, feature: .box, model: "sonnet", tokens: TokenCount(output: 90)))
        s.snoozed = [UUID(): now.addingTimeInterval(600)]
        return s
    }



    func bundle(_ s: AppState) -> ExportBundle {
        var log = AICallLog()
        log.append(AICall(at: Fx.mon(12), feature: .box, requestedModel: "sonnet", system: "s",
                          messages: [AICall.Message(role: "user", content: "hi")], maxTokens: 3000))
        return ExportBundle(exportedAt: Fx.mon(12), device: ExportBundle.Device(appVersion: "1.0.0", appBuild: "7", timeZone: "America/Toronto"),
                            state: s, aboutMe: AboutMe.parse("## Stated\n- Walks to school").markdown, callLog: log,
                            sharedDefaults: ["friction.scrollLog": .object(["$data": "e30="])], appDefaults: ["server.url": "https://pi"],
                            files: ["last-ai-error.txt": "b29wcw=="],
                            pendingNotifications: [ExportBundle.Notification(id: "plan.start.x", title: "Essay", body: "Starting now")],
                            permissions: ["location": "authorizedWhenInUse"])
    }

    func testEveryStoredPropertyIsExported() throws {
        let s = Self.populated()
        let data = try ExportBundle.encoder().encode(s)
        let keys = Set((try JSONSerialization.jsonObject(with: data) as! [String: Any]).keys)
        for child in Mirror(reflecting: s).children {
            guard let label = child.label.map({ $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }) else { continue }
            XCTAssertTrue(keys.contains(label), "AppState.\(label) isn't in the export (set it in populated() if it's new)")
        }
        let bundleKeys = Set(Mirror(reflecting: bundle(s)).children.compactMap(\.label))
        for store in ExportBundle.nonStateStores {
            XCTAssertTrue(bundleKeys.contains(store), "\(store) isn't in the export")
        }
    }

    func testRoundTripIsIdentical() throws {
        let first = try ExportBundle.encoder().encode(bundle(Self.populated()))
        let imported = try ExportBundle.read(first)
        var wiped = AppState()
        wiped.restore(full: imported.state, keepingDevice: false)
        var again = imported
        again.state = wiped
        let second = try ExportBundle.encoder().encode(again)
        XCTAssertEqual(String(data: first, encoding: .utf8), String(data: second, encoding: .utf8))
        XCTAssertEqual(imported.state.conversation.turns.first?.images.first?.base64, "aGk=", "prompts keep their images")
    }

    func testOlderFormatsAreRefused() {
        let old = #"{"format":"productium-backup","version":2,"exportedAt":"2026-11-17T13:28:00Z","state":{}}"#
        XCTAssertThrowsError(try ExportBundle.read(Data(old.utf8)))
        let v3 = #"{"format":"productium-export","version":3,"exportedAt":"2026-11-17T13:28:00Z","state":{}}"#
        XCTAssertThrowsError(try ExportBundle.read(Data(v3.utf8))) { e in
            XCTAssertTrue("\(e)".contains("format 3"), "\(e)")
        }
        XCTAssertThrowsError(try ExportBundle.read(Data("{}".utf8)))
    }

    func testNothingIsPrunedBeforeExport() {
        var s = Self.populated()
        s.entries.append(Entry(title: "old", start: Fx.mon(0, plusDays: -400), end: Fx.mon(1, plusDays: -400), category: CategoryTree.other, source: .you))
        let before = s.entries.count
        s.prune(now: Fx.mon(12))
        XCTAssertEqual(s.entries.count, before)
    }
}
