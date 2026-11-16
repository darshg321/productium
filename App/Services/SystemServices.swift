import Foundation
import ActivityKit
import WidgetKit
import BackgroundTasks
import SwiftUI
import ProductiumCore
#if canImport(AlarmKit) && ENABLE_ALARMKIT
import AlarmKit
#endif

// MARK: - Wake-up alarms (AlarmKit, iOS 26+)

/// Sets real alarms (iOS 26.1+) for the planned wake time, worked back from the first class,
/// the learned commute and getting-ready time. On older iOS, a time-sensitive
/// notification is used instead.
enum AlarmService {
    static func requestAuthorization() async -> Bool {
        #if canImport(AlarmKit) && ENABLE_ALARMKIT
        if #available(iOS 26.1, *) {
            return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        }
        #endif
        return await NotificationService.requestAuthorization()
    }

    static func schedule(_ wakes: [WakePlan]) async {
        let upcoming = wakes.filter { $0.wake > Date() }.prefix(3)
        #if canImport(AlarmKit) && ENABLE_ALARMKIT
        if #available(iOS 26.1, *) {
            await scheduleAlarmKit(Array(upcoming))
            return
        }
        #endif
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: (0..<3).map { "wake.\($0)" })
        for (i, w) in upcoming.enumerated() {
            let c = UNMutableNotificationContent()
            c.title = "Good morning"
            c.body = w.leaveBy.map { "Leave by \($0.formatted(date: .omitted, time: .shortened))." } ?? w.reason
            c.sound = .default
            c.interruptionLevel = .timeSensitive
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: w.wake)
            try? await center.add(UNNotificationRequest(identifier: "wake.\(i)", content: c,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    #if canImport(AlarmKit) && ENABLE_ALARMKIT
    struct WakeMetadata: AlarmMetadata {}

    @available(iOS 26.1, *)
    private static func scheduleAlarmKit(_ wakes: [WakePlan]) async {
        let ids = (UserDefaults.standard.array(forKey: "alarm.ids") as? [String] ?? []).compactMap(UUID.init(uuidString:))
        for id in ids { try? AlarmManager.shared.cancel(id: id) }
        var newIds: [String] = []
        for w in wakes {
            let title = w.leaveBy.map { "Leave by \($0.formatted(date: .omitted, time: .shortened))" } ?? "Good morning"
            let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
                                                secondaryButton: nil, secondaryButtonBehavior: nil)
            let attrs = AlarmAttributes<WakeMetadata>(presentation: AlarmPresentation(alert: alert), metadata: WakeMetadata(),
                                                      tintColor: .indigo)
            let id = UUID()
            let config = AlarmManager.AlarmConfiguration<WakeMetadata>.alarm(schedule: .fixed(w.wake), attributes: attrs,
                                                                             stopIntent: nil, secondaryIntent: nil, sound: .default)
            if (try? await AlarmManager.shared.schedule(id: id, configuration: config)) != nil { newIds.append(id.uuidString) }
        }
        UserDefaults.standard.set(newIds, forKey: "alarm.ids")
    }
    #endif
}

// MARK: - Live Activity for the current block

enum LiveActivityService {
    static func update(current: PlannedBlock?, next: PlannedBlock?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let existing = Activity<BlockActivityAttributes>.activities
        guard let b = current, b.isStudy || b.kind == .breakTime else {
            Task { for a in existing { await a.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        let state = BlockActivityAttributes.ContentState(title: b.title, start: b.start, end: b.end, kind: b.kind.rawValue,
                                                         nextTitle: next?.title)
        let content = ActivityContent(state: state, staleDate: b.end)
        if let a = existing.first {
            Task { await a.update(content) }
        } else {
            _ = try? Activity.request(attributes: BlockActivityAttributes(startedFromApp: true), content: content)
        }
    }
}

// MARK: - Widgets

enum WidgetService {
    static func publish(plan: Plan, outcomes: [BlockOutcome]) {
        let cal = Calendar.current
        let now = Date()
        let items = plan.blocks.filter { $0.end > now && $0.start < now.addingTimeInterval(18 * 3600) && $0.kind != .sleep }
            .prefix(30).map { WidgetSnapshot.Item(title: $0.title, start: $0.start, end: $0.end, kind: $0.kind.rawValue, symbol: Theme.symbol(for: $0.kind)) }
        let today = plan.blocks(on: now, calendar: cal).filter(\.isStudy)
        let done = outcomes.filter { cal.isDate($0.plannedStart, inSameDayAs: now) && $0.status != .skipped }.reduce(0) { $0 + $1.actualMinutes }
        WidgetSnapshot(generatedAt: now, items: Array(items), studyMinutesToday: today.reduce(0) { $0 + $1.minutes },
                       doneMinutesToday: done).save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Background refresh

enum BackgroundRefresh {
    static let id = "app.productium.refresh"

    static func register(_ handler: @escaping () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            schedule()
            let work = Task {
                await handler()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date().addingTimeInterval(45 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
