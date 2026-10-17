//
//  CacheShield.swift
//  location-spoofer
//
//  "Cache shield": when spoofing is turned off, the VPN keeps running without
//  coordinates instead of stopping. The proxy then blocks gs-loc.apple.com and
//  the gspe*-ssl.ls.apple.com downloads, so iOS never receives (and caches) the
//  real positions of the Wi-Fi networks around (e.g. at home). That cache is what
//  used to drag the spoofed location back home and forced a
//  "Reset Location & Privacy" before every session.
//
//  Also holds the live coordinate switch (setCoords IPC): the proxy changes
//  coordinates without restarting the VPN, so there is no gap in which iOS
//  could talk to Apple directly.
//

import Foundation
import NetworkExtension

enum CacheShield {
    private static let enabledKey = "cacheShieldEnabled"

    /// On by default.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: - Live coordinate switch

    /// Asks the running tunnel to switch coordinates live.
    /// `enabled == false` puts the proxy in shield mode. completion(true) only on "OK".
    static func sendSetCoords(lat: Double, lon: Double, enabled: Bool, completion: @escaping (Bool) -> Void) {
        guard let manager = ContentView.vpnManager,
              manager.connection.status == .connected,
              let session = manager.connection as? NETunnelProviderSession else {
            DiagLog.add("[live] tunnel not connected, cannot switch live")
            completion(false)
            return
        }
        let msg = "setCoords:\(enabled ? 1 : 0):\(lat):\(lon)"
        var done = false
        let finish: (Bool, String) -> Void = { ok, why in
            DispatchQueue.main.async {
                guard !done else { return }
                done = true
                DiagLog.add("[live] setCoords enabled=\(enabled) → \(ok ? "OK" : "failed: \(why)")")
                completion(ok)
            }
        }
        do {
            try session.sendProviderMessage(Data(msg.utf8)) { response in
                let text = response.flatMap { String(data: $0, encoding: .utf8) } ?? "(no reply)"
                finish(text == "OK", text)
            }
        } catch {
            finish(false, error.localizedDescription)
        }
        // Old tunnel builds just echo unknown commands; a missing reply must not hang the UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(false, "timeout") }
    }

    // MARK: - Start / restart the tunnel in shield mode

    private final class Box {
        var done = false
        var stopping = false
        var observer: NSObjectProtocol?
    }

    /// Starts the tunnel (or restarts it so it re-reads the cleared coordinates).
    /// Call after `LocationConfiguration.shared.clearCoordinates()`.
    static func startOrRestart(completion: @escaping (Bool) -> Void) {
        let run: (NETunnelProviderManager) -> Void = { manager in
            let box = Box()
            let finish: (Bool) -> Void = { ok in
                guard !box.done else { return }
                box.done = true
                if let o = box.observer { NotificationCenter.default.removeObserver(o) }
                DiagLog.add("[shield] \(ok ? "VPN running in shield mode" : "could not start shield mode")")
                completion(ok)
            }
            box.observer = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange, object: nil, queue: .main
            ) { note in
                guard let conn = note.object as? NEVPNConnection, conn === manager.connection else { return }
                switch conn.status {
                case .disconnected, .invalid:
                    if box.stopping {
                        box.stopping = false
                        do { try manager.connection.startVPNTunnel() } catch { finish(false) }
                    } else if conn.status == .invalid {
                        finish(false)
                    }
                case .connected:
                    if !box.stopping { finish(true) }
                default:
                    break
                }
            }
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                DiagLog.add("[shield] restarting VPN without coordinates")
                box.stopping = true
                manager.connection.stopVPNTunnel()
            default:
                DiagLog.add("[shield] starting VPN without coordinates")
                do { try manager.connection.startVPNTunnel() } catch { finish(false) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish(false) }
        }

        if let manager = ContentView.vpnManager,
           manager.connection.status == .connected || manager.connection.status == .connecting {
            run(manager)
        } else {
            // Stopped: re-save/reload the config first, exactly like the cold-start path.
            ContentView.installAndStartVPN { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let manager): run(manager)
                    case .failure(let error):
                        DiagLog.add("[shield] VPN config prep failed: \(error.localizedDescription)")
                        completion(false)
                    }
                }
            }
        }
    }

    /// Called on app launch: if the shield is on, spoofing is off and the VPN is down
    /// (e.g. after a reboot), bring the shield back up. Checks the real VPN status first
    /// so it never touches a running spoof.
    static func ensureRunningIfIdle(isSpoofingOff: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard isEnabled else { completion(false); return }
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            DispatchQueue.main.async {
                guard let manager = managers?.first else { completion(false); return }  // setup not done
                if ContentView.vpnManager == nil { ContentView.vpnManager = manager }
                let status = manager.connection.status
                guard status == .disconnected || status == .invalid, isSpoofingOff() else {
                    completion(false)
                    return
                }
                DiagLog.add("[shield] VPN was off on launch, starting shield mode")
                LocationConfiguration.shared.clearCoordinates()
                UserDefaults.standard.removeObject(forKey: "currentLocationName")
                startOrRestart(completion: completion)
            }
        }
    }

    /// Settings toggle turned off while idle: stop the shield VPN (spoof stays untouched).
    static func stopIfIdle() {
        guard LocationConfiguration.shared.currentCoordinates == nil,
              let manager = ContentView.vpnManager,
              manager.connection.status != .disconnected else { return }
        DiagLog.add("[shield] turned off in Settings, stopping VPN")
        manager.connection.stopVPNTunnel()
    }
}
