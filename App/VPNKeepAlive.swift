//
//  VPNKeepAlive.swift
//  location-spoofer
//
//  "Auto-reconnect": a VPN On-Demand rule so iOS itself brings the tunnel back
//  if it drops (screen locked for a long time, extension killed, iPhone rebooted),
//  without the app having to be opened. The tunnel reads the coordinates from the
//  shared App Group on start, so it comes back spoofing (or in shield mode).
//
//  It is switched on while the VPN is supposed to run (spoof active, or cache
//  shield on) and off before the app stops the VPN on purpose, so it never
//  fights a deliberate stop.
//
//  Also collects the tunnel's sleep/wake records (written by the extension) into
//  the diagnostics log, so pauses while the screen was locked become visible.
//

import Foundation
import NetworkExtension

enum VPNKeepAlive {
    private static let enabledKey = "vpnAutoReconnect"

    /// On by default (Settings › "Auto-reconnect VPN").
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// True when the VPN is supposed to be running right now.
    static var vpnShouldRun: Bool {
        LocationConfiguration.shared.currentCoordinates != nil || CacheShield.isEnabled
    }

    /// Turns the On-Demand rule on or off. `wanted` is combined with the setting.
    /// completion always runs on the main thread, even if saving fails.
    static func update(wanted: Bool, completion: (() -> Void)? = nil) {
        let want = wanted && isEnabled
        let done: () -> Void = { DispatchQueue.main.async { completion?() } }

        let apply: (NETunnelProviderManager) -> Void = { manager in
            manager.loadFromPreferences { _ in
                if manager.isOnDemandEnabled == want && (!want || !(manager.onDemandRules ?? []).isEmpty) {
                    done()
                    return
                }
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
                manager.isOnDemandEnabled = want
                manager.saveToPreferences { error in
                    if let error = error {
                        DiagLog.add("[keepalive] could not \(want ? "enable" : "disable") auto-reconnect: \(error.localizedDescription)")
                        done()
                        return
                    }
                    manager.loadFromPreferences { _ in
                        DiagLog.add("[keepalive] auto-reconnect \(want ? "ON" : "OFF")")
                        done()
                    }
                }
            }
        }

        if let manager = ContentView.vpnManager {
            apply(manager)
        } else {
            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                guard let manager = managers?.first else { done(); return }  // setup not done
                DispatchQueue.main.async {
                    if ContentView.vpnManager == nil { ContentView.vpnManager = manager }
                    apply(manager)
                }
            }
        }
    }

    // MARK: - Tunnel sleep/wake records

    private static let groupSuite = "group.dev.duti.location-spoofer"
    private static let eventsKey = "tunnelEvents"

    /// Moves the tunnel's sleep/wake records into the diagnostics log and clears them.
    static func collectTunnelEvents() {
        guard let defaults = UserDefaults(suiteName: groupSuite) else { return }
        defaults.synchronize()
        guard let events = defaults.stringArray(forKey: eventsKey), !events.isEmpty else { return }
        defaults.removeObject(forKey: eventsKey)
        defaults.synchronize()
        for e in events { DiagLog.add("[tunnel] \(e)") }
    }
}
