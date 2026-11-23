import Foundation
import UserNotifications
import ProductiumCore

enum NotificationService {
    static let scrollCategory = NotificationCategory.scroll.rawValue
    /// N7: a plan-vs-reality question ("You're home, but school's on until 3") has its own fixed answers.
    static let planQuestionCategory = "QUESTION_PLAN"

    /// The last start buttons offered on "What are you up to?" (its actions are re-registered with them).
    private static var buttons: [String] = []

    /// Categories, with the current top start buttons as the untracked prompt's one-tap answers (A8: every question
    /// has a text field *and* one-tap answers).
    static func register(buttons new: [String]? = nil) {
        if let new { buttons = Array(new.prefix(3)) }
        func a(_ id: String, _ title: String, _ symbol: String? = nil, foreground: Bool = false, destructive: Bool = false) -> UNNotificationAction {
            var o: UNNotificationActionOptions = []
            if foreground { o.insert(.foreground) }
            if destructive { o.insert(.destructive) }
            return UNNotificationAction(identifier: id, title: title, options: o, icon: symbol.map { UNNotificationActionIcon(systemImageName: $0) })
        }
        func text(_ id: String, _ title: String, _ placeholder: String) -> UNTextInputNotificationAction {
            UNTextInputNotificationAction(identifier: id, title: title, options: [], textInputButtonTitle: "Send", textInputPlaceholder: placeholder)
        }
        func cat(_ c: NotificationCategory, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: c.rawValue, actions: actions, intentIdentifiers: [], options: [])
        }
        let start = cat(.start, [a("focus.start", "Start", "play.fill"), a("focus.snooze", "10 Min Later", "clock.arrow.circlepath"),
                                  a("task.notToday", "Not Today", "arrow.uturn.forward", destructive: true)])
        let lead = cat(.lead, [a("focus.start", "Start Now", "play.fill")])
        let checkIn = cat(.checkIn, [text("reply", "Reply", "e.g. good day, bio quiz thursday"), a("mood5", "😊 Good"), a("mood3", "😐 Okay"),
                                     a("mood1", "😔 Rough")])
        let scroll = cat(.scroll, [a("scroll.yes", "Yes"), a("scroll.stop", "No, I Stopped"), a("scroll.gap", "Something Better", foreground: true)])
        let deadline = cat(.deadline, [a("item.focus", "Start It Now", "play.fill"), a("item.done", "It's Done", "checkmark")])
        let untracked = cat(.untracked, buttons.enumerated().map { a("track.\($0.offset)", $0.element) }
                            + [text("track.reply", "Something Else", "e.g. gym with Sam, homework")])
        let sleep = cat(.sleepConfirm, [a("sleep.yes", "Yes"), text("sleep.reply", "Change", "e.g. 11:40 to 7:10")])
        let question = cat(.question, [a("q.yes", "Yes"), text("q.reply", "Something Else", "What happened?")])
        let planQ = UNNotificationCategory(identifier: planQuestionCategory, actions: [
            a("q.sick", "Sick"), a("q.noSchool", "No School Today"), a("q.skipped", "Skipped"),
            text("q.reply", "Something Else", "What happened?"),
        ], intentIdentifiers: [], options: [])
        let running = cat(.running, [a("run.stop", "Done", "stop.fill"), text("run.switch", "Switch", "What are you doing now?")])
        let end = cat(.sessionEnd, [a("end.15", "+15 Min", "plus"), a("end.30", "+30 Min", "plus"),
                                    a("end.tomorrow", "Finish Tomorrow", "arrow.uturn.forward"), a("item.done", "It's Done", "checkmark")])
        UNUserNotificationCenter.current().setNotificationCategories([start, lead, checkIn, scroll, deadline, untracked, sleep,
                                                                      question, planQ, running, end])
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces everything Productium scheduled (plan nudges, tracking prompts, the running notification).
    static func schedule(_ nudges: [PlannedNudge]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix("plan.") || $0.hasPrefix("track.") || $0.hasPrefix("running.") }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            for n in nudges { add(center, n.id, content(n), at: n.at, sound: n.kind != .running) }
        }
    }

    static func content(_ n: PlannedNudge) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.body = n.body
        var info: [String: Any] = ["kind": n.kind.rawValue, "question": n.title]
        if let b = n.blockId { info["blockId"] = b.uuidString }
        if let i = n.itemId { info["itemId"] = i.uuidString }
        if let d = n.deeplink { info["deeplink"] = d }
        if let w = n.window { info["start"] = w.start.timeIntervalSince1970; info["end"] = w.end.timeIntervalSince1970 }
        if !n.actions.isEmpty { info["actions"] = n.actions }
        c.userInfo = info
        if let cat = n.kind.category { c.categoryIdentifier = cat.rawValue }
        if n.kind == .question, n.id.hasPrefix("q.plan") { c.categoryIdentifier = planQuestionCategory }
        if let b = n.blockId { c.threadIdentifier = b.uuidString }
        if n.kind == .running { c.threadIdentifier = "running" }
        c.interruptionLevel = n.kind == .running ? .passive : .active
        c.relevanceScore = n.urgent ? 0.9 : 0.4
        return c
    }

    /// A quiet answer to a reply typed into a notification (A9): what was logged, or that it's saved for later.
    static func receipt(_ title: String, body: String?) {
        let c = UNMutableNotificationContent()
        c.title = title
        if let body { c.body = body }
        c.interruptionLevel = .passive
        c.threadIdentifier = "receipts"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "receipt.\(UUID().uuidString)", content: c, trigger: nil))
    }

    /// Drops delivered tracking prompts and running notices (after an answer, a start or a stop).
    static func clearDelivered(prefixes: [String]) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { id in prefixes.contains { id.hasPrefix($0) } }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    static func snooze(blockId: UUID, title: String, minutes: Int = 10) {
        let center = UNUserNotificationCenter.current()
        cancel(blockId: blockId)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = "Snoozed. Start now, or tap Can't Today and it moves to a better slot."
        c.categoryIdentifier = NotificationCategory.start.rawValue
        c.userInfo = ["blockId": blockId.uuidString, "deeplink": "productium://now", "kind": "snooze"]
        c.threadIdentifier = blockId.uuidString
        c.interruptionLevel = .active
        add(center, "snooze.\(blockId)", c, at: Date().addingTimeInterval(Double(minutes) * 60))
    }

    static func cancel(blockId: UUID) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter {
                $0 == "plan.lead.\(blockId)" || $0 == "plan.start.\(blockId)" || $0.hasPrefix("plan.follow.\(blockId)")
                    || $0 == "snooze.\(blockId)"
            }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { ($0.request.content.userInfo["blockId"] as? String) == blockId.uuidString }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    static func scheduleScrollCheckIn(after minutes: Int, total: Int, last: Bool) {
        let center = UNUserNotificationCenter.current()
        cancelScrollCheckIns()
        let c = UNMutableNotificationContent()
        c.title = last ? "\(total) minutes. Time to stop?" : "\(total) minutes in. Still scrolling?"
        c.body = last ? "Close the app now and the evening is still yours."
                      : "Tap Yes or No, I Stopped, so Productium counts it right. Something short beats it."
        c.categoryIdentifier = scrollCategory
        c.threadIdentifier = "scroll"
        c.userInfo = ["deeplink": "productium://gap", "kind": "scroll"]
        c.interruptionLevel = .active
        add(center, "scroll.0", c, at: Date().addingTimeInterval(Double(minutes) * 60))
    }

    static func cancelScrollCheckIns() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: (0..<4).map { "scroll.\($0)" })
    }

    static func scheduleHousekeeping() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["house.screenshot", "house.expiry"])
        do {
            let c = UNMutableNotificationContent()
            c.title = "Screen Time screenshot"
            c.body = "Settings → Screen Time → See All Activity → Week. Screenshot it and drop it in the box."
            c.userInfo = ["deeplink": "productium://today"]
            center.add(UNNotificationRequest(identifier: "house.screenshot", content: c,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 19, weekday: 1), repeats: true)))
        }
    }

    private static func add(_ center: UNUserNotificationCenter, _ id: String, _ content: UNMutableNotificationContent, at date: Date,
                            sound: Bool = true) {
        if sound { content.sound = .default }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    static func notify(_ title: String, _ body: String, deeplink: String? = nil, blockId: UUID? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        var info: [String: String] = [:]
        if let deeplink { info["deeplink"] = deeplink }
        if let blockId { info["blockId"] = blockId.uuidString; c.categoryIdentifier = NotificationCategory.start.rawValue }
        c.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
