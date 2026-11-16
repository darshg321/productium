import Foundation
import UserNotifications
import ProductiumCore

/// Notifications carry most of the input: one tap on Done / Partly / Skipped
/// from the lock screen, or a typed or dictated reply to the evening check-in.
/// The app often never needs opening.
enum NotificationService {
    static let blockCategory = "BLOCK_END"
    static let checkInCategory = "CHECK_IN"
    static let markerCategory = "MARKER"

    static func register() {
        let done = UNNotificationAction(identifier: "done", title: "Done ✓", options: [])
        let partial = UNNotificationAction(identifier: "partial", title: "Partly", options: [])
        let skipped = UNNotificationAction(identifier: "skipped", title: "Didn't get to it", options: [])
        let block = UNNotificationCategory(identifier: blockCategory, actions: [done, partial, skipped], intentIdentifiers: [], options: [])
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "e.g. good day, bio quiz thursday")
        let great = UNNotificationAction(identifier: "mood5", title: "😊 Good", options: [])
        let ok = UNNotificationAction(identifier: "mood3", title: "😐 Okay", options: [])
        let low = UNNotificationAction(identifier: "mood1", title: "😔 Rough", options: [])
        let checkIn = UNNotificationCategory(identifier: checkInCategory, actions: [reply, great, ok, low], intentIdentifiers: [], options: [])
        let yes = UNNotificationAction(identifier: "marker.yes", title: "Yes", options: [])
        let marker = UNNotificationCategory(identifier: markerCategory, actions: [yes], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([block, checkIn, marker])
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Rebuilds the next 24 h of plan notifications (iOS keeps at most 64 pending).
    static func schedule(plan: Plan, prefs: Preferences, items: [WorkItem], suggestions: [(Date, String)]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ours = pending.map(\.identifier).filter { $0.hasPrefix("plan.") }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            let now = Date()
            let horizon = now.addingTimeInterval(86400)
            var count = 0
            for b in plan.blocks where b.isStudy && b.end > now && b.start < horizon && count < 40 {
                if b.start > now.addingTimeInterval(60) {
                    let c = UNMutableNotificationContent()
                    c.title = b.title
                    c.body = b.hint ?? "Starting now."
                    c.interruptionLevel = .timeSensitive
                    c.userInfo = ["blockId": b.id.uuidString, "deeplink": "productium://now"]
                    add(center, "plan.start.\(b.id)", c, at: b.start)
                    count += 1
                }
                let e = UNMutableNotificationContent()
                e.title = "How did it go?"
                e.body = b.title
                e.categoryIdentifier = blockCategory
                e.userInfo = ["blockId": b.id.uuidString]
                e.interruptionLevel = .active
                add(center, "plan.end.\(b.id)", e, at: b.end)
                count += 1
            }
            // Evening check-in, about 30 min before wind-down: mood + anything new, ~20 s.
            if let wind = plan.blocks.first(where: { $0.kind == .windDown && $0.start > now.addingTimeInterval(30 * 60) }) {
                let c = UNMutableNotificationContent()
                c.title = "20-second check-in"
                c.body = "How was today? Anything new due? Reply here, no need to open the app."
                c.categoryIdentifier = checkInCategory
                add(center, "plan.checkin", c, at: wind.start.addingTimeInterval(-30 * 60))
            }
            // Morning brief, just after the planned wake-up.
            if let w = plan.wakePlans.first(where: { $0.wake > now }) {
                let cal = Calendar.current
                let day = plan.blocks(on: w.wake, calendar: cal).filter(\.isStudy)
                let mins = day.reduce(0) { $0 + $1.minutes }
                let c = UNMutableNotificationContent()
                c.title = day.isEmpty ? "Nothing planned today" : "Today: \(minutesLabel(mins)) of focused work"
                var body = day.first.map { "First up \($0.start.formatted(date: .omitted, time: .shortened)): \($0.title)." } ?? "Enjoy it."
                if let leave = w.leaveBy { body += " Leave by \(leave.formatted(date: .omitted, time: .shortened))." }
                c.body = body
                c.userInfo = ["deeplink": "productium://today"]
                add(center, "plan.morning", c, at: w.wake.addingTimeInterval(10 * 60))
            }
            // One-tap check-in prompts while routines are still being learned.
            for (i, s) in suggestions.prefix(4).enumerated() where s.0 > now {
                let c = UNMutableNotificationContent()
                c.title = s.1 + "?"
                c.body = "Tap Yes when it happens. A few of these and Productium learns your routine."
                c.categoryIdentifier = markerCategory
                c.userInfo = ["marker": s.1]
                add(center, "plan.marker.\(i)", c, at: s.0)
            }
        }
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

    static func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
