import XCTest
@testable import ProductiumCore

final class HealthStatusTests: XCTestCase {
    func testStepsWithoutSleepIsNotTurnOnHealth() {
        let days = (0..<7).map { HealthDay(day: Fx.mon(0, plusDays: -$0), steps: 8000) }
        let s = HealthStatus.resolve(wantsHealth: true, requestNeeded: false, days: days)
        XCTAssertEqual(s, .noSleepSource)
        XCTAssertTrue(s.emptyMessage!.hasPrefix("Health is connected, but nothing on your phone records sleep."))
        XCTAssertFalse(s.emptyMessage!.contains("Turn on Health in Settings"))
    }

    func testNotAskedAndConnectedWithSleep() {
        XCTAssertEqual(HealthStatus.resolve(wantsHealth: false, requestNeeded: false, days: []), .notAsked)
        XCTAssertEqual(HealthStatus.resolve(wantsHealth: true, requestNeeded: true, days: []), .notAsked)
        let measured = HealthDay(day: Fx.mon(0), sleepMinutes: 450, bedtime: Fx.mon(0), wake: Fx.mon(7), sleepSource: .health)
        XCTAssertEqual(HealthStatus.resolve(wantsHealth: true, requestNeeded: false, days: [measured]), .withSleep)
        XCTAssertNil(HealthStatus.withSleep.emptyMessage)
    }

    func testEstimatedSleepDoesNotCountAsAMeasuredSource() {
        let estimated = HealthDay(day: Fx.mon(0), steps: 5000, sleepMinutes: 386, sleepSource: .checkIns)
        XCTAssertEqual(HealthStatus.resolve(wantsHealth: true, requestNeeded: false, days: [estimated]), .noSleepSource)
    }
}
