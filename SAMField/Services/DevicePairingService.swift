//
//  DevicePairingService.swift
//  SAM Field
//
//  iPhone half of the pairing handshake. Stores the user's `phoneDeviceID`
//  (generated once) and a list of Macs this phone has been paired with —
//  each entry carries the Mac's pairing token (32 bytes) so we can
//  answer the Mac's authChallenge without ever sending the token over
//  the network.
//
//  Pairing tokens are stored in Keychain (device-only), never in
//  UserDefaults or iCloud. Entering a valid PIN on the Mac is the ONLY
//  way to add a trust entry — the Mac replies with a `pinPairingResult`
//  carrying the token, which this service accepts via
//  `acceptPinPairingResult`.
//

import CryptoKit
import Foundation
import Observation
import os.log

@MainActor
@Observable
final class DevicePairingService {
    static let shared = DevicePairingService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "DevicePairing")

    // MARK: - Persistent state

    /// This phone's stable identifier. Generated once per install.
    private(set) var phoneDeviceID: UUID = UUID()

    /// Trusted Macs. `macDeviceID` → on-disk record (Keychain + UserDefaults
    /// index). Populated by scanning a Mac's pairing QR.
    private(set) var trustedMacs: [TrustedMacRecord] = []

    private var isBootstrapped = false

    private static let phoneDeviceIDKey = "samfield.pairing.phoneDeviceID"
    private static let trustedMacsIndexKey = "samfield.pairing.trustedMacsIndex"
    private static func tokenKey(for macDeviceID: UUID) -> String {
        "samfield.pairing.token.\(macDeviceID.uuidString)"
    }

    // MARK: - Bootstrap

    /// Idempotent. Loads persisted identity + every trusted Mac's pairing
    /// token from Keychain. MUST be awaited before AudioStreamingService
    /// tries to authenticate to a Mac.
    func bootstrap() async {
        guard !isBootstrapped else { return }

        if let stored = await KeychainService.shared.retrieveString(forKey: Self.phoneDeviceIDKey),
           let uuid = UUID(uuidString: stored) {
            phoneDeviceID = uuid
        } else {
            let fresh = UUID()
            try? await KeychainService.shared.storeString(fresh.uuidString, forKey: Self.phoneDeviceIDKey)
            phoneDeviceID = fresh
            logger.info("Generated new phoneDeviceID")
        }

        // Load the trusted-Mac index from UserDefaults and hydrate each
        // entry's pairing token from Keychain. The index stores only
        // non-secret metadata (Mac ID, display name, pairing timestamp).
        if let data = UserDefaults.standard.data(forKey: Self.trustedMacsIndexKey),
           let indexEntries = try? JSONDecoder().decode([TrustedMacIndexEntry].self, from: data) {
            var hydrated: [TrustedMacRecord] = []
            for entry in indexEntries {
                let tokenData = await KeychainService.shared.retrieveData(
                    forKey: Self.tokenKey(for: entry.macDeviceID)
                )
                guard let tokenData, tokenData.count == 32 else {
                    logger.warning("Dropped trusted Mac \(entry.macDeviceID): no pairing token in keychain")
                    continue
                }
                hydrated.append(TrustedMacRecord(
                    macDeviceID: entry.macDeviceID,
                    macDisplayName: entry.macDisplayName,
                    pairedAt: entry.pairedAt,
                    pairingToken: tokenData
                ))
            }
            trustedMacs = hydrated
        }

        isBootstrapped = true
        logger.debug("Bootstrap complete: phoneID=\(self.phoneDeviceID), trusted Macs=\(self.trustedMacs.count)")
    }

    // MARK: - Pairing

    /// Accept a successful `pinPairingResult` from the Mac. Unpacks the
    /// 32-byte HMAC token, persists it to Keychain, and registers the Mac
    /// in `trustedMacs`. Returns the new record on success, or nil if the
    /// payload is malformed / failed.
    @discardableResult
    func acceptPinPairingResult(_ result: PinPairingResult) async -> TrustedMacRecord? {
        guard result.success,
              let tokenB64 = result.tokenB64,
              let macDeviceID = result.macDeviceID,
              let macDisplayName = result.macDisplayName else {
            logger.warning("acceptPinPairingResult: incomplete success payload")
            return nil
        }
        guard let tokenData = Data(base64Encoded: tokenB64), tokenData.count == 32 else {
            logger.warning("acceptPinPairingResult: malformed token (expected 32 bytes)")
            return nil
        }
        do {
            try await KeychainService.shared.storeData(tokenData, forKey: Self.tokenKey(for: macDeviceID))
        } catch {
            logger.error("Failed to persist pairing token: \(error.localizedDescription)")
            return nil
        }
        let record = TrustedMacRecord(
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            pairedAt: Date(),
            pairingToken: tokenData
        )
        trustedMacs.removeAll { $0.macDeviceID == macDeviceID }
        trustedMacs.append(record)
        persistIndex()
        logger.info("Paired with Mac \(macDeviceID) (\(macDisplayName, privacy: .private)) via PIN")
        return record
    }

    func isPaired(with macDeviceID: UUID) -> Bool {
        trustedMacs.contains { $0.macDeviceID == macDeviceID }
    }

    func pairingToken(for macDeviceID: UUID) -> Data? {
        trustedMacs.first { $0.macDeviceID == macDeviceID }?.pairingToken
    }

    func unpair(macDeviceID: UUID) async {
        trustedMacs.removeAll { $0.macDeviceID == macDeviceID }
        try? await KeychainService.shared.deleteItem(forKey: Self.tokenKey(for: macDeviceID))
        persistIndex()
        logger.info("Unpaired Mac \(macDeviceID)")
    }

    func unpairAll() async {
        let ids = trustedMacs.map(\.macDeviceID)
        trustedMacs.removeAll()
        for id in ids {
            try? await KeychainService.shared.deleteItem(forKey: Self.tokenKey(for: id))
        }
        persistIndex()
        logger.info("Unpaired all Macs")
    }

    // MARK: - HMAC

    /// Compute the phone's response to a Mac's `authChallenge`. Returns a
    /// base64-encoded HMAC-SHA256, or nil if we have no token for this Mac
    /// (i.e., the phone scanned a different Mac's QR).
    func computeHMACResponse(for macDeviceID: UUID, challengeB64: String) -> String? {
        guard let token = pairingToken(for: macDeviceID) else { return nil }
        let message = "\(AuthChallenge.hmacContext)|\(phoneDeviceID.uuidString)|\(challengeB64)"
        let key = SymmetricKey(data: token)
        let mac = HMAC<SHA256>.authenticationCode(for: Array(message.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    // MARK: - Persistence helpers

    private func persistIndex() {
        let index = trustedMacs.map {
            TrustedMacIndexEntry(
                macDeviceID: $0.macDeviceID,
                macDisplayName: $0.macDisplayName,
                pairedAt: $0.pairedAt
            )
        }
        if let data = try? JSONEncoder().encode(index) {
            UserDefaults.standard.set(data, forKey: Self.trustedMacsIndexKey)
        }
    }
}

// MARK: - Records

struct TrustedMacRecord: Identifiable, Sendable, Equatable {
    var id: UUID { macDeviceID }
    let macDeviceID: UUID
    var macDisplayName: String
    var pairedAt: Date
    /// 32-byte raw pairing token. Never sent over the network — only used
    /// to key the HMAC response.
    var pairingToken: Data
}

private struct TrustedMacIndexEntry: Codable {
    let macDeviceID: UUID
    let macDisplayName: String
    let pairedAt: Date
}
