import Foundation
import CoreLocation
import MapKit
import Observation
import ProductiumCore

@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    @ObservationIgnored static let shared = LocationService()
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored var onTransition: ((String, Bool) -> Void)?
    @ObservationIgnored var onVisit: ((PlaceVisit) -> Void)?
    /// E1: a coarse point while moving (significant changes, fixes), for the location history.
    @ObservationIgnored var onPoint: ((TracePoint) -> Void)?
    /// E1: kept while an entry runs, so updates keep coming and the entry's place is right (iOS 17+).
    @ObservationIgnored private var session: AnyObject?
    @ObservationIgnored private var pendingFix: CheckedContinuation<CLLocation?, Never>?
    private(set) var status: CLAuthorizationStatus = .notDetermined

    private static let askedAlwaysKey = "location.askedAlways"
    @ObservationIgnored private var wantsAlways = false
    @ObservationIgnored var visitsWanted = false

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
        monitorVisits(visitsWanted)
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

    /// Visits need Always. They find the places you keep returning to without a location history.
    func monitorVisits(_ on: Bool) {
        if on, manager.authorizationStatus == .authorizedAlways {
            manager.startMonitoringVisits()
            // E1: significant changes too (cheap, works with the app closed), for the points between visits.
            if CLLocationManager.significantLocationChangeMonitoringAvailable() { manager.startMonitoringSignificantLocationChanges() }
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = true
        } else {
            manager.stopMonitoringVisits()
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    /// E1: while something is being tracked live, keep a background activity session so its place is known.
    func tracking(_ on: Bool) {
        guard #available(iOS 17.0, *), manager.authorizationStatus == .authorizedAlways else { return }
        if on, session == nil {
            session = CLBackgroundActivitySession()
            manager.startUpdatingLocation()
        } else if !on, let s = session as? CLBackgroundActivitySession {
            s.invalidate()
            session = nil
            manager.stopUpdatingLocation()
        }
    }

    /// E2: a name for a new place from its address: a landmark iOS knows there (a school, a park), else the street
    /// address. Not the nearest business, which is often a neighbour's.
    func placeName(latitude: Double, longitude: Double) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude))
        guard let m = marks?.first else { return nil }
        return m.areasOfInterest?.first ?? m.name ?? m.thoroughfare ?? m.subLocality
    }

    func locationManager(_ m: CLLocationManager, didVisit visit: CLVisit) {
        let arrival = visit.arrivalDate == .distantPast ? nil : visit.arrivalDate
        guard let arrival else { return }
        let departure = visit.departureDate == .distantFuture ? nil : visit.departureDate
        onVisit?(PlaceVisit(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
                            arrival: arrival, departure: departure))
    }

    func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) { onTransition?(region.identifier, true) }
    func locationManager(_ m: CLLocationManager, didExitRegion region: CLRegion) { onTransition?(region.identifier, false) }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        pendingFix?.resume(returning: locations.last)
        pendingFix = nil
        for l in locations where l.horizontalAccuracy >= 0 && l.horizontalAccuracy < 500 {
            onPoint?(TracePoint(at: l.timestamp, latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, accuracy: l.horizontalAccuracy))
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        pendingFix?.resume(returning: nil)
        pendingFix = nil
    }
}
