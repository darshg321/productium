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

    /// Lock-screen replies land here: Done / Partly / Skipped, mood taps, typed check-ins.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await MainActor.run {
            let model = AppModel.shared
            if let idStr = info["blockId"] as? String, let id = UUID(uuidString: idStr),
               let status = OutcomeStatus(rawValue: action) {
                model.logOutcome(blockId: id, status: status)
            } else if action.hasPrefix("mood"), let m = Int(action.dropFirst(4)) {
                model.logMood(m, energy: nil, note: nil)
            } else if action == "marker.yes", let phrase = info["marker"] as? String {
                model.logMarker(phrase, source: .notification)
            } else if let link = info["deeplink"] as? String, action == UNNotificationDefaultActionIdentifier {
                model.deepLink = link
            }
        }
        if let text = (response as? UNTextInputNotificationResponse)?.userText, !text.isEmpty {
            await AppModel.shared.dump(text)
        }
    }
}
