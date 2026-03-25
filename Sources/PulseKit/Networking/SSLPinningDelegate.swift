// Sources/PulseKit/Networking/SSLPinningDelegate.swift
//  PulseKit
//
//  Created by Pulse


import Foundation
import CryptoKit

// MARK: - PulseSessionDelegate

/// `URLSessionDelegate` that enforces SSL certificate pinning when
/// `pinnedHashes` is non-empty.
///
/// Pinning is based on the **Subject Public Key Info (SPKI)** SHA-256 hash,
/// which survives certificate rotation (same key, new cert).
/// Generate hashes with:
/// ```
/// openssl s_client -connect api.example.com:443 | \
///   openssl x509 -pubkey -noout | \
///   openssl pkey -pubin -outform der | \
///   openssl dgst -sha256 -binary | \
///   base64
/// ```
final class PulseSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    private let pinnedHashes: Set<String>

    init(pinnedHashes: Set<String>) {
        self.pinnedHashes = pinnedHashes
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // If no pins configured, proceed with default OS validation
        guard !pinnedHashes.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Validate the certificate chain via SecTrust
        var secResult = SecTrustResultType.invalid
        SecTrustEvaluate(serverTrust, &secResult)

        guard secResult == .unspecified || secResult == .proceed else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Extract server certificate SPKI hashes and compare
        let certificateCount = SecTrustGetCertificateCount(serverTrust)
        for index in 0..<certificateCount {
            guard let certificate = SecTrustGetCertificateAtIndex(serverTrust, index) else { continue }
            if let hash = spkiHash(for: certificate), pinnedHashes.contains(hash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // No matching pin found — reject
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - SPKI Extraction

    private func spkiHash(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }

        // Prepend the ASN.1 header for RSA-2048 or EC P-256 as needed
        let spkiData = asn1Header(for: publicKey).map { Data($0) + publicKeyData } ?? publicKeyData
        let hash = SHA256.hash(data: spkiData)
        return Data(hash).base64EncodedString()
    }

    /// Returns the appropriate ASN.1 header bytes for the given key type,
    /// matching the format used by popular pin-generation tools.
    private func asn1Header(for key: SecKey) -> [UInt8]? {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let keySize = attributes[kSecAttrKeySizeInBits as String] as? Int else {
            return nil
        }

        // RSA-2048
        if keyType == (kSecAttrKeyTypeRSA as String), keySize == 2048 {
            return [
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
                0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
                0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
            ]
        }
        // EC P-256
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String), keySize == 256 {
            return [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
                0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
                0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
                0x42, 0x00
            ]
        }
        return nil
    }
}
