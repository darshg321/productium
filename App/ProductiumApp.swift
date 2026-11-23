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
                .onOpenURL { model.deepLink = AppInfo.normalised($0) }
        }
        .onChange(of: phase) { _, p in
            if p == .active { model.foreground() }
            if p == .inactive { model.syncNowActivity() }
            if p == .background {
                BackgroundRefresh.schedule()
                Persistence.save(model.state)
                LocalStore.defaults.set(false, forKey: LocalStore.Key.runActive)
            }
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
        let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let window: DateInterval? = {
            guard let s = info["start"] as? Double, let e = info["end"] as? Double, e > s else { return nil }
            return DateInterval(start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e))
        }()
        let question = info["question"] as? String
        let kind = info["kind"] as? String
        await MainActor.run {
            let model = AppModel.shared
            model.log(.notification, "answered", ["action": action, "id": response.notification.request.identifier,
                                                  "kind": kind ?? "", "typed": text.isEmpty ? "" : "\(text.count) chars"].filter { !$0.value.isEmpty })
            let blockId = (info["blockId"] as? String).flatMap(UUID.init(uuidString:))
            let itemId = (info["itemId"] as? String).flatMap(UUID.init(uuidString:))
            switch action {
            case "focus.start":
                if let id = blockId { model.startFocus(blockId: id) } else { model.startNowOrNext() }
            case "focus.snooze":
                if let id = blockId { model.snooze(blockId: id) }
            case "task.notToday":
                if let id = blockId { model.notToday(blockId: id) }
            case "scroll.gap":
                Friction.answered(stillScrolling: false)
                model.deepLink = "productium://today"
            case "scroll.yes": Friction.answered(stillScrolling: true)
            case "scroll.stop": Friction.answered(stillScrolling: false)
            case "item.done":
                if let id = itemId { model.complete(id) }
            case "end.15", "end.30":
                if let id = itemId { model.extend(id, minutes: action == "end.15" ? 15 : 30) }
            case "end.tomorrow":
                if let id = itemId { model.finishTomorrow(id) }
            case "item.focus":
                if let id = itemId, let item = model.state.items.first(where: { $0.id == id }) { model.focusNow(on: item) }
            case "run.stop": model.stopRunning(source: "notification")
            case "sleep.yes":
                if let w = window { model.confirmSleep(w) }
            case let a where a.hasPrefix("mood"):
                if let m = Int(a.dropFirst(4)) { model.logMood(m, energy: nil, note: nil) }
            case let a where a.hasPrefix("track.") && a != "track.reply":
                // A start button on "What are you up to?": now, or the past stretch it asked about.
                guard let i = Int(a.dropFirst(6)), let titles = info["actions"] as? [String], i < titles.count else { break }
                if let w = window, kind == NudgeKind.untracked.rawValue, response.notification.request.identifier == "track.past" {
                    model.logStretch(titles[i], w)
                } else {
                    model.start(title: titles[i], at: window.map { max($0.start, Date().addingTimeInterval(-3600)) }, source: "prompt")
                }
            case let a where a.hasPrefix("q."):
                model.answerQuestion(action: a, id: response.notification.request.identifier, text: text)
            case UNNotificationDefaultActionIdentifier:
                if let link = info["deeplink"] as? String { model.deepLink = link }
            default: break
            }
        }
        guard !text.isEmpty, !action.hasPrefix("q.") else { return }
        switch action {
        case "run.switch":
            await AppModel.shared.submit("starting \(text)", source: .notification)
        case "sleep.reply":
            await MainActor.run { _ = window.map { AppModel.shared.state.prompts.sleepAnswered.insert(DayKeys.key($0.end, AppModel.shared.cal)) } }
            await AppModel.shared.submit("I slept \(text)", source: .notification, context: question)
        case "track.reply":
            let what = window.map { w in "\(question ?? "What were you doing") (\(w.start.hm)–\(min(w.end, Date()).hm))" } ?? question
            await AppModel.shared.submit(text, source: .notification, context: what)
        default:
            await AppModel.shared.submit(text, source: .notification, context: question)
        }
    }
}
