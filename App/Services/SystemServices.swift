import Foundation
import BackgroundTasks
import SwiftUI
import AppIntents
import ProductiumCore
#if canImport(AlarmKit) && ENABLE_ALARMKIT
import AlarmKit
#endif

enum AlarmService {
    static func requestAuthorization() async -> Bool {
        #if canImport(AlarmKit) && ENABLE_ALARMKIT
        if #available(iOS 26.1, *) {
            return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        }
        #endif
        return await NotificationService.requestAuthorization()
    }

    /// Hands the whole wanted list (`AlarmPlanner.desired`) to the one scheduler. Latest call wins.
    static func sync(_ desired: [PlannedAlarm]) {
        Task { await AlarmScheduler.shared.request(desired) }
    }
}

/// The only code that touches alarms (v1.1 C2). Requests are serialised and coalesced: while one sync runs, newer
/// requests replace each other and only the latest is applied next. Each sync compares the wanted list with the
/// alarms actually on the device (`AlarmReconciler`), so duplicates and orphans from any earlier run are cancelled.
actor AlarmScheduler {
    static let shared = AlarmScheduler()

    private var pending: [PlannedAlarm]?
    private var running = false
    private static let ledgerKey = "alarms.ledger"

    func request(_ desired: [PlannedAlarm]) async {
        pending = desired
        guard !running else { return }
        running = true
        while let next = pending {
            pending = nil
            await apply(next)
        }
        running = false
    }

    /// What Productium believes is scheduled (for the debug list and the export).
    func current() -> [AlarmLedgerEntry] { ledger.values.sorted { $0.at < $1.at } }

    private var ledger: [UUID: AlarmLedgerEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.ledgerKey),
                  let raw = try? JSONDecoder().decode([String: AlarmLedgerEntry].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: Self.ledgerKey)
        }
    }

    private func apply(_ desired: [PlannedAlarm]) async {
        let now = Date()
        #if canImport(AlarmKit) && ENABLE_ALARMKIT
        if #available(iOS 26.1, *) {
            await applyAlarmKit(desired, now: now)
            return
        }
        #endif
        await applyNotifications(desired, now: now)
    }

    #if canImport(AlarmKit) && ENABLE_ALARMKIT
    struct Metadata: AlarmMetadata {}

    @available(iOS 26.1, *)
    private func applyAlarmKit(_ desired: [PlannedAlarm], now: Date) async {
        let manager = AlarmManager.shared
        guard let onDevice = try? manager.alarms else { return }
        let device = onDevice.map { DeviceAlarm(id: $0.id, alerting: $0.state == .alerting) }
        let diff = AlarmReconciler.diff(desired: desired, device: device, ledger: ledger, now: now)
        guard !diff.isEmpty || diff.ledger != ledger else { return }
        let (adding, cancelling, onDeviceCount) = (diff.add.count, diff.cancel.count, device.count)
        await MainActor.run {
            AppModel.shared.log(.alarm, "reconcile", ["desired": "\(desired.count)", "device": "\(onDeviceCount)",
                                                      "add": "\(adding)", "cancel": "\(cancelling)"])
        }
        var book = diff.ledger
        for id in diff.cancel { try? manager.cancel(id: id) }
        ledger = book
        for a in diff.add {
            let id = UUID()
            do {
                try await manager.schedule(id: id, configuration: configuration(a))
                book[id] = AlarmLedgerEntry(a)
                ledger = book
            } catch {
                let why = "\(error)", title = a.title
                await MainActor.run { AppModel.shared.log(.alarm, "schedule_failed", level: .error, ["title": title, "error": why]) }
            }
        }
    }

    @available(iOS 26.1, *)
    private func configuration(_ a: PlannedAlarm) -> AlarmManager.AlarmConfiguration<Metadata> {
        let title = LocalizedStringResource(stringLiteral: a.title)
        let alert: AlarmPresentation.Alert
        if a.kind == .missedStart {
            let start = AlarmButton(text: "Start", textColor: .white, systemImageName: "play.fill")
            alert = AlarmPresentation.Alert(title: title, secondaryButton: start, secondaryButtonBehavior: .custom)
        } else {
            alert = AlarmPresentation.Alert(title: title, secondaryButton: nil, secondaryButtonBehavior: nil)
        }
        let tint: Color
        switch a.kind {
        case .wake, .bedtime: tint = .indigo
        case .leave: tint = .green
        case .missedStart, .entry: tint = .blue
        }
        let attrs = AlarmAttributes<Metadata>(presentation: AlarmPresentation(alert: alert), metadata: Metadata(), tintColor: tint)
        let secondary: (any LiveActivityIntent)? = a.kind == .missedStart ? StartFocusIntent() : nil
        // N4: the stop button records when it was pressed (and when it first rang): the wake signal and the snooze metric.
        let stop: (any LiveActivityIntent)? = a.kind == .entry || a.kind == .wake ? AlarmStoppedIntent(ringAt: a.at) : nil
        return .alarm(schedule: .fixed(a.at), attributes: attrs, stopIntent: stop, secondaryIntent: secondary, sound: .default)
    }
    #endif

    /// Before iOS 26.1 there is no AlarmKit: wake alarms become notifications (ids `alarm.<key>`). The other alarm
    /// kinds already have a notification from `NudgePlanner.plan`, so they are not duplicated here.
    private func applyNotifications(_ desired: [PlannedAlarm], now: Date) async {
        let center = UNUserNotificationCenter.current()
        let wakes = desired.filter { ($0.kind == .wake || $0.kind == .entry) && $0.at > now }
        let wanted = Set(wakes.map { "alarm.\($0.key)" })
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let stale = pending.filter { ($0.hasPrefix("alarm.") || $0.hasPrefix("wake.")) && !wanted.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for w in wakes {
            let c = UNMutableNotificationContent()
            c.title = "Good morning"
            c.body = w.title
            c.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: w.at)
            try? await center.add(UNNotificationRequest(identifier: "alarm.\(w.key)", content: c,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }
}

enum BackgroundRefresh {
    static let id = "app.productium.refresh"

    static func register(_ handler: @escaping () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            schedule()
            let work = Task {
                await MainActor.run { AppModel.shared.log(.lifecycle, "background_refresh") }
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
