import Foundation
import UIKit
import UserNotifications
import ProductiumCore

// v1.6: setup problems on Today (E3, F1) and asking iOS again after a reinstall or restore.

extension AppModel {
    /// What's on but not working, not dismissed today.
    var setupProblems: [SetupProblem] {
        var x = SetupProblems.Input(now: Date())
        x.locationWanted = state.integrations.location
        switch LocationService.shared.status {
        case .authorizedAlways: x.location = "always"
        case .authorizedWhenInUse: x.location = "whenInUse"
        case .denied, .restricted: x.location = "denied"
        default: x.location = "notDetermined"
        }
        x.notificationsWanted = state.integrations.notifications
        x.notificationsDenied = notificationsDenied
        x.appLiteralSeen = appLiteralSeen
        return SetupProblems.showing(SetupProblems.find(x), dismissed: state.dismissed, today: DayKeys.key(Date(), cal))
    }

    func dismissSetup(_ p: SetupProblem) {
        state.dismissed.insert(p.dismissKey(on: DayKeys.key(Date(), cal)))
        save()
    }

    func fix(_ p: SetupProblem) {
        switch p.fix {
        case .settings: if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        case .health: if let u = URL(string: "x-apple-health://") { UIApplication.shared.open(u) }
        case .shortcutsGuide: showShortcutsGuide = true
        }
    }

    func checkNotificationsDenied() async {
        notificationsDenied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// F1: each integration that's on is checked against what iOS allows; anything this install never asked is asked.
    func checkPermissions() async {
        let n = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = n.authorizationStatus == .denied
        if state.integrations.notifications && n.authorizationStatus == .notDetermined {
            state.integrations.notifications = await NotificationService.requestAuthorization()
        }
        if state.integrations.location { LocationService.shared.requestAlways() }
        if state.integrations.health, await HealthService.shared.requestNeeded() {
            try? await HealthService.shared.requestAuthorization()
        }
        log(.lifecycle, "permissions", ["location": LocationService.shared.statusText, "notifications": "\(n.authorizationStatus.rawValue)"])
    }

    /// F4: with Location only While Using there are no visits, so a fix each time the app comes to the front (at most
    /// every 10 min) goes in the trace; a finished stay of 20 min or more becomes a visit, and places follow.
    func foregroundFix() {
        guard state.integrations.location, LocationService.shared.status == .authorizedWhenInUse,
              Date().timeIntervalSince(state.trace.points.last?.at ?? .distantPast) > 10 * 60 else { return }
        Task {
            guard let loc = await LocationService.shared.currentLocation() else { return }
            state.trace.add(TracePoint(at: Date(), latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                                       accuracy: loc.horizontalAccuracy))
            let last = state.trace.points.last?.at
            for v in state.trace.stays(since: Date().addingTimeInterval(-12 * 3600)) where v.departure != last
                && !state.trace.visits.contains(where: { abs($0.arrival.timeIntervalSince(v.arrival)) < 60 }) {
                noteVisit(v)
            }
            save()
        }
    }

    // MARK: C1: Pause

    /// Ends what's running now and keeps it paused until Resume or Stop.
    func pauseRunning(source: String) {
        guard let r = running else { return }
        let end = resumedEnds ?? Sessions.block(for: r, in: state.plan, now: Date()).map(\.end)
        var es = state.entries
        state.paused = PausedSession.pause(entries: &es, plannedEnd: end, now: Date(), calendar: cal)
        state.entries = es
        resumedEnds = nil
        log(.intent, "pause", ["source": source, "title": r.title])
        Haptics.stop()
        afterLogChange()
        replan()
    }

    /// Starts the paused thing again; its countdown carries on from the time that was left.
    func resumePaused(source: String) {
        guard let p = state.paused else { return }
        let r = p.resume(now: Date())
        state.paused = nil
        log(.intent, "resume", ["source": source, "title": p.title])
        applyUI([r.op], what: "resume (\(source))", quiet: true)
        resumedEnds = r.ends
        Haptics.start()
        syncNowActivity()
    }

    /// Stop while paused: nothing after the pause is logged.
    func clearPause() {
        guard state.paused != nil else { return }
        state.paused = nil
        resumedEnds = nil
        replan()
    }

    /// E2: "None of These" on Did These Happen?: every one of them didn't happen, in one change.
    func rejectAll(_ ds: [DayEntry]) {
        applyUI(ds.map { BoxOp(.entry, .skip, ref: $0.ref) }, what: "reject all (\(ds.count))", quiet: true)
        Haptics.tap()
    }

    // MARK: G10: the outbox

    func resendOutbox(_ id: UUID) {
        guard let item = state.outbox.items.first(where: { $0.id == id }) else { return }
        state.outbox.sent(id)
        Task { _ = await submit(item.text, source: item.source, context: item.context) }
    }

    func discardOutbox(_ id: UUID) {
        state.outbox.sent(id)
        log(.box, "outbox_discarded")
        save()
    }
}
