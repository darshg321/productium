import Foundation
import EventKit
import Photos
import Vision
import UIKit
import ActivityKit
import ProductiumCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - M9: open tasks mirrored into a "Productium" list in Reminders ("Productium Dev" in dev builds)

@MainActor
final class ReminderService {
    static let shared = ReminderService()
    private let store = EKEventStore()
    private static let listKey = "reminders.listId"

    var authorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func requestAccess() async -> Bool { (try? await store.requestFullAccessToReminders()) ?? false }

    private func list() -> EKCalendar? {
        if let id = UserDefaults.standard.string(forKey: Self.listKey), let c = store.calendar(withIdentifier: id) { return c }
        let c = EKCalendar(for: .reminder, eventStore: store)
        c.title = AppInfo.name
        c.source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first { $0.sourceType == .local }
        guard (try? store.saveCalendar(c, commit: true)) != nil else { return nil }
        UserDefaults.standard.set(c.calendarIdentifier, forKey: Self.listKey)
        return c
    }

    private func fetch(_ cal: EKCalendar) async -> [EKReminder] {
        await withCheckedContinuation { c in
            store.fetchReminders(matching: store.predicateForReminders(in: [cal])) { c.resume(returning: $0 ?? []) }
        }
    }

    /// Two-way: titles follow the plan, missing tasks are added, gone ones removed, ticked-off ones complete the task.
    func sync(_ model: AppModel) async {
        guard model.state.integrations.reminders, authorized, let cal = list() else { return }
        let rs = await fetch(cal)
        let items = rs.map { r in
            ReminderItem(id: r.calendarItemIdentifier, title: r.title ?? "", completed: r.isCompleted,
                         taskId: r.url.flatMap { $0.host == "task" ? UUID(uuidString: $0.lastPathComponent) : nil })
        }
        var next: [UUID: Date] = [:]
        for b in model.state.plan.blocks where b.isStudy && b.start > Date() {
            if let id = b.itemId, next[id] == nil { next[id] = b.start }
        }
        let d = ReminderMirror.diff(tasks: model.state.items, reminders: items, next: next, calendar: model.cal)
        for id in d.completeTasks { model.complete(id) }
        for (taskId, title) in d.create {
            let r = EKReminder(eventStore: store)
            r.calendar = cal
            r.title = title
            r.url = AppInfo.url("task/\(taskId.uuidString)")
            if let t = model.state.items.first(where: { $0.id == taskId }) {
                r.dueDateComponents = model.cal.dateComponents([.year, .month, .day, .hour, .minute], from: t.due)
            }
            try? store.save(r, commit: false)
        }
        for (id, title) in d.retitle {
            if let r = rs.first(where: { $0.calendarItemIdentifier == id }) { r.title = title; try? store.save(r, commit: false) }
        }
        for id in d.delete {
            if let r = rs.first(where: { $0.calendarItemIdentifier == id }) { try? store.remove(r, commit: false) }
        }
        try? store.commit()
        if !(d.create.isEmpty && d.retitle.isEmpty && d.delete.isEmpty && d.completeTasks.isEmpty) {
            model.log(.sensor, "reminders", ["add": "\(d.create.count)", "retitle": "\(d.retitle.count)", "delete": "\(d.delete.count)",
                                             "completed": "\(d.completeTasks.count)"])
        }
    }
}

// MARK: - M5 / M6: Screen Time screenshots read on the phone

final class ScreenshotWatcher: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = ScreenshotWatcher()
    private static let seenKey = "photos.lastScreenshot"
    private var started = false

    var authorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    func requestAccess() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return s == .authorized || s == .limited
    }

    func start() {
        guard authorized, !started else { return }
        started = true
        PHPhotoLibrary.shared().register(self)
        Task { await check() }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) { Task { await check() } }

    /// New screenshots since the last look: Vision reads them; Screen Time ones are applied on the phone, the image goes
    /// to the box only when the text can't be read; homework-looking ones are offered as tasks.
    func check() async {
        let last = UserDefaults.standard.double(forKey: Self.seenKey)
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0 AND creationDate > %@",
                                     PHAssetMediaSubtype.photoScreenshot.rawValue, Date(timeIntervalSince1970: max(last, Date().timeIntervalSince1970 - 86400)) as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        var newest = last
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in list.append(a) }
        for a in list {
            newest = max(newest, a.creationDate?.timeIntervalSince1970 ?? newest)
            guard let img = await image(a) else { continue }
            let text = await Self.ocr(img)
            await MainActor.run { AppModel.shared.screenshot(text: text, image: img) }
        }
        UserDefaults.standard.set(newest, forKey: Self.seenKey)
    }

    private func image(_ a: PHAsset) async -> UIImage? {
        await withCheckedContinuation { c in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.isSynchronous = false
            o.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 1290, height: 2796), contentMode: .aspectFit, options: o) { img, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                c.resume(returning: img)
            }
        }
    }

    /// On-device OCR (no network, no prompt): one line per text block, top to bottom.
    static func ocr(_ img: UIImage) async -> String {
        guard let cg = img.cgImage else { return "" }
        return await Task.detached(priority: .utility) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            guard (try? VNImageRequestHandler(cgImage: cg).perform([req])) != nil else { return "" }
            return (req.results ?? []).sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

// MARK: - M7: Apple's on-device model, when the phone has it

enum OnDeviceModel {
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Files a title into one of the given category paths when no rule fits (free, instant, offline). nil: unsure or
    /// unavailable, and the caller keeps its fallback.
    static func categorise(_ title: String, paths: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), available, !paths.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: "You file a high-school student's activities into categories. Answer with one category exactly as written, or NONE.")
        let prompt = "Activity: \(title)\nCategories:\n" + paths.prefix(60).joined(separator: "\n")
        guard let answer = try? await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines),
              paths.contains(answer) else { return nil }
        return answer
        #else
        return nil
        #endif
    }
}

// MARK: - D5 / v1.3 B: the Now Live Activity (Lock Screen, Dynamic Island)

@MainActor
enum RunningActivity {
    /// Live Activities allowed in Settings; when off, notifications (and the passive running one, D6) are the fallback.
    static var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// The Now activity is on the Lock Screen, so prompts set to Live Activity aren't also sent as notifications (B2).
    static var showing: Bool { enabled && !Activity<NowAttributes>.activities.isEmpty }

    static let startedKey = "now.activityStartedAt"
    /// iOS ends an activity after 8 hours; one older than this is replaced while the app is open.
    static let renewAfter: TimeInterval = 7 * 3600

    /// One activity for whatever's now: updated in place, started when there's none, ended when there's nothing to show.
    static func sync(_ now: NowState?, rings: DayRings?, foreground: Bool) {
        for a in Activity<RunningAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        var current = Activity<NowAttributes>.activities
        guard enabled, let now else {
            for a in current { Task { await a.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        let state = NowAttributes.ContentState(card: card(now.card), then: now.then.map(card), rings: rings.map(mirror))
        let content = ActivityContent(state: state, staleDate: now.until)
        let started = LocalStore.defaults.double(forKey: startedKey)
        if foreground, !current.isEmpty, Date().timeIntervalSince1970 - started > renewAfter {
            for a in current { Task { await a.end(nil, dismissalPolicy: .immediate) } }
            current = []
        }
        if let a = current.first {
            for extra in current.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
            if a.content.state != state || a.content.staleDate != now.until { Task { await a.update(content) } }
            return
        }
        do {
            _ = try Activity.request(attributes: NowAttributes(), content: content, pushType: nil)
            LocalStore.defaults.set(Date().timeIntervalSince1970, forKey: startedKey)
            AppModel.shared.log(.notification, "live_activity_started", ["kind": now.card.kind.rawValue])
        } catch {
            AppModel.shared.log(.notification, "live_activity_failed", level: .error, ["error": "\(error)", "foreground": "\(foreground)"])
        }
    }

    static func card(_ c: NowCard) -> NowAttributes.Card {
        NowAttributes.Card(kind: c.kind.rawValue, title: c.title, subtitle: c.subtitle, since: c.since,
                           buttons: c.buttons.map { NowAttributes.Button(action: $0.action, label: $0.label, symbol: $0.symbol) },
                           other: c.other)
    }

    static func mirror(_ r: DayRings) -> NowAttributes.Rings {
        NowAttributes.Rings(work: r.work, tracked: r.tracked, limit: r.limit, workLabel: r.workLabel, trackedLabel: r.trackedLabel,
                            limitLabel: r.limitLabel)
    }
}
