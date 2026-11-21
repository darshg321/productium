import Foundation
import CoreMotion
import ProductiumCore

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

    /// Steps over one stretch (a walk), for its cadence (N5).
    func steps(from: Date, to: Date) async -> Int? {
        guard CMPedometer.isStepCountingAvailable(), to > from else { return nil }
        return await withCheckedContinuation { c in
            CMPedometer().queryPedometerData(from: from, to: to) { data, _ in c.resume(returning: data?.numberOfSteps.intValue) }
        }
    }

    /// Steps per day from the phone itself (no Health permission), up to 7 days back.
    func stepsByDay(back n: Int, calendar cal: Calendar) async -> [Date: Int] {
        guard CMPedometer.isStepCountingAvailable() else { return [:] }
        let pedometer = CMPedometer()
        let today = cal.startOfDay(for: Date())
        var out: [Date: Int] = [:]
        for i in 0..<max(1, min(n, 7)) {
            guard let day = cal.date(byAdding: .day, value: -i, to: today), let next = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let steps: Int? = await withCheckedContinuation { c in
                pedometer.queryPedometerData(from: day, to: min(next, Date())) { data, _ in c.resume(returning: data?.numberOfSteps.intValue) }
            }
            if let steps { out[day] = steps }
        }
        return out
    }
}
