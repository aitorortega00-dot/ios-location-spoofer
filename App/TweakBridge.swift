import Foundation
import notify

/// Publishes the spoof state to the LocSpoofGPS tweak (tweak/ folder, jailbreak only).
///
/// The tweak runs inside other apps, whose sandbox can't read our App Group, so the
/// state travels through notifyd: each Darwin notification name carries a 64-bit
/// state (the raw bits of a Double for lat/lon, 1/0 for enabled). Nothing is written
/// to disk; after a reboot the state is empty and the tweak stays inactive until the
/// next Set Location.
enum TweakBridge {
    static let enabledName = "dev.duti.location-spoofer.tweak.enabled"
    static let latName = "dev.duti.location-spoofer.tweak.lat"
    static let lonName = "dev.duti.location-spoofer.tweak.lon"
    static let changedName = "dev.duti.location-spoofer.tweak.changed"

    static func publish(latitude: Double, longitude: Double) {
        let ok = setState(latName, latitude.bitPattern)
            && setState(lonName, longitude.bitPattern)
            && setState(enabledName, 1)
        notify_post(changedName)
        DiagLog.add(String(format: "[Tweak] state published: ON %.6f, %.6f%@", latitude, longitude, ok ? "" : " (notify error)"))
    }

    static func clear() {
        let ok = setState(enabledName, 0)
        notify_post(changedName)
        DiagLog.add("[Tweak] state published: OFF\(ok ? "" : " (notify error)")")
    }

    private static var tokens: [String: Int32] = [:]
    private static let lock = NSLock()

    private static func setState(_ name: String, _ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var token = tokens[name] ?? -1
        if token == -1 {
            let rc = notify_register_check(name, &token)
            guard rc == NOTIFY_STATUS_OK else {
                DiagLog.add("[Tweak] register \(name) failed: \(rc)")
                return false
            }
            tokens[name] = token
        }
        let rc = notify_set_state(token, value)
        if rc != NOTIFY_STATUS_OK {
            DiagLog.add("[Tweak] set_state \(name) failed: \(rc)")
            return false
        }
        return true
    }
}
