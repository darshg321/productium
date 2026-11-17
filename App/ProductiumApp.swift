import SwiftUI
import UserNotifications
import ProductiumCore

@main
struct ProductiumApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.deepLink = $0.absoluteString }
        }
        .onChange(of: phase) { _, p in
            if p == .active { model.foreground() }
            if p == .background { BackgroundRefresh.schedule(); Persistence.save(model.state) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundRefresh.register { await AppModel.shared.refresh(full: false) }
        BackgroundRefresh.schedule()
        Task { @MainActor in AppModel.shared.launch() }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await MainActor.run {
            let model = AppModel.shared
            let blockId = (info["blockId"] as? String).flatMap(UUID.init(uuidString:))
            let itemId = (info["itemId"] as? String).flatMap(UUID.init(uuidString:))
            if let id = blockId, let status = OutcomeStatus(rawValue: action) {
                model.logOutcome(blockId: id, status: status)
            } else if action == "focus.start" {
                if let id = blockId { model.startFocus(blockId: id) } else { model.startNowOrNext() }
            } else if action == "focus.snooze", let id = blockId {
                model.snooze(blockId: id)
            } else if action == "focus.cant", let id = blockId {
                model.logOutcome(blockId: id, status: .skipped)
            } else if action == "scroll.gap" {
                Friction.answered(stillScrolling: false)
                model.deepLink = "productium://gap"
            } else if action == "scroll.yes" {
                Friction.answered(stillScrolling: true)
            } else if action == "scroll.stop" {
                Friction.answered(stillScrolling: false)
            } else if action == "item.done", let id = itemId {
                model.complete(id)
            } else if action == "item.focus", let id = itemId, let item = model.state.items.first(where: { $0.id == id }) {
                model.focusNow(on: item)
            } else if action.hasPrefix("mood"), let m = Int(action.dropFirst(4)) {
                model.logMood(m, energy: nil, note: nil)
            } else if action == "marker.yes", let phrase = info["marker"] as? String {
                model.logMarker(phrase, source: .notification)
            } else if let link = info["deeplink"] as? String, action == UNNotificationDefaultActionIdentifier {
                model.deepLink = link
            }
        }
        guard let text = (response as? UNTextInputNotificationResponse)?.userText, !text.isEmpty else { return }
        if action == "gap.reply", let s = info["start"] as? Double, let e = info["end"] as? Double {
            await AppModel.shared.answerGap(text, gap: MysteryGap(start: Date(timeIntervalSince1970: s),
                                                                  end: min(Date(), Date(timeIntervalSince1970: e)), ongoing: false))
        } else {
            await AppModel.shared.dump(text)
        }
    }
}
