import Foundation
import UIKit
import CoreLocation

/// Reads coordinates the user copied in another app (Google Maps, Apple Maps, a message…)
/// so the app can set them automatically when it is opened.
///
/// Only reads the clipboard when its content changed since the last check (changeCount does
/// not trigger iOS's "Allow Paste" prompt), and only accepts text that is clearly a coordinate.
enum ClipboardCoords {
    private static let enabledKey = "clipboardAutoSetEnabled"
    private static let lastChangeKey = "clipboardLastChangeCount"
    private static let lastTextKey = "clipboardLastText"

    /// Settings → "Set location from clipboard". On by default.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Returns new coordinates found in the clipboard, or nil (nothing new / not coordinates).
    /// Each clipboard content is only used once.
    static func takeNew() -> CLLocationCoordinate2D? {
        guard isEnabled else { return nil }
        let pb = UIPasteboard.general
        let change = pb.changeCount
        let defaults = UserDefaults.standard
        if defaults.object(forKey: lastChangeKey) as? Int == change { return nil }
        defaults.set(change, forKey: lastChangeKey)
        guard pb.hasStrings, let text = pb.string else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The change counter can restart after a reboot: also remember the text itself.
        if defaults.string(forKey: lastTextKey) == trimmed { return nil }
        defaults.set(trimmed, forKey: lastTextKey)
        guard let coord = parse(trimmed) else {
            DiagLog.add("[clipboard] new text is not a coordinate, ignored")
            return nil
        }
        DiagLog.add("[clipboard] coordinates found: \(coord.latitude), \(coord.longitude)")
        return coord
    }

    // MARK: - Parsing

    static func parse(_ raw: String) -> CLLocationCoordinate2D? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000 else { return nil }

        if text.lowercased().hasPrefix("http") || text.contains("maps") {
            if let c = parseURL(text) { return c }
        }
        guard text.count <= 120 else { return nil }
        if let c = parseDecimalPair(text) { return c }
        if let c = parseHemisphere(text) { return c }
        if let c = parseDMS(text) { return c }
        return nil
    }

    private static let num = #"(-?\d{1,3}\.\d+)"#

    /// "40.4168, -3.7038" · "40.4168,-3.7038" · "40.4168 -3.7038" · "(40.4168, -3.7038)"
    /// The whole text must be the pair, with at least 2 decimals, to avoid picking up random numbers.
    private static func parseDecimalPair(_ text: String) -> CLLocationCoordinate2D? {
        let pattern = #"^\(?\s*(-?\d{1,2}\.\d{2,})\s*[,;\s]\s*(-?\d{1,3}\.\d{2,})\s*\)?$"#
        guard let m = firstMatch(pattern, in: text), m.count == 3 else { return nil }
        return valid(m[1], m[2])
    }

    /// Apple Maps style: "40.41680° N, 3.70380° W"
    private static func parseHemisphere(_ text: String) -> CLLocationCoordinate2D? {
        let pattern = #"^(\d{1,2}(?:\.\d+)?)\s*°?\s*([NS])\s*[,;\s]\s*(\d{1,3}(?:\.\d+)?)\s*°?\s*([EW])$"#
        guard let m = firstMatch(pattern, in: text.uppercased()), m.count == 5,
              var lat = Double(m[1]), var lon = Double(m[3]) else { return nil }
        if m[2] == "S" { lat = -lat }
        if m[4] == "W" { lon = -lon }
        return valid(lat, lon)
    }

    /// Google Maps style: 40°24'59.0"N 3°42'13.0"W
    private static func parseDMS(_ text: String) -> CLLocationCoordinate2D? {
        let part = #"(\d{1,3})\s*°\s*(\d{1,2})\s*['′]\s*(\d{1,2}(?:\.\d+)?)\s*(?:"|″|'')?\s*([NSEW])"#
        let pattern = "^" + part + #"\s*[,;\s]?\s*"# + part + "$"
        guard let m = firstMatch(pattern, in: text.uppercased()), m.count == 9 else { return nil }
        func value(_ d: String, _ mi: String, _ s: String, _ h: String) -> Double? {
            guard let d = Double(d), let mi = Double(mi), let s = Double(s) else { return nil }
            let v = d + mi / 60 + s / 3600
            return (h == "S" || h == "W") ? -v : v
        }
        guard let a = value(m[1], m[2], m[3], m[4]), let b = value(m[5], m[6], m[7], m[8]) else { return nil }
        let aIsLat = m[4] == "N" || m[4] == "S"
        return aIsLat ? valid(a, b) : valid(b, a)
    }

    /// Links from Google Maps / Apple Maps that contain the coordinates.
    /// (Short links like maps.app.goo.gl don't contain them and can't be read offline.)
    private static func parseURL(_ text: String) -> CLLocationCoordinate2D? {
        let decoded = text.removingPercentEncoding ?? text
        let patterns = [
            #"!3d"# + num + #"!4d"# + num,            // exact pin in Google Maps place links
            #"[?&](?:q|query|ll|sll|daddr|center|destination)="# + num + #"\s*,\s*"# + num,
            #"@"# + num + #","# + num,                  // map centre in Google Maps links
        ]
        for p in patterns {
            if let m = firstMatch(p, in: decoded), m.count == 3, let c = valid(m[1], m[2]) {
                return c
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func valid(_ a: String, _ b: String) -> CLLocationCoordinate2D? {
        guard let lat = Double(a), let lon = Double(b) else { return nil }
        return valid(lat, lon)
    }

    private static func valid(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D? {
        guard (-90...90).contains(lat), (-180...180).contains(lon), !(lat == 0 && lon == 0) else { return nil }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return CLLocationCoordinate2DIsValid(c) ? c : nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: text) else { return "" }
            return String(text[r])
        }
    }
}
