import XCTest
@testable import ProductiumCore

final class VersionTests: XCTestCase {
    func testParsingAndOrdering() {
        XCTAssertEqual(AppVersion("v1.0.3"), AppVersion(1, 0, 3))
        XCTAssertEqual(AppVersion("1.0"), AppVersion(1, 0, 0))
        XCTAssertNil(AppVersion("free-latest"))
        XCTAssertNil(AppVersion("v1.x"))
        XCTAssertTrue(AppVersion(1, 10, 0) > AppVersion(1, 9, 9))
        XCTAssertTrue(AppVersion(2, 0, 0) > AppVersion(1, 99, 99))
    }

    func testOnlyANewerReleaseIsAnUpdate() {
        let r = ReleaseInfo(tag: "v1.0.3", url: "https://github.com/x/y/releases/tag/v1.0.3", checkedAt: Fx.mon(8))
        XCTAssertEqual(r.update(over: "1.0.0")?.description, "v1.0.3")
        XCTAssertNil(r.update(over: "1.0.3"))
        XCTAssertNil(r.update(over: "1.1"))
    }

    func testReleaseJSONAndDailyCheck() {
        let json = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/x/y/releases/tag/v1.2.0","name":"v1.2.0","draft":false}"#.utf8)
        XCTAssertEqual(ReleaseInfo.parse(json, now: Fx.mon(8))?.tag, "v1.2.0")
        XCTAssertNil(ReleaseInfo.parse(Data("{}".utf8), now: Fx.mon(8)))
        XCTAssertTrue(ReleaseInfo.isDue(last: nil, now: Fx.mon(8)))
        XCTAssertFalse(ReleaseInfo.isDue(last: Fx.mon(8), now: Fx.mon(20)))
        XCTAssertTrue(ReleaseInfo.isDue(last: Fx.mon(8), now: Fx.mon(9, plusDays: 1)))
    }
}
