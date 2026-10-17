//
//  SpoofHealthMonitor.swift
//  location-spoofer
//
//  While spoofing is active and the app is open, watches the location iOS
//  reports and tells the user why it escaped, if it does:
//
//  - .gps:   precise fix far from the target → real satellite signal
//            (near a window / outside). The app cannot block it.
//  - .cache: imprecise fix (big grey circle) far from the target → iOS is using
//            real Wi-Fi positions it cached earlier. Fix: reapply, and if it keeps
//            happening, Reset Location & Privacy with the VPN off.
//
//  It only reads locations; it never changes anything in the system.
//

import Foundation
import CoreLocation

final class SpoofHealthMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Issue: Equatable {
        case gps(distance: Double)
        case cache(distance: Double)
    }

    @Published private(set) var issue: Issue?

    private let manager = CLLocationManager()
    private var target: CLLocation?
    private var active = false
    private var ignoreUntil = Date.distantPast
    private var badSince: Date?
    private var observers: [NSObjectProtocol] = []

    /// A fix this precise (metres) is treated as GPS.
    private let gpsAccuracy: Double = 65
    /// Bad readings must persist this long before warning (avoids flicker).
    private let persistSeconds: Double = 6

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        // Location Services is switched off during the automatic restart; asking for the
        // location then makes iOS show the "Turn On Location Services" alert.
        observers.append(NotificationCenter.default.addObserver(
            forName: .locationCycleWillStart, object: nil, queue: .main
        ) { [weak self] _ in
            self?.manager.stopUpdatingLocation()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .locationCycleDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.active else { return }
            self.ignoreUntil = Date().addingTimeInterval(8)
            self.manager.startUpdatingLocation()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Start watching. `target` is the WGS-84 coordinate the proxy is serving.
    func start(target coord: CLLocationCoordinate2D) {
        target = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        active = true
        issue = nil
        badSince = nil
        ignoreUntil = Date().addingTimeInterval(8)  // let iOS settle after activation
        guard !LocationServicesToggle.isCycling else { return }
        manager.startUpdatingLocation()
    }

    func stop() {
        active = false
        target = nil
        issue = nil
        badSince = nil
        manager.stopUpdatingLocation()
    }

    /// Clears the current warning (e.g. after "Reapply") and waits for fresh readings.
    func reset() {
        issue = nil
        badSince = nil
        ignoreUntil = Date().addingTimeInterval(8)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let target, let loc = locations.last else { return }
        guard Date() >= ignoreUntil, abs(loc.timestamp.timeIntervalSinceNow) < 15,
              loc.horizontalAccuracy >= 0 else { return }

        let distance = loc.distance(from: target)
        let accuracy = loc.horizontalAccuracy
        // Inside the reported circle (plus margin) counts as OK.
        let ok = distance <= max(250, accuracy + 100)

        if ok {
            if issue != nil {
                DiagLog.add("[health] location back on target (d=\(Int(distance)) m)")
            }
            badSince = nil
            issue = nil
            return
        }

        let now = Date()
        if badSince == nil { badSince = now }
        guard now.timeIntervalSince(badSince!) >= persistSeconds else { return }

        let newIssue: Issue = accuracy <= gpsAccuracy ? .gps(distance: distance) : .cache(distance: distance)
        if !sameKind(issue, newIssue) {
            DiagLog.add("[health] location escaped: \(accuracy <= gpsAccuracy ? "GPS" : "Wi-Fi cache") d=\(Int(distance)) m acc=\(Int(accuracy)) m")
        }
        issue = newIssue
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to do: transient errors are normal (e.g. during the restart).
    }

    private func sameKind(_ a: Issue?, _ b: Issue) -> Bool {
        switch (a, b) {
        case (.gps?, .gps), (.cache?, .cache): return true
        default: return false
        }
    }
}
