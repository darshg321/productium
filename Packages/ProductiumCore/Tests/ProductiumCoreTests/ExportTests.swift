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
        s.commitments = [Fx.school]
        s.routines[1].samples = [14]
        s.markers = [TimelineEvent(at: now, phrase: "left home", activity: "to_school", category: .commute, phase: .start)]
        s.outcomes = [BlockOutcome(blockId: UUID(), itemId: task.id, kind: .essay, plannedStart: now, plannedMinutes: 40,
                                   actualMinutes: 40, status: .done, loggedAt: now)]
        s.moods = [MoodEntry(at: now, mood: 4)]
        s.progress = [ProgressEntry(at: now, itemId: task.id, minutes: 30, from: 0, to: 30, source: .task)]
        s.health = [HealthDay(day: Fx.mon(0), steps: 4000)]
        s.motion = [MotionSpan(start: Fx.mon(8), end: Fx.mon(8, 14), kind: .walking, confidence: 2)]
        s.screen = [ScreenDay(day: Fx.mon(0), distractingMinutes: 131, totalMinutes: 202)]
        s.events = [FixedEvent(id: "EK:1", title: "CS Club Meeting", start: now, end: now.addingTimeInterval(3000))]
        s.oneOffs = [FixedEvent(id: UUID().uuidString, title: "Dentist", start: now, end: now.addingTimeInterval(3600))]
        s.exceptions = [DayException(day: Fx.mon(0, plusDays: 1), kind: .school, cancelled: true)]
        s.learned.adherenceSamples = 3
        s.policy.maxBlockMinutes = 45
        _ = s.beliefs.state("study.schoolDayCapacity", 120, now: now)
        s.taper.baselineMinutes = 130
        s.flashcards = [Flashcard(itemId: task.id, subject: nil, front: "Q", back: "A")]
        s.reads = [ReadPiece(title: "T", body: "B", subject: nil, question: "Q", source: "Claude")]
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
        s.focus = FocusSession(blockId: UUID(), itemId: nil, title: "Essay", startedAt: now, plannedEnd: now.addingTimeInterval(2400))
        s.gaps = GapLog(asked: [AskedGap(start: now, end: now.addingTimeInterval(3000), askedAt: now, answer: "gym", activity: "exercise")])
        s.appOpens = [now]
        s.reflectionAt = now
        s.proposals.submit(ReflectionRun(at: now, note: "n", model: "opus"),
                           [BehaviourProposal(runId: UUID(), change: .knob(key: "planner.maxBlockMinutes", to: 45), from: "", to: "",
                                              reason: "r", evidence: ["e"], model: "opus", at: now)], state: s.dumpState, now: now)
        s.dismissed = ["a warning"]
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
        XCTAssertThrowsError(try ExportBundle.read(Data(old.utf8))) { e in
            XCTAssertTrue("\(e)".contains("format 2"), "\(e)")
        }
        XCTAssertThrowsError(try ExportBundle.read(Data("{}".utf8)))
    }

    func testNothingIsPrunedBeforeExport() {
        var s = Self.populated()
        s.markers.append(TimelineEvent(at: Fx.mon(0, plusDays: -400), phrase: "old", activity: "x", category: .free, phase: .point))
        s.prune(now: Fx.mon(12))
        XCTAssertEqual(s.markers.count, 2)
    }
}
