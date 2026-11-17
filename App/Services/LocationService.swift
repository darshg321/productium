import Foundation
import CoreLocation

final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    var onTransition: ((String, Bool) -> Void)?
    private var pendingFix: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizedAlways: Bool { manager.authorizationStatus == .authorizedAlways }

    func requestAlways() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestAlwaysAuthorization()
    }

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
