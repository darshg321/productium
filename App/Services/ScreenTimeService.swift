import Foundation
import FamilyControls
import DeviceActivity
import ManagedSettings
import ProductiumCore

/// Screen Time API (FamilyControls `.individual` authorization). The student picks
/// their distracting apps, categories and sites once. Productium then:
///   • shields them during focus blocks and wind-down,
///   • measures daily use through threshold events (15-min resolution),
///   • enforces a daily limit that tapers week by week (`ScreenTaper`).
@MainActor
final class ScreenTimeService {
    static let shared = ScreenTimeService()
    private let center = DeviceActivityCenter()

    var authorized: Bool { AuthorizationCenter.shared.authorizationStatus == .approved }

    func requestAuthorization() async -> Bool {
        #if FREE_TIER
        return false   // Family Controls isn't available to free (Personal Team) signing
        #endif
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            return false
        }
        return authorized
    }

    var selection: FamilyActivitySelection {
        get { ScreenShield.loadSelection() ?? FamilyActivitySelection() }
        set { ScreenShield.saveSelection(newValue); configured = nil }
    }

    var hasSelection: Bool {
        let s = selection
        return !(s.applicationTokens.isEmpty && s.categoryTokens.isEmpty && s.webDomainTokens.isEmpty)
    }

    /// The (limit, selection) the daily monitor was last started with. Compared by
    /// value, since encoded Sets have no stable order across launches.
    private var configured: (limit: Int, selection: FamilyActivitySelection)? {
        get {
            guard let d = SharedConfig.defaults.data(forKey: "screen.configSelection"),
                  let sel = try? JSONDecoder().decode(FamilyActivitySelection.self, from: d) else { return nil }
            return (SharedConfig.defaults.integer(forKey: "screen.configLimit"), sel)
        }
        set {
            if let newValue, let d = try? JSONEncoder().encode(newValue.selection) {
                SharedConfig.defaults.set(d, forKey: "screen.configSelection")
                SharedConfig.defaults.set(newValue.limit, forKey: "screen.configLimit")
            } else {
                SharedConfig.defaults.removeObject(forKey: "screen.configSelection")
            }
        }
    }

    /// Daily usage monitor + limit. Only restarted when something changed, since
    /// restarting mid-day can reset threshold counting.
    func configureDaily(limitMinutes: Int?, unlocksPerDay: Int) {
        guard authorized, hasSelection else { return }
        SharedConfig.defaults.set(limitMinutes ?? 0, forKey: SharedConfig.Key.dailyLimit)
        SharedConfig.defaults.set(unlocksPerDay, forKey: SharedConfig.Key.unlocksPerDay)
        let sel = selection
        let limit = limitMinutes ?? 0
        if let c = configured, c.limit == limit, c.selection == sel { return }
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for m in ScreenShield.usageSteps {
            events[.usage(m)] = DeviceActivityEvent(applications: sel.applicationTokens, categories: sel.categoryTokens,
                                                    webDomains: sel.webDomainTokens, threshold: DateComponents(minute: m))
        }
        if let l = limitMinutes, l > 0 {
            events[.limit] = DeviceActivityEvent(applications: sel.applicationTokens, categories: sel.categoryTokens,
                                                 webDomains: sel.webDomainTokens, threshold: DateComponents(minute: l))
        }
        let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                              intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
        center.stopMonitoring([.daily])
        do {
            try center.startMonitoring(.daily, during: schedule, events: events)
            configured = (limit, sel)
        } catch {
            print("daily monitor failed: \(error)")
        }
    }

    /// Wind-down (bedtime − wind-down → wake) and today's focus blocks.
    func configureSchedules(plan: Plan, prefs: Preferences, shieldFocus: Bool, shieldWindDown: Bool) {
        guard authorized, hasSelection else { return }
        let cal = Calendar.current
        let now = Date()
        // Focus blocks: the next ≤ 8 study blocks in the next 24 h (DeviceActivity allows ~20 activities).
        let old = center.activities.filter { $0.isFocus }
        center.stopMonitoring(old)
        if shieldFocus {
            let blocks = plan.blocks.filter { $0.isStudy && $0.end > now && $0.start < now.addingTimeInterval(86400) && $0.minutes >= 15 }.prefix(8)
            for (i, b) in blocks.enumerated() {
                let start = max(b.start, now.addingTimeInterval(60))
                guard b.end.timeIntervalSince(start) >= 15 * 60 else { continue }
                let comps: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
                let s = DeviceActivitySchedule(intervalStart: cal.dateComponents(comps, from: start),
                                               intervalEnd: cal.dateComponents(comps, from: b.end), repeats: false)
                try? center.startMonitoring(.focus(i), during: s)
            }
        }
        center.stopMonitoring([.windDown])
        if shieldWindDown, let wind = plan.blocks.first(where: { $0.kind == .windDown && $0.end > now }) {
            let s = DeviceActivitySchedule(intervalStart: cal.dateComponents([.hour, .minute], from: wind.start),
                                           intervalEnd: cal.dateComponents([.hour, .minute], from: plan.wakePlans.first?.wake ?? wind.end.addingTimeInterval(9 * 3600)),
                                           repeats: true)
            try? center.startMonitoring(.windDown, during: s)
        }
    }

    /// Shield right now (focus session started manually) or lift it.
    func focusNow(_ on: Bool, title: String? = nil, ends: Date? = nil) {
        guard authorized, hasSelection else { return }
        if on {
            SharedConfig.defaults.set(title, forKey: SharedConfig.Key.focusTitle)
            SharedConfig.defaults.set(ends?.timeIntervalSince1970 ?? 0, forKey: SharedConfig.Key.focusEnds)
            ScreenShield.apply(.focus, reason: "focus")
        } else {
            ScreenShield.clear(.focus)
        }
    }

    func usageDays(back n: Int) -> [ScreenDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<n).compactMap { i in
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { return nil }
            return ScreenDay(day: d, distractingMinutes: ScreenShield.usage(on: d), unlockRequests: ScreenShield.unlocksUsed(on: d))
        }
    }

    func disable() {
        center.stopMonitoring()
        ScreenShield.clearAll()
        configured = nil
    }
}
