//
//  TunnelSharedStatus.swift
//  location-spoofer
//
//  Second channel between the app and the tunnel that does not use app messages.
//  On some days sendProviderMessage always comes back empty although the tunnel is up,
//  so the app can neither confirm nor switch coordinates. The tunnel also writes its state
//  and recent log lines to the shared app group, and switches coordinates when the app
//  posts a Darwin notification.
//

import Foundation

enum TunnelSharedStatus {
    private static let groupSuite = "group.dev.duti.location-spoofer"
    private static let statusKey = "tunnelSharedStatus"
    private static let sharedLogKey = "tunnelSharedLog"
    private static let pendingCoordsKey = "pendingCoords"
    private static let pendingAckKey = "pendingCoordsAck"
    private static let coordsNotification = "dev.duti.location-spoofer.setCoords"

    struct Status {
        let age: TimeInterval
        let up: Int
        let running: Bool
        let appMessages: Int
        let lat: Double?
        let lon: Double?
        let enabled: Bool?

        var summary: String {
            let coords: String
            if let lat = lat, let lon = lon {
                coords = String(format: "%.6f, %.6f", lat, lon) + (enabled == true ? " (spoofing)" : " (shield)")
            } else {
                coords = "none"
            }
            return "tunnel status \(Int(age))s ago: up \(up / 60)m\(up % 60)s, proxy \(running ? "running" : "NOT running"), coords \(coords), app messages received \(appMessages)"
        }
    }

    static func read() -> Status? {
        guard let d = UserDefaults(suiteName: groupSuite) else { return nil }
        d.synchronize()
        guard let s = d.dictionary(forKey: statusKey), let t = s["t"] as? Double else { return nil }
        return Status(
            age: Date().timeIntervalSince1970 - t,
            up: s["up"] as? Int ?? 0,
            running: s["running"] as? Bool ?? false,
            appMessages: s["appMessages"] as? Int ?? 0,
            lat: s["lat"] as? Double,
            lon: s["lon"] as? Double,
            enabled: s["enabled"] as? Bool)
    }

    /// True if the tunnel reported these coordinates in the last few seconds.
    static func confirms(lat: Double, lon: Double) -> Bool {
        guard let s = read(), s.age < 6, s.running, s.enabled == true,
              let sLat = s.lat, let sLon = s.lon else { return false }
        return abs(sLat - lat) < 1e-5 && abs(sLon - lon) < 1e-5
    }

    static func recentLog() -> [String] {
        guard let d = UserDefaults(suiteName: groupSuite) else { return [] }
        d.synchronize()
        return d.stringArray(forKey: sharedLogKey) ?? []
    }

    /// Asks the tunnel to switch coordinates through the shared app group.
    /// completion(true) when the tunnel acknowledges within ~3 s.
    static func setCoords(lat: Double, lon: Double, enabled: Bool, completion: @escaping (Bool) -> Void) {
        guard let d = UserDefaults(suiteName: groupSuite) else { completion(false); return }
        let id = UUID().uuidString
        d.set("\(id)|\(enabled ? 1 : 0)|\(lat)|\(lon)", forKey: pendingCoordsKey)
        d.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(coordsNotification as CFString), nil, nil, true)

        let started = Date()
        func check() {
            d.synchronize()
            let ack = d.string(forKey: pendingAckKey) ?? ""
            if ack == "\(id)|OK" {
                DiagLog.add("[shared] setCoords enabled=\(enabled) → OK (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")
                completion(true)
            } else if ack == "\(id)|ERR" {
                DiagLog.add("[shared] setCoords enabled=\(enabled) → tunnel says proxy not running")
                completion(false)
            } else if Date().timeIntervalSince(started) > 3 {
                DiagLog.add("[shared] setCoords enabled=\(enabled) → no answer from the tunnel")
                completion(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
    }
}
