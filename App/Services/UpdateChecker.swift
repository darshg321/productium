import Foundation
import Observation
import ProductiumCore

/// Asks GitHub once a day whether a newer release exists. The endpoint is public and the request carries nothing about you.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let repo = "darshg321/productium"
    private static let key = "update.latestRelease"

    private(set) var latest: ReleaseInfo?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            latest = try? d.decode(ReleaseInfo.self, from: data)
        }
    }

    static var installed: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    var available: AppVersion? { latest?.update(over: Self.installed) }

    func checkIfDue(force: Bool = false) async {
        guard force || ReleaseInfo.isDue(last: latest?.checkedAt, now: Date()),
              let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Productium", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = ReleaseInfo.parse(data, now: Date()) else { return }
        latest = info
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(info) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
