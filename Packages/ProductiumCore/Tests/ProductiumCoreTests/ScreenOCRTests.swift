import XCTest
@testable import ProductiumCore

/// v1.2 M5 / M6 / M9 / M2. The OCR texts are written to match the iOS 18 Screen Time layouts line by line (Vision
/// returns one line per text block); they are not from real screenshots yet.
final class ScreenOCRTests: XCTestCase {
    let day = """
    9:41
    Screen Time
    Today, 9:41 PM
    Week
    Day
    SCREEN TIME
    Today at 9:41 PM
    3h 22m
    MOST USED
    SHOW CATEGORIES
    Instagram
    1h 36m
    YouTube
    48m
    Safari
    22m
    Messages
    15m
    PICKUPS
    84
    First Pickup Today at 6:42 AM
    NOTIFICATIONS
    150
    """
    let week = """
    Screen Time
    Week
    Daily Average
    4h 5m
    32% from last week
    Total Screen Time 28h 35m
    MOST USED
    TikTok
    9h 12m
    Instagram
    6h 3m
    Notes
    1h 10m
    PICKUPS
    Daily Average 72
    NOTIFICATIONS
    Daily Average 120
    """
    let yesterday = """
    Screen Time
    Yesterday
    SCREEN TIME
    2h 5m
    MOST USED
    Discord 1h 2m
    Snapchat 40m
    PICKUPS
    61
    """
    let dated = """
    Wednesday, Nov 19
    SCREEN TIME
    5h
    Most Used
    YouTube
    3h 30 min
    Safari
    1 hr 5 min
    Pickups 99
    First Pickup 7:05 AM
    Notifications 210
    """
    let categories = """
    Screen Time
    Daily Average
    3h 1m
    MOST USED
    SHOW APPS & WEBSITES
    Social
    2h 10m
    Entertainment
    40m
    """
    let assignment = "Bio Lab Report\nDue Friday, Nov 21 at 11:59 PM\nSubmit on Classroom"

    func testFiveLayouts() {
        let d = ScreenOCR.parse(day)!
        XCTAssertEqual(d.period, "day")
        XCTAssertEqual(d.dateLabel, "Today")
        XCTAssertEqual(d.minutes, 202)
        XCTAssertEqual(d.apps.map(\.name), ["Instagram", "YouTube", "Safari", "Messages"])
        XCTAssertEqual(d.apps.first?.minutes, 96)
        XCTAssertEqual(d.pickups, 84)
        XCTAssertEqual(d.firstPickup, "6:42 AM")
        XCTAssertEqual(d.notifications, 150)

        let w = ScreenOCR.parse(week)!
        XCTAssertEqual(w.period, "week")
        XCTAssertEqual(w.minutes, 245)
        XCTAssertEqual(w.apps.map(\.minutes), [552, 363, 70])
        XCTAssertEqual(w.pickups, 72)
        XCTAssertEqual(w.notifications, 120)

        let y = ScreenOCR.parse(yesterday)!
        XCTAssertEqual(y.dateLabel, "Yesterday")
        XCTAssertEqual(y.minutes, 125)
        XCTAssertEqual(y.apps.map(\.name), ["Discord", "Snapchat"], "one line per app works too")
        XCTAssertEqual(y.pickups, 61)

        let n = ScreenOCR.parse(dated)!
        XCTAssertEqual(n.dateLabel, "Wednesday, Nov 19")
        XCTAssertEqual(n.minutes, 300)
        XCTAssertEqual(n.apps.map(\.minutes), [210, 65])
        XCTAssertEqual(n.pickups, 99)
        XCTAssertEqual(n.firstPickup, "7:05 AM")
        XCTAssertEqual(n.notifications, 210)

        let c = ScreenOCR.parse(categories)!
        XCTAssertEqual(c.minutes, 181)
        XCTAssertTrue(c.apps.isEmpty, "categories aren't apps: the box gets the image instead")
    }

    func testClassifier() {
        XCTAssertTrue(ScreenOCR.isScreenTime(day))
        XCTAssertFalse(ScreenOCR.isScreenTime(assignment))
        XCTAssertTrue(ScreenOCR.looksLikeAssignment(assignment))
        XCTAssertFalse(ScreenOCR.looksLikeAssignment(day))
        XCTAssertNil(ScreenOCR.parse("A photo of a cat\nwith some text"))
    }

    func testReadingAppliesLikeTheBoxsScreenTimeOp() {
        var s = AppState()
        var me = AboutMe.empty
        let op = BoxOp(.screen_time, .add, BoxFields(screen: ScreenOCR.parse(day)!.box))
        let r = BoxSideOps.apply([op], to: &s, aboutMe: &me, now: Fx.mon(21, 45), calendar: Fx.cal)
        XCTAssertTrue(r.problems.isEmpty, "\(r.problems)")
        XCTAssertEqual(s.screen.first?.totalMinutes, 202)
        XCTAssertEqual(s.screen.first?.pickups, 84)
    }

    func testRemindersMirrorDiff() {
        let cal = Fx.cal
        let a = WorkItem(title: "Gatsby essay", kind: .essay, due: Fx.mon(23, plusDays: 4))
        var b = WorkItem(title: "Bio quiz", kind: .quiz, due: Fx.mon(9, plusDays: 2))
        let c = WorkItem(title: "Chem lab", kind: .assignment, due: Fx.mon(9, plusDays: 3))
        let next = [a.id: Fx.mon(16, plusDays: 1)]
        let reminders = [ReminderItem(id: "r-a", title: "Gatsby essay · due Fri", completed: false, taskId: a.id),
                         ReminderItem(id: "r-b", title: "Bio quiz · due Wed", completed: true, taskId: b.id),
                         ReminderItem(id: "r-old", title: "Old thing", completed: false, taskId: UUID()),
                         ReminderItem(id: "r-mine", title: "Buy milk", completed: false, taskId: nil)]
        let d = ReminderMirror.diff(tasks: [a, b, c], reminders: reminders, next: next, calendar: cal)
        XCTAssertEqual(d.create.map(\.0), [c.id])
        XCTAssertEqual(d.create.first?.1, "Chem lab · due Thu")
        XCTAssertEqual(d.retitle.map(\.1), ["Gatsby essay · next Tue 16:00"])
        XCTAssertEqual(d.completeTasks, [b.id], "ticked off in Reminders = done here")
        XCTAssertEqual(d.delete, ["r-old", "r-mine"], "the list is Productium's own")
        b.isDone = true
        XCTAssertTrue(ReminderMirror.diff(tasks: [a, b, c], reminders: reminders, next: next, calendar: cal).delete.contains("r-b"))
    }

    func testToggle() {
        let shower = Entry(title: "Shower", start: Fx.mon(21), end: nil, category: "essentials.shower", source: .you)
        XCTAssertEqual(ActivityToggle.ops("shower", running: shower).map(\.verb), [.stop])
        XCTAssertEqual(ActivityToggle.ops("Homework", running: shower).map(\.verb), [.start])
        XCTAssertEqual(ActivityToggle.ops("Shower", running: nil).first?.fields.title, "Shower")
    }
}
