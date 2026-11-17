import Foundation
import CoreLocation
import Observation

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored static let shared = LocationService()
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored var onTransition: ((String, Bool) -> Void)?
    @ObservationIgnored private var pendingFix: CheckedContinuation<CLLocation?, Never>?
    private(set) var status: CLAuthorizationStatus = .notDetermined

    private static let askedAlwaysKey = "location.askedAlways"
    @ObservationIgnored private var wantsAlways = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        status = manager.authorizationStatus
    }

    var authorizedAlways: Bool { status == .authorizedAlways }

    /// iOS ignores an Always request made while the When-In-Use prompt is up, so ask for When In Use first
    /// and escalate once the answer arrives (and only once).
    func requestAlways() {
        wantsAlways = true
        status = manager.authorizationStatus
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: escalateIfNeeded()
        default: break
        }
    }

    private func escalateIfNeeded() {
        guard wantsAlways, manager.authorizationStatus == .authorizedWhenInUse,
              !UserDefaults.standard.bool(forKey: Self.askedAlwaysKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.askedAlwaysKey)
        manager.requestAlwaysAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        status = m.authorizationStatus
        escalateIfNeeded()
    }

    var statusText: String {
        switch status {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "Only While Using"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not Asked"
        }
    }

    /// Arrive and leave events need Always; While Using only works with the app open.
    var needsSettings: Bool { status == .authorizedWhenInUse || status == .denied }

    func currentLocation() async -> CLLocation? {
        await withCheckedContinuation { c in
            pendingFix = c
            manager.requestLocation()
        }
    }

    func monitor(_ places: [SavedPlace]) {
        for r in manager.monitoredRegions { manager.stopMonitoring(for: r) }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for p in places.prefix(20) {
            let r = CLCircularRegion(center: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                                     radius: min(p.radius, manager.maximumRegionMonitoringDistance), identifier: p.id)
            r.notifyOnEntry = true
            r.notifyOnExit = true
            manager.startMonitoring(for: r)
        }
    }

    func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) { onTransition?(region.identifier, true) }
    func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) { onTransition?(region.identifier, false) }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        pendingFix?.resume(returning: locations.last)
        pendingFix = nil
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        pendingFix?.resume(returning: nil)
        pendingFix = nil
    }
}
