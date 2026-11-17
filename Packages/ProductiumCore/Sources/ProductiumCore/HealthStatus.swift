import Foundation

/// What Health can actually tell the app. HealthKit never says whether *read* access was granted, so
/// "no sleep data" is not the same as "Health is off".
public enum HealthStatus: String, Codable, Sendable {
    case notAsked
    case noSleepSource
    case withSleep

    /// - requestNeeded: HealthKit's `getRequestStatusForAuthorization` said it still has to be asked.
    public static func resolve(wantsHealth: Bool, requestNeeded: Bool, days: [HealthDay]) -> HealthStatus {
        guard wantsHealth, !requestNeeded else { return .notAsked }
        let measured = days.contains { $0.sleepMinutes != nil && ($0.sleepSource == nil || $0.sleepSource == .health) }
        return measured ? .withSleep : .noSleepSource
    }

    /// The line the Review sleep card shows when it has no sleep figure.
    public var emptyMessage: String? {
        switch self {
        case .notAsked:
            return "Health isn't connected. Turn it on in Settings → Connections, or tell the Inbox when you woke up."
        case .noSleepSource:
            return "Health is connected, but nothing on your phone records sleep. Productium estimates sleep from your check-ins and phone use. For measured sleep, turn on Sleep Schedule in the Health app or wear a Watch."
        case .withSleep:
            return nil
        }
    }

    public var title: String {
        switch self {
        case .notAsked: return "Not connected"
        case .noSleepSource: return "Connected, no sleep source"
        case .withSleep: return "Connected, with sleep"
        }
    }
}
