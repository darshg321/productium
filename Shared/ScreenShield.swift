import Foundation
#if canImport(FamilyControls)
import FamilyControls
import ManagedSettings
import DeviceActivity

extension DeviceActivityName {
    static let daily = Self("productium.daily")
    static let windDown = Self("productium.winddown")
    static let unlock = Self("productium.unlock")
    static func focus(_ i: Int) -> Self { Self("productium.focus.\(i)") }
    var isFocus: Bool { rawValue.hasPrefix("productium.focus.") }
}

extension DeviceActivityEvent.Name {
    static let limit = Self("productium.limit")
    static func usage(_ minutes: Int) -> Self { Self("productium.usage.\(minutes)") }
    var usageMinutes: Int? {
        rawValue.hasPrefix("productium.usage.") ? Int(rawValue.split(separator: ".").last ?? "") : nil
    }
}

extension ManagedSettingsStore.Name {
    static let focus = Self("productium.focus")
    static let limit = Self("productium.limit")
    static let windDown = Self("productium.winddown")
}

/// Shield logic used by the app, the DeviceActivity monitor and the shield action.
enum ScreenShield {
    static let usageSteps = Array(stride(from: 15, through: 240, by: 15))

    static func loadSelection() -> FamilyActivitySelection? {
        guard let d = SharedConfig.defaults.data(forKey: SharedConfig.Key.selection) else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: d)
    }

    static func saveSelection(_ s: FamilyActivitySelection) {
        if let d = try? JSONEncoder().encode(s) { SharedConfig.defaults.set(d, forKey: SharedConfig.Key.selection) }
    }

    /// Shields the selected distracting apps, categories and websites in the given store.
    static func apply(_ store: ManagedSettingsStore.Name, reason: String) {
        guard let sel = loadSelection() else { return }
        let s = ManagedSettingsStore(named: store)
        s.shield.applications = sel.applicationTokens.isEmpty ? nil : sel.applicationTokens
        s.shield.applicationCategories = sel.categoryTokens.isEmpty ? nil : .specific(sel.categoryTokens)
        s.shield.webDomains = sel.webDomainTokens.isEmpty ? nil : sel.webDomainTokens
        s.shield.webDomainCategories = sel.categoryTokens.isEmpty ? nil : .specific(sel.categoryTokens)
        SharedConfig.defaults.set(reason, forKey: SharedConfig.Key.shieldReason)
    }

    static func clear(_ store: ManagedSettingsStore.Name) {
        ManagedSettingsStore(named: store).clearAllSettings()
    }

    static func clearAll() {
        [ManagedSettingsStore.Name.focus, .limit, .windDown].forEach(clear)
    }

    // Usage minutes (threshold events give "at least N minutes today").
    static func recordUsage(_ minutes: Int, on date: Date = Date()) {
        let key = SharedConfig.Key.usagePrefix + SharedConfig.dayKey(date)
        if minutes > SharedConfig.defaults.integer(forKey: key) { SharedConfig.defaults.set(minutes, forKey: key) }
    }

    static func usage(on date: Date) -> Int {
        SharedConfig.defaults.integer(forKey: SharedConfig.Key.usagePrefix + SharedConfig.dayKey(date))
    }

    static func unlocksUsed(on date: Date = Date()) -> Int {
        SharedConfig.defaults.integer(forKey: SharedConfig.Key.unlocksUsedPrefix + SharedConfig.dayKey(date))
    }

    static var unlocksAllowed: Int {
        let v = SharedConfig.defaults.object(forKey: SharedConfig.Key.unlocksPerDay) as? Int
        return v ?? 3
    }

    /// "15 more minutes": lift the limit shield and re-apply it when the window ends.
    /// Every unlock is a deliberate tap past a pause, the friction that cut app openings
    /// by more than half in Grüning et al. 2023.
    @discardableResult
    static func grantUnlock(minutes: Int = 15) -> Bool {
        let used = unlocksUsed()
        guard used < unlocksAllowed else { return false }
        SharedConfig.defaults.set(used + 1, forKey: SharedConfig.Key.unlocksUsedPrefix + SharedConfig.dayKey())
        clear(.limit)
        let cal = Calendar.current
        let now = Date()
        // DeviceActivity schedules must be ≥ 15 min; add one minute of margin.
        let end = now.addingTimeInterval(Double(max(15, minutes) + 1) * 60)
        let schedule = DeviceActivitySchedule(
            intervalStart: cal.dateComponents([.hour, .minute, .second], from: now),
            intervalEnd: cal.dateComponents([.hour, .minute, .second], from: end),
            repeats: false)
        let center = DeviceActivityCenter()
        center.stopMonitoring([.unlock])
        do { try center.startMonitoring(.unlock, during: schedule) } catch {
            // Couldn't schedule the re-lock, so don't leave it unlocked.
            apply(.limit, reason: "limit")
            return false
        }
        return true
    }
}
#endif
