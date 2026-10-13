//
//  JoystickFileChannel.swift
//  location-spoofer-tunnel
//
//  App → tunnel channel for the in-app joystick that does not depend on sendProviderMessage
//  (which does not answer on some ldid-signed installs). The app writes a request file in the
//  shared App Group container; the tunnel polls it, applies the coordinate to the Go proxy in
//  place and writes an ack file the app waits for.
//
//  joystick-request.txt : "<seq>,<lat>,<lon>"
//  joystick-ack.txt     : "<seq>,OK"  or  "<seq>,ERR:<reason>"
//

import Foundation
import os.log

final class JoystickFileChannel {
    static let groupID = "group.dev.duti.location-spoofer"
    private let queue = DispatchQueue(label: "dev.duti.location-spoofer.joystick-file")
    private var timer: DispatchSourceTimer?
    private var lastSeq: Int64 = 0
    private let apply: (_ lat: Double, _ lon: Double) -> String?   // nil = OK, else error text

    init(apply: @escaping (_ lat: Double, _ lon: Double) -> String?) {
        self.apply = apply
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    func start() {
        guard let dir = Self.containerURL else {
            os_log("SPOOFTRACE joystick file channel: App Group container unavailable", log: OSLog.default, type: .error)
            return
        }
        let requestURL = dir.appendingPathComponent("joystick-request.txt")
        let ackURL = dir.appendingPathComponent("joystick-ack.txt")
        // Ignore a request left over from before this tunnel started.
        if let old = Self.read(requestURL) { lastSeq = old.seq }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self, let req = Self.read(requestURL), req.seq > self.lastSeq else { return }
            self.lastSeq = req.seq
            let error = self.apply(req.lat, req.lon)
            let ack = "\(req.seq),\(error.map { "ERR:\($0)" } ?? "OK")"
            try? ack.write(to: ackURL, atomically: true, encoding: .utf8)
            os_log("SPOOFTRACE joystick file request seq=%{public}lld (%{public}f, %{public}f) -> %{public}@",
                   log: OSLog.default, type: .default, req.seq, req.lat, req.lon, error ?? "OK")
        }
        t.resume()
        timer = t
        os_log("SPOOFTRACE joystick file channel started at %{public}@", log: OSLog.default, type: .default, dir.path)
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private static func read(_ url: URL) -> (seq: Int64, lat: Double, lon: Double)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard parts.count == 3, let seq = Int64(parts[0]),
              let lat = Double(parts[1]), let lon = Double(parts[2]) else { return nil }
        return (seq, lat, lon)
    }
}
