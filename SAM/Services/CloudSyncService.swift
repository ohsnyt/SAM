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
//
//  Mac writes, phone reads. Both devices share the same iCloud account.
//

import Foundation
import CloudKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CloudSyncService")

@MainActor
@Observable
final class CloudSyncService {

    static let shared = CloudSyncService()

    private let container = CKContainer(identifier: "iCloud.sam.SAM")
    private var database: CKDatabase { container.privateCloudDatabase }

    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?

    private init() {}

    // MARK: - Record Types

    static let briefingRecordType = "SAMBriefing"
    static let settingsRecordType = "SAMWorkspaceSettings"

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
    func pushBriefing(briefingJSON: String) async {
        let record = CKRecord(
            recordType: Self.briefingRecordType,
            recordID: Self.briefingRecordID
        )
        record["content"] = briefingJSON as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        do {
            let saved = try await database.save(record)
            lastSyncDate = Date()
            syncError = nil
            logger.info("Briefing pushed to CloudKit (\(briefingJSON.count) chars)")
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Record already exists — fetch and update
            do {
                let existing = try await database.record(for: Self.briefingRecordID)
                existing["content"] = briefingJSON as CKRecordValue
                existing["updatedAt"] = Date() as CKRecordValue
                try await database.save(existing)
                lastSyncDate = Date()
                syncError = nil
                logger.info("Briefing updated in CloudKit")
            } catch {
                syncError = error.localizedDescription
                logger.error("Briefing CloudKit update failed: \(error.localizedDescription)")
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
            try await database.save(record)
            lastSyncDate = Date()
            logger.info("Workspace settings pushed to CloudKit")
        } catch let error as CKError where error.code == .serverRecordChanged {
            do {
                let existing = try await database.record(for: Self.settingsRecordID)
                if let data = settings.toWireData() {
                    existing["settingsJSON"] = String(data: data, encoding: .utf8) as? CKRecordValue
                }
                existing["updatedAt"] = Date() as CKRecordValue
                try await database.save(existing)
                lastSyncDate = Date()
                logger.info("Workspace settings updated in CloudKit")
            } catch {
                logger.error("Settings CloudKit update failed: \(error.localizedDescription)")
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
