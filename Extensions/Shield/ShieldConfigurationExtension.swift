import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration { make() }
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration { make() }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { make() }
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration { make() }

    private func make() -> ShieldConfiguration {
        let d = SharedConfig.defaults
        let reason = d.string(forKey: SharedConfig.Key.shieldReason) ?? "limit"
        let title: String
        var subtitle: String
        var secondary: String?
        switch reason {
        case "focus":
            title = "Focus block"
            let what = d.string(forKey: SharedConfig.Key.focusTitle) ?? "your work"
            let ends = Date(timeIntervalSince1970: d.double(forKey: SharedConfig.Key.focusEnds))
            let mins = max(0, Int(ends.timeIntervalSinceNow / 60))
            subtitle = "You're on \(what). It's back in \(mins) min."
        case "winddown":
            title = "Wind-down time"
            subtitle = "Screens off now means falling asleep sooner. See you in the morning."
        default:
            title = "That's today's limit"
            let left = max(0, ScreenShield.unlocksAllowed - ScreenShield.unlocksUsed())
            subtitle = "Pause for a second. Is this what you want to be doing?"
            if left > 0 { secondary = "15 more minutes (\(left) left)" }
        }
        if d.bool(forKey: SharedConfig.Key.nudgeOnShield) { subtitle += "\nTap below for a 2-minute read instead." }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            backgroundColor: UIColor.systemBackground.withAlphaComponent(0.6),
            icon: UIImage(systemName: reason == "winddown" ? "moon.stars" : "leaf"),
            title: ShieldConfiguration.Label(text: title, color: .label),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: d.bool(forKey: SharedConfig.Key.nudgeOnShield) ? "Something better" : "Close", color: .white),
            primaryButtonBackgroundColor: UIColor(red: 0.36, green: 0.42, blue: 0.85, alpha: 1),
            secondaryButtonLabel: secondary.map { ShieldConfiguration.Label(text: $0, color: .secondaryLabel) })
    }
}
