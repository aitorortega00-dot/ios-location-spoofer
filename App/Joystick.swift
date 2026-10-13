import SwiftUI
import CoreLocation
import NetworkExtension

/// Joystick for fast short-distance movement while spoofing is active.
///
/// Each step:
///   1. computes the new WGS-84 coordinate (metres → degrees),
///   2. sends it to the tunnel over IPC ("setCoords:<lat>,<lon>") — the Go proxy updates
///      in place, no VPN restart,
///   3. confirms with "getCoords" that Go holds the new coordinate,
///   4. cycles Location Services so iOS re-queries Wi-Fi positions.
///
/// Taps made while a step is running are accumulated and applied together in the next step,
/// so rapid tapping never queues a chain of Location Services restarts.
enum JoystickDirection: String, CaseIterable {
    case n = "N", ne = "NE", e = "E", se = "SE", s = "S", sw = "SW", w = "W", nw = "NW"

    /// Unit vector (north, east). Diagonals are normalised so a "5 m" step is 5 m in total.
    var vector: (north: Double, east: Double) {
        let d = 1.0 / 2.0.squareRoot()
        switch self {
        case .n:  return (1, 0)
        case .ne: return (d, d)
        case .e:  return (0, 1)
        case .se: return (-d, d)
        case .s:  return (-1, 0)
        case .sw: return (-d, -d)
        case .w:  return (0, -1)
        case .nw: return (d, -d)
        }
    }

    var arrowSymbol: String {
        switch self {
        case .n:  return "arrow.up"
        case .ne: return "arrow.up.right"
        case .e:  return "arrow.right"
        case .se: return "arrow.down.right"
        case .s:  return "arrow.down"
        case .sw: return "arrow.down.left"
        case .w:  return "arrow.left"
        case .nw: return "arrow.up.left"
        }
    }
}

enum JoystickGeo {
    /// Metres per degree of latitude (mean value, good to <1% for steps of metres).
    static let metersPerDegreeLat = 111_320.0

    /// Moves a WGS-84 coordinate by `north`/`east` metres.
    static func offset(lat: Double, lon: Double, north: Double, east: Double) -> (lat: Double, lon: Double) {
        let newLat = lat + north / metersPerDegreeLat
        let cosLat = max(cos(lat * .pi / 180), 1e-6)  // avoid division by zero at the poles
        var newLon = lon + east / (metersPerDegreeLat * cosLat)
        if newLon > 180 { newLon -= 360 }
        if newLon < -180 { newLon += 360 }
        return (min(max(newLat, -90), 90), newLon)
    }
}

@MainActor
final class JoystickController: ObservableObject {
    static let stepOptions: [Double] = [1, 5, 10, 25]
    static let offSecondsOptions: [Double] = [0.5, 1, 1.5, 2, 3]
    private static let stepKey = "joystickStepMeters"
    private static let offKey = "joystickOffSeconds"

    @Published var stepMeters: Double {
        didSet { UserDefaults.standard.set(stepMeters, forKey: Self.stepKey) }
    }
    /// How long Location Services stays off on each step. 3 s = same as the normal flow.
    @Published var offSeconds: Double {
        didSet { UserDefaults.standard.set(offSeconds, forKey: Self.offKey) }
    }
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var statusIsError = false
    /// Accumulated offset not yet applied (metres).
    @Published private(set) var pendingNorth = 0.0
    @Published private(set) var pendingEast = 0.0
    @Published private(set) var stepCount = 0

    /// Called on the main thread with the new WGS-84 coordinate after Go confirmed it.
    var onMoved: ((CLLocationCoordinate2D) -> Void)?

    init() {
        let d = UserDefaults.standard
        let step = d.double(forKey: Self.stepKey)
        stepMeters = Self.stepOptions.contains(step) ? step : 5
        let off = d.double(forKey: Self.offKey)
        offSeconds = Self.offSecondsOptions.contains(off) ? off : 3
    }

    var hasPending: Bool { abs(pendingNorth) > 0.001 || abs(pendingEast) > 0.001 }

    func nudge(_ dir: JoystickDirection) {
        let v = dir.vector
        pendingNorth += v.north * stepMeters
        pendingEast += v.east * stepMeters
        DiagLog.add(String(format: "[Joystick] tap %@ %.0fm → pending N=%.2fm E=%.2fm%@",
                           dir.rawValue, stepMeters, pendingNorth, pendingEast, isBusy ? " (queued, step in progress)" : ""))
        if !isBusy {
            Task { await runLoop() }
        }
    }

    private func runLoop() async {
        isBusy = true
        defer { isBusy = false }
        while hasPending {
            let north = pendingNorth, east = pendingEast
            pendingNorth = 0; pendingEast = 0
            let ok = await applyStep(north: north, east: east)
            if !ok {
                // Drop whatever accumulated meanwhile: moving on from an unknown state is worse.
                pendingNorth = 0; pendingEast = 0
                return
            }
        }
    }

    private func applyStep(north: Double, east: Double) async -> Bool {
        let started = Date()
        guard let current = LocationConfiguration.shared.currentCoordinates else {
            fail("No active coordinate. Set a location first.")
            return false
        }
        let target = JoystickGeo.offset(lat: current.latitude, lon: current.longitude, north: north, east: east)
        let distance = (north * north + east * east).squareRoot()
        stepCount += 1
        let n = stepCount
        statusIsError = false
        statusText = String(format: "Step %d: moving %.1f m…", n, distance)
        DiagLog.add(String(format: "[Joystick] step %d N=%.2fm E=%.2fm (%.1fm) (%.7f, %.7f) → (%.7f, %.7f)",
                           n, north, east, distance, current.latitude, current.longitude, target.lat, target.lon))

        // 1) Deliver the coordinate to the tunnel. Three routes, fastest first:
        //    a) sendProviderMessage — does not answer on some ldid-signed installs,
        //    b) request file in the shared App Group container, polled by the tunnel every 0.25 s,
        //    c) restart the VPN — the tunnel reads the stored coordinate at start (same as the normal flow).
        LocationConfiguration.shared.setCoordinates(latitude: target.lat, longitude: target.lon)
        var route = ""
        switch await sendMessage(String(format: "setCoords:%.8f,%.8f", target.lat, target.lon)) {
        case .success(let reply) where reply == "OK":
            route = "ipc"
        case .success(let reply):
            DiagLog.add("[Joystick] step \(n) ipc rejected: \(reply)")
        case .failure(let err):
            DiagLog.add("[Joystick] step \(n) ipc unavailable: \(err.text)")
        }
        if route.isEmpty {
            statusText = String(format: "Step %d: sending via shared file…", n)
            if let err = await sendViaFile(lat: target.lat, lon: target.lon) {
                DiagLog.add("[Joystick] step \(n) file channel: \(err)")
            } else {
                route = "file"
            }
        }
        if route.isEmpty {
            statusText = String(format: "Step %d: restarting VPN with the new position…", n)
            DiagLog.add("[Joystick] step \(n) falling back to VPN restart")
            guard await restartTunnel() else {
                fail("Could not deliver the move to the tunnel. See diagnostics.")
                return false
            }
            route = "vpn-restart"
        }
        let tDelivered = Date().timeIntervalSince(started)
        DiagLog.add(String(format: "[Joystick] step %d delivered via %@ in %.2fs, restarting Location Services (off %.1fs)",
                           n, route, tDelivered, offSeconds))
        onMoved?(CLLocationCoordinate2D(latitude: target.lat, longitude: target.lon))

        // 3) Make iOS re-query Wi-Fi positions
        statusText = String(format: "Step %d: restarting Location Services…", n)
        let cycled = await LocationServicesToggle.cycle(offSeconds: offSeconds)
        let total = Date().timeIntervalSince(started)
        if cycled {
            statusText = String(format: "Step %d done: %.1f m in %.1fs", n, distance, total)
            DiagLog.add(String(format: "[Joystick] step %d OK total %.2fs", n, total))
            return true
        } else {
            DiagLog.add(String(format: "[Joystick] step %d auto-restart failed after %.2fs", n, total))
            fail("Proxy moved, but Location Services could not be restarted automatically. Restart it manually.")
            return false
        }
    }

    private func fail(_ message: String) {
        statusIsError = true
        statusText = message
    }

    // MARK: - IPC

    struct IPCError: Error {
        let text: String
        /// The tunnel process is gone or silent: a stop/start of the tunnel usually fixes it.
        let isRecoverableByRestart: Bool
    }

    /// Returns the tunnel's reply as text, or a precise reason why there is none.
    private func sendMessage(_ text: String) async -> Result<String, IPCError> {
        switch await sendRaw(text) {
        case .success(let data):
            return .success(String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")
        case .failure(let e):
            return .failure(e)
        }
    }

    private func sendRaw(_ text: String) async -> Result<Data, IPCError> {
        guard let manager = await loadManager() else {
            return .failure(IPCError(text: "no VPN configuration found", isRecoverableByRestart: false))
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            return .failure(IPCError(text: "VPN connection is not a tunnel session", isRecoverableByRestart: false))
        }
        let status = session.status
        guard status == .connected else {
            return .failure(IPCError(text: "VPN status is \(Self.describe(status)), not connected", isRecoverableByRestart: true))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<Data, IPCError>, Never>) in
            do {
                try session.sendProviderMessage(Data(text.utf8)) { response in
                    if let response {
                        cont.resume(returning: .success(response))
                    } else {
                        cont.resume(returning: .failure(IPCError(
                            text: "tunnel process did not answer (VPN shows connected)", isRecoverableByRestart: true)))
                    }
                }
            } catch {
                cont.resume(returning: .failure(IPCError(
                    text: "iOS refused the message: \(error.localizedDescription)", isRecoverableByRestart: true)))
            }
        }
    }

    /// Uses the manager loaded at launch, or loads it now if it is missing.
    private func loadManager() async -> NETunnelProviderManager? {
        if let m = ContentView.vpnManager { return m }
        DiagLog.add("[Joystick] vpnManager nil — loading from preferences")
        return await withCheckedContinuation { (cont: CheckedContinuation<NETunnelProviderManager?, Never>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, _ in
                DispatchQueue.main.async {
                    if let m = managers?.first { ContentView.vpnManager = m }
                    cont.resume(returning: managers?.first)
                }
            }
        }
    }

    // MARK: - File channel (see Tunnel/JoystickFileChannel.swift)

    /// Writes a request into the App Group container and waits for the tunnel's ack.
    /// Returns nil on success, or the reason it failed.
    private func sendViaFile(lat: Double, lon: Double, timeout: Double = 2.0) async -> String? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.duti.location-spoofer") else {
            return "App Group container unavailable"
        }
        let seq = Int64(Date().timeIntervalSince1970 * 1000)
        let request = String(format: "%lld,%.8f,%.8f", seq, lat, lon)
        do {
            try request.write(to: dir.appendingPathComponent("joystick-request.txt"), atomically: true, encoding: .utf8)
        } catch {
            return "could not write request: \(error.localizedDescription)"
        }
        let ackURL = dir.appendingPathComponent("joystick-ack.txt")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ack = try? String(contentsOf: ackURL, encoding: .utf8),
               ack.hasPrefix("\(seq),") {
                let result = String(ack.dropFirst("\(seq),".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return result == "OK" ? nil : "tunnel answered \(result)"
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return String(format: "no ack from tunnel within %.1fs (old tunnel build still running?)", timeout)
    }

    /// Stops and starts the tunnel; on start it loads the coordinate stored in the App Group.
    private func restartTunnel() async -> Bool {
        guard let manager = await loadManager() else { return false }
        let started = Date()
        let conn = manager.connection
        if conn.status != .disconnected && conn.status != .invalid {
            conn.stopVPNTunnel()
            _ = await waitForStatus(conn, .disconnected, timeout: 8)
        }
        do {
            try conn.startVPNTunnel()
        } catch {
            DiagLog.add("[Joystick] restartTunnel startVPNTunnel error: \(error.localizedDescription)")
            return false
        }
        guard await waitForStatus(conn, .connected, timeout: 15) else {
            DiagLog.add("[Joystick] restartTunnel: never reached connected (status \(Self.describe(conn.status)))")
            return false
        }
        // .connected does not mean the Go proxy is listening yet (same 2 s buffer as the normal flow).
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        DiagLog.add(String(format: "[Joystick] restartTunnel OK in %.1fs", Date().timeIntervalSince(started)))
        return true
    }

    private func waitForStatus(_ conn: NEVPNConnection, _ target: NEVPNStatus, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if conn.status == target { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return conn.status == target
    }

    private static func describe(_ s: NEVPNStatus) -> String {
        switch s {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

}

/// Compact on-map panel: 8-direction pad, step size and Location Services off time.
struct JoystickPanel: View {
    @ObservedObject var controller: JoystickController
    var onClose: () -> Void

    private let grid: [[JoystickDirection?]] = [
        [.nw, .n, .ne],
        [.w, nil, .e],
        [.sw, .s, .se],
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Joystick", systemImage: "dpad")
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("Close joystick")
            }

            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { col in
                            if let dir = grid[row][col] {
                                Button { controller.nudge(dir) } label: {
                                    Image(systemName: dir.arrowSymbol)
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 52, height: 52)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundColor(.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .accessibilityLabel("Move \(dir.rawValue)")
                            } else {
                                centerCell
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Step").font(.caption).foregroundColor(.secondary)
                Picker("Step", selection: $controller.stepMeters) {
                    ForEach(JoystickController.stepOptions, id: \.self) { m in
                        Text("\(Int(m)) m").tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Location Services off time").font(.caption).foregroundColor(.secondary)
                Picker("Off time", selection: $controller.offSeconds) {
                    ForEach(JoystickController.offSecondsOptions, id: \.self) { s in
                        Text(s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s)).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(alignment: .top, spacing: 6) {
                if controller.isBusy { ProgressView().controlSize(.small) }
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundColor(controller.statusIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 4)
    }

    /// Centre of the pad: shows the queued distance while a step is running.
    private var centerCell: some View {
        let queued = (controller.pendingNorth * controller.pendingNorth + controller.pendingEast * controller.pendingEast).squareRoot()
        return VStack(spacing: 0) {
            if controller.hasPending {
                Text(String(format: "+%.0f m", queued)).font(.caption2.weight(.semibold))
                Text("queued").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                Image(systemName: "circle.fill").font(.system(size: 8)).foregroundColor(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }
}
