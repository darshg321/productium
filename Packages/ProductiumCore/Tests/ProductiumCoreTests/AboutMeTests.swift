import XCTest
@testable import ProductiumCore

final class AboutMeTests: XCTestCase {
    let sample = """
    # About me

    ## Stated
    - Applying to Waterloo, McMaster, UofT and Queen's
    - CS club is Thursdays at lunch (you)

    ## Inferred
    - Works best after 8 pm — evidence: 9 of 12 evening blocks done, confidence: med, since 2026-11-17

    ## Patterns

    ## Preferences
    - Short blocks for essays (you)

    ## Notes from me
    - keep this
    """

    func testMarkdownRoundTrips() {
        let me = AboutMe.parse(sample)
        XCTAssertEqual(me[.stated].count, 2)
        XCTAssertTrue(me[.stated][1].byStudent)
        XCTAssertFalse(me[.stated][0].byStudent)
        XCTAssertEqual(me[.inferred].count, 1)
        XCTAssertEqual(me.other, ["## Notes from me", "- keep this"])
        XCTAssertEqual(AboutMe.parse(me.markdown), me, "what's written reads back the same")
    }

    func testStudentLinesSurviveAIUpdates() {
        var me = AboutMe.parse(sample)
        let r = me.apply(AboutMeFact(text: "CS club moved to Fridays", replaces: "CS club is Thursdays at lunch"), by: .box)
        XCTAssertEqual(r, .failure(.studentLine))
        XCTAssertTrue(me[.stated].contains { $0.text == "CS club is Thursdays at lunch" })
        XCTAssertEqual(me.apply(AboutMeFact(section: "Inferred", text: "Avoids essays"), by: .box), .failure(.notAllowed(.inferred)))
        XCTAssertEqual(me.apply(AboutMeFact(section: "Stated", text: "Stated things"), by: .reflection), .failure(.notAllowed(.stated)))
        XCTAssertNoThrow(try me.apply(AboutMeFact(text: "Waterloo drafts 1-2 done"), by: .box).get())
        XCTAssertEqual(me[.stated].last?.text, "Waterloo drafts 1-2 done")
        me.apply(AboutMeFact(text: "Waterloo drafts 1-3 done", replaces: "Waterloo drafts 1-2 done"), by: .box)
        XCTAssertEqual(me[.stated].filter { $0.text.hasPrefix("Waterloo") }.map(\.text), ["Waterloo drafts 1-3 done"])
        me.apply(AboutMeFact(text: "waterloo drafts 1-3 done."), by: .box)
        XCTAssertEqual(me[.stated].filter { $0.text.hasPrefix("Waterloo") }.count, 1)
    }

    func testEditorMarksWhatTheStudentChanged() {
        let old = AboutMe.parse(sample).markdown
        let new = old.replacingOccurrences(of: "- Applying to Waterloo, McMaster, UofT and Queen's",
                                           with: "- Applying to Waterloo, McMaster and UofT")
        let me = AboutMe.studentEdited(old: old, new: new)
        XCTAssertEqual(me[.stated].first?.text, "Applying to Waterloo, McMaster and UofT")
        XCTAssertTrue(me[.stated].first?.byStudent ?? false)
        XCTAssertFalse(me[.inferred].first?.byStudent ?? true, "untouched AI lines stay AI lines")
    }

}
