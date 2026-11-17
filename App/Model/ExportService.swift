import Foundation
import UIKit
import UserNotifications
import CoreLocation
import EventKit
import HealthKit
import ProductiumCore

/// UserDefaults values (plist types) as JSON and back. Data and dates, which JSON doesn't have,
/// become `{"$data": base64}` and `{"$date": iso8601}`.
enum PlistJSON {
    static func json(_ v: Any) -> JSONValue {
        switch v {
        case let s as String: return .string(s)
        case let d as Data: return .object(["$data": .string(d.base64EncodedString())])
        case let d as Date: return .object(["$date": .string(ISO8601DateFormatter().string(from: d))])
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let a as [Any]: return .array(a.map(json))
        case let o as [String: Any]: return .object(o.mapValues(json))
        default: return .string(String(describing: v))
        }
    }

    static func value(_ j: JSONValue) -> Any? {
        switch j {
        case .string(let s): return s
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .array(let a): return a.compactMap(value)
        case .object(let o):
            if o.count == 1, case .string(let b)? = o["$data"] { return Data(base64Encoded: b) }
            if o.count == 1, case .string(let d)? = o["$date"] { return ISO8601DateFormatter().date(from: d) }
            return o.compactMapValues(value)
        case .null: return nil
        }
    }

    static func domain(_ d: [String: Any]?) -> [String: JSONValue] { (d ?? [:]).mapValues(json) }
}

/// Builds and restores the one-file export (see `ExportBundle`).
@MainActor
enum ExportService {
    /// Files already in the bundle under their own names, so they aren't copied twice.
    static let representedFiles: Set<String> = ["container/state.json", "container/ai-calls.json", "documents/about-me.md"]

    static var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static var appDomainName: String { Bundle.main.bundleIdentifier ?? "productium" }

    static func make(_ model: AppModel) async -> ExportBundle {
        Persistence.save(model.state)
        CallLogStore.save(model.callLog)
        let info = Bundle.main.infoDictionary
        let device = ExportBundle.Device(appVersion: info?["CFBundleShortVersionString"] as? String,
                                         appBuild: info?["CFBundleVersion"] as? String,
                                         systemVersion: UIDevice.current.systemVersion, model: deviceModel,
                                         timeZone: TimeZone.current.identifier)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map { r in
            ExportBundle.Notification(id: r.identifier, title: r.content.title, body: r.content.body,
                                      at: (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                                        ?? (r.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate(),
                                      category: r.content.categoryIdentifier, userInfo: PlistJSON.json(r.content.userInfo as? [String: Any] ?? [:]))
        }
        let delivered = await center.deliveredNotifications().map { n in
            ExportBundle.Notification(id: n.request.identifier, title: n.request.content.title, body: n.request.content.body,
                                      at: n.date, category: n.request.content.categoryIdentifier,
                                      userInfo: PlistJSON.json(n.request.content.userInfo as? [String: Any] ?? [:]))
        }
        var snapshots: [String: JSONValue] = [:]
        if let u = model.serverUsage.flatMap(JSONValue.encoding) { snapshots["usage"] = u }
        if let s = model.subscription.flatMap(JSONValue.encoding) { snapshots["subscription"] = s }
        return ExportBundle(exportedAt: Date(), device: device, state: model.state, aboutMe: model.aboutMe.markdown,
                            callLog: model.callLog,
                            sharedDefaults: PlistJSON.domain(SharedConfig.defaults.persistentDomain(forName: SharedConfig.appGroup)),
                            appDefaults: PlistJSON.domain(UserDefaults.standard.persistentDomain(forName: appDomainName)),
                            files: files(), pendingNotifications: pending, deliveredNotifications: delivered,
                            permissions: await permissions(), serverSnapshots: snapshots)
    }

    /// Every file under the app's container and Documents, except the ones the bundle already holds.
    static func files() -> [String: String] {
        var out: [String: String] = [:]
        for (prefix, root) in [("container", SharedConfig.containerURL), ("documents", documentsURL)] {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in e {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let key = "\(prefix)/\(rel)"
                guard !representedFiles.contains(key), !rel.hasPrefix("Library/"), let data = try? Data(contentsOf: url) else { continue }
                out[key] = data.base64EncodedString()
            }
        }
        return out
    }

    static func permissions() async -> [String: String] {
        var p: [String: String] = [:]
        let n = await UNUserNotificationCenter.current().notificationSettings()
        p["notifications"] = ["notDetermined", "denied", "authorized", "provisional", "ephemeral"][safe: n.authorizationStatus.rawValue] ?? "\(n.authorizationStatus.rawValue)"
        let loc = CLLocationManager().authorizationStatus
        p["location"] = ["notDetermined", "restricted", "denied", "authorizedAlways", "authorizedWhenInUse"][safe: Int(loc.rawValue)] ?? "\(loc.rawValue)"
        let ek = EKEventStore.authorizationStatus(for: .event)
        p["calendar"] = ["notDetermined", "restricted", "denied", "fullAccess", "writeOnly"][safe: ek.rawValue] ?? "\(ek.rawValue)"
        if HKHealthStore.isHealthDataAvailable() {
            let store = HealthService.shared.store
            // HealthKit never says whether *read* access was granted; this is the share status and
            // whether the request sheet would still show.
            let types: [(String, HKObjectType)] = [
                ("health.sleep", HKCategoryType(.sleepAnalysis)), ("health.steps", HKQuantityType(.stepCount)),
                ("health.daylight", HKQuantityType(.timeInDaylight)), ("health.restingHeartRate", HKQuantityType(.restingHeartRate)),
                ("health.mindful", HKCategoryType(.mindfulSession)),
            ]
            for (name, type) in types {
                p[name] = ["notDetermined", "sharingDenied", "sharingAuthorized"][safe: store.authorizationStatus(for: type).rawValue] ?? "?"
            }
            let status = try? await store.statusForAuthorizationRequest(toShare: [HKCategoryType(.mindfulSession)],
                                                                         read: [HKCategoryType(.sleepAnalysis), HKQuantityType(.stepCount)])
            p["health.request"] = status.map { ["unknown", "shouldRequest", "unnecessary"][safe: $0.rawValue] ?? "?" } ?? "error"
        } else {
            p["health"] = "unavailable"
        }
        return p
    }

    static var deviceModel: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Puts everything back. The current data is set aside first (state-before-restore.json).
    static func restore(_ b: ExportBundle, into model: AppModel) {
        if let data = try? ExportBundle.encoder().encode(model.state) {
            try? data.write(to: Persistence.url.deletingLastPathComponent().appendingPathComponent("state-before-restore.json"), options: .atomic)
        }
        model.state.restore(full: b.state)
        model.aboutMe = AboutMe.parse(b.aboutMe)
        model.callLog = b.callLog
        CallLogStore.save(b.callLog)
        let shared = SharedConfig.defaults
        for (k, v) in b.sharedDefaults { shared.set(PlistJSON.value(v), forKey: k) }
        for (k, v) in b.appDefaults { UserDefaults.standard.set(PlistJSON.value(v), forKey: k) }
        for (key, base64) in b.files where key != "container/state-before-restore.json" {
            guard let data = Data(base64Encoded: base64) else { continue }
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let root = parts[0] == "documents" ? documentsURL : SharedConfig.containerURL
            let url = root.appendingPathComponent(parts[1])
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        Persistence.save(model.state)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
