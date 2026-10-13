import Foundation
import CoreLocation
import ObjectiveC

/// Toggles system-wide Location Services through the private
/// `+[CLLocationManager setLocationServicesEnabled:]` API.
///
/// Only works when the app binary carries the locationd entitlements
/// (ldid-signed build installed on a jailbroken device / TrollStore).
/// On a normal signed build the call is silently ignored by locationd,
/// so every step verifies the real state and reports failure instead of
/// pretending it worked — the manual guide then stays on screen.
extension Notification.Name {
    /// Posted (main thread) right before Location Services is turned off by `cycle`.
    static let locationCycleWillStart = Notification.Name("LocationCycleWillStart")
    /// Posted (main thread) once the cycle is over and Location Services has settled.
    static let locationCycleDidEnd = Notification.Name("LocationCycleDidEnd")
}

enum LocationServicesToggle {
    /// True while `cycle` runs. Anything that requests the user's location must
    /// wait: asking while Location Services is off makes iOS show the
    /// "Turn On Location Services…" system alert.
    /// Only written on the main thread (inside `cycle`); plain static so non-isolated
    /// delegate callbacks can read it without an actor hop.
    nonisolated(unsafe) static private(set) var isCycling = false
    private static let setSelector = NSSelectorFromString("setLocationServicesEnabled:")

    /// True if the private selector exists on this iOS version.
    static var isAPIAvailable: Bool {
        class_getClassMethod(CLLocationManager.self, setSelector) != nil
    }

    /// Current system-wide Location Services state.
    static var isEnabled: Bool {
        CLLocationManager.locationServicesEnabled()
    }

    /// Calls the private setter. Returns false if the API is missing.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let method = class_getClassMethod(CLLocationManager.self, setSelector) else {
            return false
        }
        typealias Setter = @convention(c) (AnyClass, Selector, Bool) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        setter(CLLocationManager.self, setSelector, enabled)
        return true
    }

    /// Polls until Location Services reaches `target` or the timeout expires.
    private static func waitForState(_ target: Bool, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await readState() == target { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await readState() == target
    }

    /// Reads the state off the main thread (Apple warns against calling it on main).
    private static func readState() async -> Bool {
        await Task.detached(priority: .userInitiated) { isEnabled }.value
    }

    /// Off → wait `offSeconds` → on, verifying each step and logging to DiagLog.
    /// Returns true only if both transitions were confirmed.
    /// Maps pause their user-location tracking for the whole cycle (see notifications).
    @MainActor
    static func cycle(offSeconds: Double = 3.0) async -> Bool {
        isCycling = true
        NotificationCenter.default.post(name: .locationCycleWillStart, object: nil)
        // Give MapKit a moment to stop its location session before turning services off.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let ok = await runCycle(offSeconds: offSeconds)

        // Return right away so the caller can finish; maps resume in the background
        // once locationd has settled, so they don't trigger the system alert.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            isCycling = false
            NotificationCenter.default.post(name: .locationCycleDidEnd, object: nil)
        }
        return ok
    }

    private static func runCycle(offSeconds: Double) async -> Bool {
        guard isAPIAvailable else {
            DiagLog.add("[LocToggle] Private API not available on this iOS — manual restart needed")
            return false
        }

        let start = Date()
        DiagLog.add("[LocToggle] Auto-restart started (initial state: \(await readState() ? "ON" : "OFF"))")

        setEnabled(false)
        guard await waitForState(false, timeout: 2.0) else {
            DiagLog.add("[LocToggle] Could not turn OFF (missing entitlements?) — manual restart needed")
            return false
        }
        DiagLog.add("[LocToggle] Location Services OFF — waiting \(offSeconds)s")

        try? await Task.sleep(nanoseconds: UInt64(offSeconds * 1_000_000_000))

        setEnabled(true)
        guard await waitForState(true, timeout: 3.0) else {
            DiagLog.add("[LocToggle] Could not turn back ON — turn it on manually in Settings!")
            return false
        }
        let total = Date().timeIntervalSince(start)
        DiagLog.add(String(format: "[LocToggle] Location Services ON — cycle OK (%.1fs total)", total))
        return true
    }
}
