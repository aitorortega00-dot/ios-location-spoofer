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

    static let feedbackName = "dev.duti.location-spoofer.tweak.feedback"
    static let loadedName = "dev.duti.location-spoofer.tweak.loaded"

    /// Logs what notifyd holds right now: our published state and the tweak's feedback.
    static func logStatus() {
        guard let en = getState(enabledName), let la = getState(latName), let lo = getState(lonName) else {
            DiagLog.add("[Tweak] status: cannot read state from notifyd")
            return
        }
        DiagLog.add(String(format: "[Tweak] status: spoof %@ %.6f, %.6f",
                           en == 1 ? "ON" : "OFF", Double(bitPattern: la), Double(bitPattern: lo)))
        let loaded = getState(loadedName) ?? 0
        DiagLog.add("[Tweak] loaded into \(loaded) process(es) since boot\(loaded == 0 ? " — tweak NOT active (not installed / not injected?)" : "")")
        guard let fb = getState(feedbackName), fb != 0 else {
            DiagLog.add("[Tweak] no location fixes seen yet (open Maps with spoof ON, then check again)")
            return
        }
        let type = Int(fb & 0xFF) - 1
        let dist = Int((fb >> 8) & 0xFFFF) * 10
        let replaced = (fb >> 24) & 0xFFFFF
        let kept = (fb >> 44) & 0xFFFFF
        DiagLog.add("[Tweak] last fix: type=\(type) dist≈\(dist) m · replaced=\(replaced) kept=\(kept) (counters of the last app that got a fix)")
    }

    private static func getState(_ name: String) -> UInt64? {
        var token: Int32 = -1
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return nil }
        defer { notify_cancel(token) }
        var v: UInt64 = 0
        guard notify_get_state(token, &v) == NOTIFY_STATUS_OK else { return nil }
        return v
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
