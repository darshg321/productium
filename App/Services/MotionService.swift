import Foundation
import CoreMotion
import ProductiumCore

/// Walking, cycling, driving and still periods from Core Motion. iOS keeps 7 days of activity
/// history, so this works even when the app wasn't running. No entitlement needed (free builds
/// too). Only spans are kept, never locations.
final class MotionService {
    static let shared = MotionService()
    private let manager = CMMotionActivityManager()
    private let queue = OperationQueue()

    var available: Bool { CMMotionActivityManager.isActivityAvailable() }
    var status: String {
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "notDetermined"
        }
    }

    /// Asks for access (the first query shows the prompt). True when allowed.
    func requestAccess() async -> Bool {
        guard available else { return false }
        _ = await samples(from: Date().addingTimeInterval(-600), to: Date())
        return CMMotionActivityManager.authorizationStatus() == .authorized
    }

    func samples(from: Date, to: Date) async -> [MotionSample] {
        guard available else { return [] }
        return await withCheckedContinuation { c in
            manager.queryActivityStarting(from: from, to: to, to: queue) { acts, _ in
                c.resume(returning: (acts ?? []).map(Self.sample))
            }
        }
    }

    static func sample(_ a: CMMotionActivity) -> MotionSample {
        let kind: MotionKind = a.automotive ? .automotive : a.cycling ? .cycling : a.running ? .running
            : a.walking ? .walking : a.stationary ? .stationary : .unknown
        let conf: Int
        switch a.confidence {
        case .high: conf = 2
        case .medium: conf = 1
        default: conf = 0
        }
        return MotionSample(at: a.startDate, kind: kind, confidence: conf)
    }
}
