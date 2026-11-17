import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

final class ActivityMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        if activity == .daily {
            ScreenShield.clear(.limit)
        } else if activity == .windDown {
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
