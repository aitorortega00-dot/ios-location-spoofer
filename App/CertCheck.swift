//
//  CertCheck.swift
//  location-spoofer
//
//  Real check of the proxy's CA: asks iOS whether it trusts the CA the tunnel signs with.
//  "Certificate status" only remembers that setup was done once; if the app made a new CA
//  (e.g. after reinstalling) iOS may still trust only the old one and refuse the proxy.
//

import Foundation
import Security
import CryptoKit

enum CertCheck {
    private static let groupSuite = "group.dev.duti.location-spoofer"
    private static let caCertKey = "LOCATIONSPOOFER_CA_Certificate"

    static func report() -> String {
        guard let d = UserDefaults(suiteName: groupSuite),
              let pem = d.string(forKey: caCertKey) else {
            return "no CA stored yet (the VPN creates it on first start)"
        }
        let b64 = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: b64),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return "stored CA could not be read"
        }
        let digest = SHA256.hash(data: der).map { String(format: "%02X", $0) }
        let fingerprint = digest.prefix(6).joined(separator: " ")

        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else {
            return "SHA-256 \(fingerprint)…, trust check failed to run"
        }
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        if trusted {
            return "SHA-256 \(fingerprint)…, TRUSTED by iOS"
        }
        let why = (error as Error?)?.localizedDescription ?? "unknown reason"
        return "SHA-256 \(fingerprint)…, NOT trusted by iOS (\(why))"
    }
}
