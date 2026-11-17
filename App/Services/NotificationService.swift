import Foundation
import UserNotifications
import ProductiumCore

/// Notifications carry most of the input: one tap on Done / Partly / Skipped
/// from the lock screen, or a typed or dictated reply to the evening check-in.
/// The app often never needs opening.
///
/// What gets sent, and when, is decided by `NudgePlanner` (ProductiumCore); this file only turns
/// those into requests. Ids starting "plan." are rebuilt on every replan. "snooze." and
/// "scroll." ones are set by a tap or by a Shortcuts automation and left alone by replans.
enum NotificationService {
    static let blockCategory = "BLOCK_END"
    static let startCategory = "BLOCK_START"
    static let leadCategory = "LEAD_UP"
    static let checkInCategory = "CHECK_IN"
    static let markerCategory = "MARKER"
    static let scrollCategory = "SCROLL"
    static let deadlineCategory = "DEADLINE"

    static func register() {
        let done = UNNotificationAction(identifier: "done", title: "Done ✓", options: [])
        let partial = UNNotificationAction(identifier: "partial", title: "Partly", options: [])
        let skipped = UNNotificationAction(identifier: "skipped", title: "Didn't get to it", options: [])
        let block = UNNotificationCategory(identifier: blockCategory, actions: [done, partial, skipped], intentIdentifiers: [], options: [])

        let startNow = UNNotificationAction(identifier: "focus.start", title: "Start Focus", options: [.foreground],
                                            icon: UNNotificationActionIcon(systemImageName: "play.fill"))
        let snooze = UNNotificationAction(identifier: "focus.snooze", title: "In 10 Minutes", options: [],
                                          icon: UNNotificationActionIcon(systemImageName: "clock.arrow.circlepath"))
        let cant = UNNotificationAction(identifier: "focus.cant", title: "Can't Today", options: [.destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "arrow.uturn.forward"))
        let start = UNNotificationCategory(identifier: startCategory, actions: [startNow, snooze, cant], intentIdentifiers: [], options: [])
        let early = UNNotificationAction(identifier: "focus.start", title: "Start Now", options: [.foreground],
                                         icon: UNNotificationActionIcon(systemImageName: "play.fill"))
        let lead = UNNotificationCategory(identifier: leadCategory, actions: [early], intentIdentifiers: [], options: [])

        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "e.g. good day, bio quiz thursday")
        let great = UNNotificationAction(identifier: "mood5", title: "😊 Good", options: [])
        let ok = UNNotificationAction(identifier: "mood3", title: "😐 Okay", options: [])
        let low = UNNotificationAction(identifier: "mood1", title: "😔 Rough", options: [])
        let checkIn = UNNotificationCategory(identifier: checkInCategory, actions: [reply, great, ok, low], intentIdentifiers: [], options: [])
        let yes = UNNotificationAction(identifier: "marker.yes", title: "Yes", options: [])
        let marker = UNNotificationCategory(identifier: markerCategory, actions: [yes], intentIdentifiers: [], options: [])

        let still = UNNotificationAction(identifier: "scroll.yes", title: "Yes", options: [])
        let stop = UNNotificationAction(identifier: "scroll.stop", title: "No, I Stopped", options: [])
        let showMe = UNNotificationAction(identifier: "scroll.gap", title: "Something Better", options: [.foreground])
        let scroll = UNNotificationCategory(identifier: scrollCategory, actions: [still, stop, showMe], intentIdentifiers: [], options: [])

        let finished = UNNotificationAction(identifier: "item.done", title: "It's Done", options: [])
        let workNow = UNNotificationAction(identifier: "item.focus", title: "Work on It Now", options: [.foreground])
        let deadline = UNNotificationCategory(identifier: deadlineCategory, actions: [workNow, finished], intentIdentifiers: [], options: [])

        UNUserNotificationCenter.current().setNotificationCategories([block, start, lead, checkIn, marker, scroll, deadline])
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces every pending "plan." notification with `nudges`.
    static func schedule(_ nudges: [PlannedNudge]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix("plan.") }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            for n in nudges { add(center, n.id, content(n), at: n.at) }
        }
    }

    static func content(_ n: PlannedNudge) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = n.title
        c.body = n.body
        var info: [String: String] = [:]
        if let b = n.blockId { info["blockId"] = b.uuidString }
        if let i = n.itemId { info["itemId"] = i.uuidString }
        if let m = n.marker { info["marker"] = m }
        if let d = n.deeplink { info["deeplink"] = d }
        info["kind"] = n.kind.rawValue
        c.userInfo = info
        switch n.kind {
        case .start, .followUp: c.categoryIdentifier = startCategory
        case .leadUp: c.categoryIdentifier = leadCategory
        case .end: c.categoryIdentifier = blockCategory
        case .checkIn: c.categoryIdentifier = checkInCategory
        case .marker: c.categoryIdentifier = markerCategory
        case .deadline: c.categoryIdentifier = deadlineCategory
        default: break
        }
        // Follow-ups for the same block replace each other in Notification Center.
        if let b = n.blockId { c.threadIdentifier = b.uuidString }
        // Time Sensitive needs a paid-account entitlement; without it iOS treats this as .active.
        c.interruptionLevel = n.urgent ? .timeSensitive : .active
        c.relevanceScore = n.urgent ? 0.9 : 0.4
        return c
    }

    /// "In 10 minutes" from a start notification: one reminder, and the block's own follow-ups
    /// are dropped (the next replan leaves them out while it's snoozed).
    static func snooze(blockId: UUID, title: String, minutes: Int = 10) {
        let center = UNUserNotificationCenter.current()
        cancel(blockId: blockId)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = "Snoozed. Start now, or tap Can't Today and it moves to a better slot."
        c.categoryIdentifier = startCategory
        c.userInfo = ["blockId": blockId.uuidString, "deeplink": "productium://now", "kind": "snooze"]
        c.threadIdentifier = blockId.uuidString
        c.interruptionLevel = .timeSensitive
        add(center, "snooze.\(blockId)", c, at: Date().addingTimeInterval(Double(minutes) * 60))
    }

    /// Focus started (or the block was answered): no more heads-ups, starts or follow-ups for it.
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
            let ids = delivered.filter { ($0.request.content.userInfo["blockId"] as? String) == blockId.uuidString
                && ($0.request.content.userInfo["kind"] as? String) != NudgeKind.end.rawValue }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: Scrolling check-ins (free build, from the Shortcuts pause)

    /// After "Go back anyway": one "still scrolling?" check-in. The next is scheduled only when
    /// the student answers Yes, so an unanswered one (a locked phone) is the last.
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

    /// Free builds: a weekly nudge to drop a Screen Time screenshot, and a warning
    /// the day before the 7-day signature runs out.
    static func scheduleHousekeeping(freeTier: Bool, expiry: Date?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["house.screenshot", "house.expiry"])
        if freeTier {
            let c = UNMutableNotificationContent()
            c.title = "Screen Time screenshot"
            c.body = "Settings → Screen Time → See All Activity → Week. Screenshot it and drop it in the box."
            c.userInfo = ["deeplink": "productium://today"]
            center.add(UNNotificationRequest(identifier: "house.screenshot", content: c,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 19, weekday: 1), repeats: true)))
        }
        if let expiry, expiry.addingTimeInterval(-86400) > Date() {
            let c = UNMutableNotificationContent()
            c.title = "Productium expires tomorrow"
            c.body = "Open SideStore and tap Refresh All (LocalDevVPN on) so it keeps working."
            add(center, "house.expiry", c, at: expiry.addingTimeInterval(-86400))
        }
    }

    private static func add(_ center: UNUserNotificationCenter, _ id: String, _ content: UNMutableNotificationContent, at date: Date) {
        content.sound = .default
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
        if let blockId { info["blockId"] = blockId.uuidString; c.categoryIdentifier = startCategory }
        c.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
