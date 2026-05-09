//
//  CloudSyncService.swift
//  SAM
//
//  CloudKit-based sync for data that the phone needs anywhere,
//  not just on the local network. Uses the private database in
//  the iCloud.sam.SAM container.
//
//  Synced record types:
//    - SAMBriefing: daily briefing content
//    - SAMWorkspaceSettings: calendar/contact group configuration
//    - SAMPairingToken: per-Mac HMAC pairing secret for the audio stream
//
//  Mac writes, phone reads. Both devices share the same iCloud account,
//  so the private DB is itself the trust boundary — no PIN/QR/handshake UX.
//

import Foundation
import CloudKit
import os.log

@MainActor
@Observable
final class CloudSyncService {

    static let shared = CloudSyncService()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CloudSyncService")

    private let container = CKContainer(identifier: "iCloud.sam.SAM")
    private var database: CKDatabase { container.privateCloudDatabase }

    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?

    private init() {}

    // MARK: - Record Types

    static let briefingRecordType = "SAMBriefing"
    static let settingsRecordType = "SAMWorkspaceSettings"
    static let pairingTokenRecordType = "SAMPairingToken"

    // Use a fixed record ID so we always overwrite the same record
    // (there's only one briefing and one settings record per user).
    private static let briefingRecordID = CKRecord.ID(
        recordName: "currentBriefing",
        zoneID: .default
    )
    private static let settingsRecordID = CKRecord.ID(
        recordName: "workspaceSettings",
        zoneID: .default
    )

    // MARK: - Push Briefing (Mac → iCloud)

    /// Save the current daily briefing to CloudKit so the phone can read it.
    ///
    /// Uses `.allKeys` save policy: the briefing is a single record we always
    /// want to replace whole, so there's no value in CloudKit's default
    /// `.ifServerRecordUnchanged` change-tag check. The earlier fetch-mutate-
    /// save fallback was also vulnerable to "client oplock error" when the
    /// phone or another push raced with our fetch — `.allKeys` removes the
    /// race entirely.
    func pushBriefing(briefingJSON: String) async {
        let record = CKRecord(
            recordType: Self.briefingRecordType,
            recordID: Self.briefingRecordID
        )
        record["content"] = briefingJSON as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            switch saveResults[Self.briefingRecordID] {
            case .success:
                lastSyncDate = Date()
                syncError = nil
                logger.info("Briefing pushed to CloudKit (\(briefingJSON.count) chars)")
            case .failure(let error):
                syncError = error.localizedDescription
                logger.error("Briefing CloudKit save failed: \(error.localizedDescription)")
            case .none:
                logger.error("Briefing CloudKit save returned no result for record")
            }
        } catch {
            syncError = error.localizedDescription
            logger.error("Briefing CloudKit push failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Push Workspace Settings (Mac → iCloud)

    /// Save workspace settings to CloudKit so the phone can read them offline.
    func pushWorkspaceSettings(_ settings: WorkspaceSettings) async {
        let record = CKRecord(
            recordType: Self.settingsRecordType,
            recordID: Self.settingsRecordID
        )
        if let data = settings.toWireData() {
            record["settingsJSON"] = String(data: data, encoding: .utf8) as? CKRecordValue
        }
        record["updatedAt"] = Date() as CKRecordValue

        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .allKeys,
                atomically: true
            )
            switch saveResults[Self.settingsRecordID] {
            case .success:
                lastSyncDate = Date()
                logger.info("Workspace settings pushed to CloudKit")
            case .failure(let error):
                logger.error("Settings CloudKit save failed: \(error.localizedDescription)")
            case .none:
                logger.error("Settings CloudKit save returned no result for record")
            }
        } catch {
            logger.error("Settings CloudKit push failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch Briefing (Phone ← iCloud)

    /// Fetch the latest briefing from CloudKit. Returns the JSON string or nil.
    func fetchBriefing() async -> String? {
        do {
            let record = try await database.record(for: Self.briefingRecordID)
            lastSyncDate = Date()
            return record["content"] as? String
        } catch {
            logger.debug("No briefing in CloudKit (or fetch failed): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Push Pairing Token (Mac → iCloud)

    /// Write this Mac's HMAC pairing token to CloudKit so any phone on the
    /// same iCloud account can pick it up automatically. One record per Mac,
    /// keyed by macDeviceID.
    func pushPairingToken(macDeviceID: UUID, macDisplayName: String, tokenData: Data) async {
        let recordID = Self.pairingTokenRecordID(for: macDeviceID)
        let record = CKRecord(recordType: Self.pairingTokenRecordType, recordID: recordID)
        record["macDeviceID"] = macDeviceID.uuidString as CKRecordValue
        record["macDisplayName"] = macDisplayName as CKRecordValue
        record["tokenB64"] = tokenData.base64EncodedString() as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        do {
            _ = try await database.save(record)
            lastSyncDate = Date()
            syncError = nil
            logger.info("Pairing token pushed to CloudKit (\(macDeviceID.uuidString))")
        } catch let error as CKError where error.code == .serverRecordChanged {
            do {
                let existing = try await database.record(for: recordID)
                existing["macDeviceID"] = macDeviceID.uuidString as CKRecordValue
                existing["macDisplayName"] = macDisplayName as CKRecordValue
                existing["tokenB64"] = tokenData.base64EncodedString() as CKRecordValue
                existing["updatedAt"] = Date() as CKRecordValue
                try await database.save(existing)
                lastSyncDate = Date()
                syncError = nil
                logger.info("Pairing token updated in CloudKit (\(macDeviceID.uuidString))")
            } catch {
                syncError = error.localizedDescription
                logger.error("Pairing token CloudKit update failed: \(error.localizedDescription)")
            }
        } catch {
            syncError = error.localizedDescription
            logger.error("Pairing token CloudKit push failed: \(error.localizedDescription)")
        }
    }

    /// Delete this Mac's pairing token from CloudKit. Phones will lose access
    /// on next fetch until a new token is pushed.
    func deletePairingToken(macDeviceID: UUID) async {
        let recordID = Self.pairingTokenRecordID(for: macDeviceID)
        do {
            _ = try await database.deleteRecord(withID: recordID)
            logger.info("Pairing token deleted from CloudKit (\(macDeviceID.uuidString))")
        } catch {
            logger.error("Pairing token CloudKit delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch Pairing Tokens (Phone ← iCloud)

    /// Fetch all pairing-token records the signed-in iCloud user has. The phone
    /// uses this on launch to learn which Macs it can talk to without any
    /// pairing UX.
    func fetchPairingTokens() async -> [(macDeviceID: UUID, macDisplayName: String, tokenData: Data)] {
        let query = CKQuery(recordType: Self.pairingTokenRecordType, predicate: NSPredicate(value: true))
        do {
            let (matchResults, _) = try await database.records(matching: query)
            var results: [(UUID, String, Data)] = []
            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    guard let idString = record["macDeviceID"] as? String,
                          let id = UUID(uuidString: idString),
                          let name = record["macDisplayName"] as? String,
                          let tokenB64 = record["tokenB64"] as? String,
                          let tokenData = Data(base64Encoded: tokenB64) else {
                        continue
                    }
                    results.append((id, name, tokenData))
                case .failure(let error):
                    logger.error("Pairing token record decode failed: \(error.localizedDescription)")
                }
            }
            lastSyncDate = Date()
            logger.info("Fetched \(results.count) pairing token(s) from CloudKit")
            return results
        } catch {
            logger.debug("No pairing tokens in CloudKit (or fetch failed): \(error.localizedDescription)")
            return []
        }
    }

    private static func pairingTokenRecordID(for macDeviceID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "pairingToken-\(macDeviceID.uuidString)", zoneID: .default)
    }

    // MARK: - Fetch Workspace Settings (Phone ← iCloud)

    /// Fetch workspace settings from CloudKit and cache locally.
    func fetchAndCacheWorkspaceSettings() async -> WorkspaceSettings? {
        do {
            let record = try await database.record(for: Self.settingsRecordID)
            guard let jsonString = record["settingsJSON"] as? String,
                  let data = jsonString.data(using: .utf8),
                  let settings = try? JSONDecoder().decode(WorkspaceSettings.self, from: data) else {
                return nil
            }
            settings.cache()
            lastSyncDate = Date()
            logger.info("Workspace settings fetched from CloudKit and cached")
            return settings
        } catch {
            logger.debug("No settings in CloudKit: \(error.localizedDescription)")
            return nil
        }
    }
}
