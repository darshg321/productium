import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

/// Runs in the background, woken by the system at schedule boundaries and usage thresholds.
/// It can't talk to the app directly, so state goes through the App Group.
final class ActivityMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if activity == .daily {
            // New day: the limit shield comes off.
            ScreenShield.clear(.limit)
        } else if activity == .windDown {
            // Screens before bed delay sleep (Hale & Guan 2015; Carter et al. 2016).
            ScreenShield.apply(.windDown, reason: "winddown")
        } else if activity.isFocus {
            ScreenShield.apply(.focus, reason: "focus")
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        if activity == .windDown {
            ScreenShield.clear(.windDown)
        } else if activity.isFocus {
            ScreenShield.clear(.focus)
        } else if activity == .unlock {
            // "15 more minutes" is over. Re-lock if today's limit was reached.
            let limit = SharedConfig.defaults.integer(forKey: SharedConfig.Key.dailyLimit)
            if limit > 0 && ScreenShield.usage(on: Date()) >= limit {
                ScreenShield.apply(.limit, reason: "limit")
            }
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        if let m = event.usageMinutes {
            ScreenShield.recordUsage(m)
        } else if event == .limit {
            let limit = SharedConfig.defaults.integer(forKey: SharedConfig.Key.dailyLimit)
            if limit > 0 { ScreenShield.recordUsage(limit) }
            ScreenShield.apply(.limit, reason: "limit")
        }
    }
}
