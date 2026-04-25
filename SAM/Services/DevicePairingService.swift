//
//  DevicePairingService.swift
//  SAM
//
//  HMAC pairing token + auth for the iPhone ↔ Mac audio streaming link.
//
//  Trust model: every SAM device belongs to the same iCloud account, so the
//  CloudKit private DB is itself the trust boundary. There is no PIN/QR/
//  handshake UX — the Mac writes its 32-byte HMAC token to its private
//  CloudKit zone on first launch, and any phone signed into the same iCloud
//  account can read it. Phones from different iCloud accounts can't, and the
//  HMAC challenge fails for them automatically.
//
//  Wire flow:
//    1. Phone connects, learns macDeviceID from Bonjour TXT.
//    2. Mac sends `AuthChallenge`.
//    3. Phone HMACs `SAM-AUTH-v1|phoneDeviceID|challengeB64` with the token
//       and replies with `AuthResponse`.
//    4. Mac verifies. Unknown but valid phones are auto-trusted (their HMAC
//       proves they share the iCloud-distributed token).
//
//  The 32-byte token never leaves the Keychain on either device after the
//  initial CloudKit fetch. Resetting the token (Settings) regenerates it,
//  evicts all paired phones, and re-publishes to CloudKit.
//

import CryptoKit
import Foundation
import Observation
import os.log

@MainActor
@Observable
final class DevicePairingService {
    static let shared = DevicePairingService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DevicePairing")

    // MARK: - Persistent state

    private(set) var macDeviceID: UUID = UUID()
    private(set) var macDisplayName: String = "Mac"
    /// Raw 32-byte HMAC key. Distributed via CloudKit private DB; never sent
    /// over the local TCP stream.
    private var pairingTokenData: Data = Data()
    private(set) var pairedDevices: [PairedDeviceRecord] = []

    private var isBootstrapped = false

    // MARK: - Storage keys

    private static let macDeviceIDKey = "sam.pairing.macDeviceID"
    private static let pairingTokenKey = "sam.pairing.pairingToken"
    private static let pairedDevicesKey = "sam.pairing.pairedDevices"

    // MARK: - Bootstrap

    /// Load persistent state from Keychain + UserDefaults, then publish the
    /// pairing token to CloudKit so phones on the same iCloud account can
    /// pick it up. Idempotent.
    func bootstrap() async {
        guard !isBootstrapped else { return }

        if let stored = await KeychainService.shared.retrieveString(forKey: Self.macDeviceIDKey),
           let uuid = UUID(uuidString: stored) {
            macDeviceID = uuid
        } else {
            let fresh = UUID()
            try? await KeychainService.shared.storeString(fresh.uuidString, forKey: Self.macDeviceIDKey)
            macDeviceID = fresh
            logger.info("Generated new macDeviceID")
        }

        if let stored = await KeychainService.shared.retrieveData(forKey: Self.pairingTokenKey),
           stored.count == 32 {
            pairingTokenData = stored
        } else {
            let fresh = Self.randomBytes(32)
            try? await KeychainService.shared.storeData(fresh, forKey: Self.pairingTokenKey)
            pairingTokenData = fresh
            logger.info("Generated new pairing token")
        }

        if let data = UserDefaults.standard.data(forKey: Self.pairedDevicesKey),
           let decoded = try? JSONDecoder().decode([PairedDeviceRecord].self, from: data) {
            pairedDevices = decoded
        }

        macDisplayName = Self.defaultMacDisplayName()
        isBootstrapped = true
        logger.debug("Bootstrap complete: \(self.pairedDevices.count) paired device(s)")

        await CloudSyncService.shared.pushPairingToken(
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            tokenData: pairingTokenData
        )
    }

    // MARK: - Authentication

    /// Verify an `AuthResponse` carrying an HMAC of the challenge the Mac just sent.
    /// A valid HMAC is sufficient proof — only phones with the iCloud-distributed
    /// token can produce one. Unknown phones with valid HMACs are auto-added to
    /// `pairedDevices` (the CloudKit trust boundary already vouched for them).
    func authenticate(
        phoneDeviceID: UUID,
        phoneDisplayName: String,
        challengeB64: String,
        responseHMACB64: String
    ) -> AuthResult {
        guard isBootstrapped else {
            logger.error("authenticate called before bootstrap")
            return AuthResult(success: false, reason: "Mac not ready", macDisplayName: macDisplayName)
        }

        guard isValidHMAC(phoneDeviceID: phoneDeviceID, challengeB64: challengeB64, responseHMACB64: responseHMACB64) else {
            logger.warning("Auth failed: invalid HMAC from \(phoneDeviceID)")
            return AuthResult(success: false, reason: "Invalid credentials", macDisplayName: macDisplayName)
        }

        if let existingIndex = pairedDevices.firstIndex(where: { $0.id == phoneDeviceID }) {
            pairedDevices[existingIndex].lastSeenAt = Date()
            pairedDevices[existingIndex].displayName = phoneDisplayName
            persistPairedDevices()
            logger.info("Auth success for known phone \(phoneDeviceID)")
        } else {
            let record = PairedDeviceRecord(
                id: phoneDeviceID,
                displayName: phoneDisplayName,
                pairedAt: Date(),
                lastSeenAt: Date()
            )
            pairedDevices.append(record)
            persistPairedDevices()
            logger.info("Auto-trusted new phone \(phoneDeviceID) (\(phoneDisplayName, privacy: .private)) via CloudKit token")
        }
        return AuthResult(success: true, macDisplayName: macDisplayName)
    }

    /// Generate a fresh 16-byte challenge, base64-encoded for transit.
    func makeChallenge() -> (b64: String, raw: Data) {
        let raw = Self.randomBytes(16)
        return (raw.base64EncodedString(), raw)
    }

    // MARK: - Device management

    func unpair(phoneDeviceID: UUID) {
        pairedDevices.removeAll { $0.id == phoneDeviceID }
        persistPairedDevices()
        logger.info("Unpaired phone \(phoneDeviceID)")
    }

    func unpairAll() {
        pairedDevices.removeAll()
        persistPairedDevices()
        logger.info("Unpaired all devices")
    }

    /// Wipes the current token and generates a new one. Every paired phone is
    /// evicted because their old HMACs won't verify any more. The new token is
    /// republished to CloudKit so phones can re-fetch silently. User-invoked.
    func resetPairingToken() async {
        let fresh = Self.randomBytes(32)
        try? await KeychainService.shared.storeData(fresh, forKey: Self.pairingTokenKey)
        pairingTokenData = fresh
        unpairAll()
        await CloudSyncService.shared.pushPairingToken(
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            tokenData: pairingTokenData
        )
        logger.info("Pairing token reset and republished to CloudKit")
    }

    // MARK: - Private

    private func isValidHMAC(phoneDeviceID: UUID, challengeB64: String, responseHMACB64: String) -> Bool {
        guard let actual = Data(base64Encoded: responseHMACB64) else { return false }
        let message = "\(AuthChallenge.hmacContext)|\(phoneDeviceID.uuidString)|\(challengeB64)"
        let key = SymmetricKey(data: pairingTokenData)
        return HMAC<SHA256>.isValidAuthenticationCode(
            actual,
            authenticating: Array(message.utf8),
            using: key
        )
    }

    private func persistPairedDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            UserDefaults.standard.set(data, forKey: Self.pairedDevicesKey)
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func defaultMacDisplayName() -> String {
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return hostName
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: ".lan", with: "")
    }
}

// MARK: - PairedDeviceRecord

struct PairedDeviceRecord: Codable, Sendable, Identifiable, Equatable {
    /// phoneDeviceID.
    let id: UUID
    var displayName: String
    var pairedAt: Date
    var lastSeenAt: Date?
}
