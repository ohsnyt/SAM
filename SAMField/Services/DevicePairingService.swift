//
//  DevicePairingService.swift
//  SAM Field
//
//  iPhone half of the pairing handshake. Stores the user's `phoneDeviceID`
//  (generated once) and a list of Macs this phone has been paired with —
//  each entry carries the Mac's pairing token (32 bytes) so we can answer
//  the Mac's authChallenge without ever sending the token over the network.
//
//  Trust source: CloudKit private DB. Every SAM device belongs to the same
//  iCloud account, so on bootstrap we read all `SAMPairingToken` records
//  the user has and adopt them silently — no PIN entry, no QR scan.
//  Tokens are cached in Keychain (`kSecAttrAccessibleWhenUnlockedThisDevice
//  Only`) so we don't re-hit CloudKit on every cold start, and so we still
//  work with no network as long as we've fetched once before.
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

    /// Trusted Macs. Hydrated from Keychain on bootstrap, then refreshed from
    /// CloudKit so newly-added Macs on the same iCloud account appear without
    /// any user action.
    private(set) var trustedMacs: [TrustedMacRecord] = []

    private var isBootstrapped = false

    private static let phoneDeviceIDKey = "samfield.pairing.phoneDeviceID"
    private static let trustedMacsIndexKey = "samfield.pairing.trustedMacsIndex"
    private static func tokenKey(for macDeviceID: UUID) -> String {
        "samfield.pairing.token.\(macDeviceID.uuidString)"
    }

    // MARK: - Bootstrap

    /// Idempotent. Loads persisted identity + every trusted Mac's pairing
    /// token from Keychain, then fetches new/updated tokens from CloudKit.
    /// MUST be awaited before AudioStreamingService tries to authenticate.
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

        // Hydrate trusted Macs from Keychain first so we work offline.
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
        logger.debug("Bootstrap (local) complete: phoneID=\(self.phoneDeviceID), trusted Macs=\(self.trustedMacs.count)")

        // Refresh from CloudKit in the background. New Macs on the same
        // iCloud account get adopted without UX. Updated tokens (e.g., after
        // a Reset on the Mac) overwrite the stale keychain entry.
        await refreshFromCloudKit()
    }

    /// Pull all `SAMPairingToken` records the iCloud user has and merge them
    /// into `trustedMacs`. Safe to call any time — call sites typically just
    /// rely on the implicit refresh during `bootstrap()`.
    func refreshFromCloudKit() async {
        let tokens = await CloudSyncService.shared.fetchPairingTokens()
        guard !tokens.isEmpty else {
            logger.debug("CloudKit returned no pairing tokens (yet)")
            return
        }
        for (macID, name, tokenData) in tokens {
            guard tokenData.count == 32 else {
                logger.warning("Skipping CloudKit token for \(macID): wrong length \(tokenData.count)")
                continue
            }
            let existing = trustedMacs.firstIndex { $0.macDeviceID == macID }
            if let i = existing {
                if trustedMacs[i].pairingToken != tokenData {
                    try? await KeychainService.shared.storeData(tokenData, forKey: Self.tokenKey(for: macID))
                    trustedMacs[i].pairingToken = tokenData
                    trustedMacs[i].macDisplayName = name
                    logger.info("Refreshed pairing token for Mac \(macID)")
                } else if trustedMacs[i].macDisplayName != name {
                    trustedMacs[i].macDisplayName = name
                }
            } else {
                try? await KeychainService.shared.storeData(tokenData, forKey: Self.tokenKey(for: macID))
                let record = TrustedMacRecord(
                    macDeviceID: macID,
                    macDisplayName: name,
                    pairedAt: Date(),
                    pairingToken: tokenData
                )
                trustedMacs.append(record)
                logger.info("Adopted new Mac \(macID) (\(name, privacy: .private)) from CloudKit")
            }
        }
        persistIndex()
    }

    // MARK: - Pairing

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
    /// (i.e., a stranger's Mac somehow advertised on the network).
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
