//
//  BackupPayload.swift
//  SAM_crm
//
//  The JSON envelope that gets encrypted into a .sam-backup file.
//  Contains a snapshot of all three runtime stores plus metadata so we
//  can version the format and reject incompatible files on restore.
//

import Foundation

/// Top-level container for a SAM backup.
/// Version is bumped whenever the shape of any nested model changes in a
/// way that would break decoding.  The restore path checks this before
/// attempting to deserialise the inner arrays.
struct BackupPayload: Codable {

    /// Format version.  Currently 1.
    let version: Int

    /// Human-readable creation timestamp (for the user's benefit in Finder).
    /// The source of truth for ordering is the ISO string below.
    let createdAt: String            // ISO 8601

    // MARK: - Store snapshots

    let evidence: [EvidenceItem]
    let people:   [PersonDetailModel]
    let contexts: [ContextDetailModel]

    // MARK: - Factory

    /// Snapshot the live stores right now.
    @MainActor
    static func current() -> BackupPayload {
        let evidenceStore = MockEvidenceRuntimeStore.shared
        let peopleStore   = MockPeopleRuntimeStore.shared
        let contextStore  = MockContextRuntimeStore.shared

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return BackupPayload(
            version:   BackupPayload.currentVersion,
            createdAt: iso.string(from: .now),
            evidence:  evidenceStore.items,
            people:    peopleStore.all,
            contexts:  contextStore.all
        )
    }

    /// Overwrite the live stores with the contents of this payload.
    /// Called on the main actor after a successful decrypt + decode.
    @MainActor
    func restore() {
        MockEvidenceRuntimeStore.shared.replaceAll(with: evidence)
        MockPeopleRuntimeStore.shared.replaceAll(with: people)
        MockContextRuntimeStore.shared.replaceAll(with: contexts)
    }

    // MARK: - Constants

    static let currentVersion = 1
}
