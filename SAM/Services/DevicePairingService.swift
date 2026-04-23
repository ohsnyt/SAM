//
//  DevicePairingService.swift
//  SAM
//
//  PIN-based pairing + HMAC auth for the iPhone ↔ Mac audio streaming link.
//
//  Flow (simple PIN):
//    1. User clicks "Pair New iPhone" on the Mac → `startPINPairing()` generates
//       a random 6-digit PIN, displayed on screen for up to 90 seconds.
//    2. User opens SAM Field on the iPhone, types the PIN, taps Pair.
//    3. Phone sends `PinPairingRequest{pin, phoneDeviceID, phoneDisplayName}`.
//    4. Mac checks the PIN via `verifyPIN`. On match: registers the phone,
//       returns the HMAC token in `PinPairingResult`, and stops pairing mode.
//    5. Thereafter every connection from that phone uses the standard
//       HMAC-SHA256 challenge-response keyed by the pairing token.
//
//  The 32-byte pairing token is generated once at first launch and never
//  transmitted over the network except inside a successful PinPairingResult
//  (gated by the PIN). The phone stores it in Keychain; the Mac stores it in
//  Keychain under `sam.pairing.pairingToken`.
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
    /// Raw 32-byte HMAC key. Sent to the phone only inside a successful
    /// PinPairingResult; never leaves the Keychain otherwise.
    private var pairingTokenData: Data = Data()
    private(set) var pairedDevices: [PairedDeviceRecord] = []

    // MARK: - Transient pairing-mode state

    /// Current 6-digit PIN while a pairing window is open. Nil otherwise.
    private(set) var currentPIN: String?

    /// When the current PIN expires.
    private(set) var currentPINExpiresAt: Date?

    var isPINActive: Bool {
        guard let currentPIN, !currentPIN.isEmpty, let expires = currentPINExpiresAt else { return false }
        return expires > Date()
    }

    private var pinExpiryTask: Task<Void, Never>?
    private var isBootstrapped = false

    // MARK: - Storage keys

    private static let macDeviceIDKey = "sam.pairing.macDeviceID"
    private static let pairingTokenKey = "sam.pairing.pairingToken"
    private static let pairedDevicesKey = "sam.pairing.pairedDevices"

    // MARK: - Bootstrap

    /// Load persistent state from Keychain + UserDefaults. Idempotent. Call once at
    /// app launch before anyone can access `macDeviceID` / `pairingTokenData`.
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
    }

    // MARK: - Pairing mode

    /// Open a pairing window. Returns the 6-digit PIN to display on screen.
    /// While this window is open, an iPhone may connect and send a
    /// `PinPairingRequest` carrying this PIN to be registered as trusted.
    @discardableResult
    func startPINPairing(duration: TimeInterval = 90) -> String {
        pinExpiryTask?.cancel()

        let pin = Self.generatePIN()
        let expires = Date().addingTimeInterval(duration)
        currentPIN = pin
        currentPINExpiresAt = expires

        pinExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.stopPINPairing()
            }
        }

        logger.info("PIN pairing started (expires \(expires, privacy: .public))")
        return pin
    }

    /// Close the pairing window early (user cancelled, or a phone just paired).
    func stopPINPairing() {
        pinExpiryTask?.cancel()
        pinExpiryTask = nil
        if currentPIN != nil {
            logger.info("PIN pairing ended")
        }
        currentPIN = nil
        currentPINExpiresAt = nil
    }

    /// Verify a PIN sent by the phone. On success, register the phone and
    /// return a success result containing the HMAC token so the Mac can
    /// transmit it back.
    func verifyPIN(
        _ pin: String,
        phoneDeviceID: UUID,
        phoneDisplayName: String
    ) -> PinPairingResult {
        guard isBootstrapped else {
            return PinPairingResult(success: false, reason: "Mac not ready")
        }
        guard isPINActive, let active = currentPIN else {
            return PinPairingResult(success: false, reason: "This Mac isn't accepting pairs right now.")
        }
        guard pin == active else {
            logger.warning("PIN mismatch from phone \(phoneDeviceID)")
            return PinPairingResult(success: false, reason: "Incorrect PIN.")
        }

        // Register / refresh the paired-device record.
        let record = PairedDeviceRecord(
            id: phoneDeviceID,
            displayName: phoneDisplayName,
            pairedAt: Date(),
            lastSeenAt: Date()
        )
        pairedDevices.removeAll { $0.id == phoneDeviceID }
        pairedDevices.append(record)
        persistPairedDevices()

        // One-shot: successful PIN closes the window immediately.
        stopPINPairing()

        logger.info("Paired new phone \(phoneDeviceID) (\(phoneDisplayName, privacy: .private)) via PIN")
        return PinPairingResult(
            success: true,
            tokenB64: pairingTokenData.base64EncodedString(),
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName
        )
    }

    private static func generatePIN() -> String {
        String(format: "%06d", Int.random(in: 0...999999))
    }

    // MARK: - Authentication

    /// Verify an `AuthResponse` carrying an HMAC of the challenge the Mac just sent.
    /// Valid HMAC + known phoneDeviceID → success. Unknown phones must go through
    /// `verifyPIN` first — they cannot join via `authenticate`.
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

        guard let existingIndex = pairedDevices.firstIndex(where: { $0.id == phoneDeviceID }) else {
            logger.warning("Auth rejected: unknown phone \(phoneDeviceID)")
            return AuthResult(
                success: false,
                reason: "This iPhone isn't paired with this Mac. Open Settings on the Mac to start pairing.",
                macDisplayName: macDisplayName
            )
        }

        pairedDevices[existingIndex].lastSeenAt = Date()
        pairedDevices[existingIndex].displayName = phoneDisplayName
        persistPairedDevices()
        logger.info("Auth success for known phone \(phoneDeviceID)")
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
    /// evicted because their old HMACs won't verify any more. User-invoked only.
    func resetPairingToken() async {
        let fresh = Self.randomBytes(32)
        try? await KeychainService.shared.storeData(fresh, forKey: Self.pairingTokenKey)
        pairingTokenData = fresh
        unpairAll()
        logger.info("Pairing token reset")
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
