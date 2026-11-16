import ManagedSettings
import UserNotifications
import Foundation

final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(action, completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(action, completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        respond(action, completionHandler)
    }

    private func respond(_ action: ShieldAction, _ done: @escaping (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed:
            if SharedConfig.defaults.bool(forKey: SharedConfig.Key.nudgeOnShield) {
                // Extensions can't open the app, but a notification can.
                SharedConfig.defaults.set("productium://gap", forKey: SharedConfig.Key.pendingDeepLink)
                let c = UNMutableNotificationContent()
                c.title = "2 minutes, better spent"
                c.body = "A short read or a few flashcards. Tap to open."
                c.userInfo = ["deeplink": "productium://gap"]
                c.interruptionLevel = .active
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "shield.nudge", content: c, trigger: nil))
            }
            done(.close)
        case .secondaryButtonPressed:
            let reason = SharedConfig.defaults.string(forKey: SharedConfig.Key.shieldReason)
            if reason == "limit", ScreenShield.grantUnlock(minutes: 15) {
                done(.defer)
            } else {
                done(.close)
            }
        @unknown default:
            done(.close)
        }
    }
}
