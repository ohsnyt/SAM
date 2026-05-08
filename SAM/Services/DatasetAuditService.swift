//
//  DatasetAuditService.swift
//  SAM
//
//  Phase 0a — Dataset Audit.
//
//  Walks every SwiftData model in the SAM store, captures row counts,
//  weekly creation histograms, per-source breakdown for evidence, and
//  on-disk file sizes (audio, store, pre-open backups). Emits a single
//  JSON document the user can save and email back so we can model her
//  steady-state growth and project 1y / 3y / 5y data volumes.
//
//  This is a one-shot diagnostic. It runs on demand from
//  Settings → Diagnostics → Dataset Audit.
//

import Foundation
import SwiftData
import os.log

// MARK: - Report shape

struct DatasetAuditReport: Codable, Sendable {
    let schemaVersion: String
    let generatedAt: Date
    let models: [ModelAudit]
    let evidenceBySource: [String: Int]
    let files: FileSizes

    struct ModelAudit: Codable, Sendable {
        let name: String
        let rowCount: Int
        /// Field used for the weekly bucket (e.g., "createdAt", "occurredAt", "(none)").
        let histogramSource: String
        /// ISO-week key ("YYYY-Www") → row count. Rows with nil timestamp counted under "(unknown)".
        let weekly: [String: Int]
    }

    struct FileSizes: Codable, Sendable {
        /// SQLite store + -wal + -shm.
        let storeBytes: Int64
        let storePath: String
        /// MeetingAudio/*.wav.
        let audioBytes: Int64
        let audioFileCount: Int
        let audioPath: String
        /// SAM-PreOpenBackups/*.
        let preOpenBackupBytes: Int64
        let preOpenBackupCount: Int
        /// Whole Application Support/SAM tree.
        let applicationSupportBytes: Int64
    }
}

// MARK: - Service

@MainActor
final class DatasetAuditService {

    static let shared = DatasetAuditService()
    private init() {}

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DatasetAudit")

    // MARK: Entry point

    func generateReport() throws -> DatasetAuditReport {
        let context = SAMModelContainer.newContext()

        var models: [DatasetAuditReport.ModelAudit] = []
        models.reserveCapacity(64)

        // Each helper returns (rowCount, weekly, source-label).
        models.append(audit(context, name: "SamPerson") { (p: SamPerson) -> Date? in p.lifecycleChangedAt }
            .renamed(source: "lifecycleChangedAt"))
        models.append(audit(context, name: "SamContext") { (_: SamContext) -> Date? in nil }
            .renamed(source: "(none)"))
        models.append(audit(context, name: "ContextParticipation") { (x: ContextParticipation) -> Date? in x.startDate }
            .renamed(source: "startDate"))
        models.append(audit(context, name: "Responsibility") { (x: Responsibility) -> Date? in x.startDate }
            .renamed(source: "startDate"))
        models.append(audit(context, name: "JointInterest") { (x: JointInterest) -> Date? in x.startDate }
            .renamed(source: "startDate"))
        models.append(audit(context, name: "ConsentRequirement") { (x: ConsentRequirement) -> Date? in x.requestedAt }
            .renamed(source: "requestedAt"))
        models.append(audit(context, name: "Product") { (x: Product) -> Date? in x.issuedDate }
            .renamed(source: "issuedDate"))
        models.append(audit(context, name: "Coverage") { (_: Coverage) -> Date? in nil }
            .renamed(source: "(none)"))
        models.append(audit(context, name: "SamEvidenceItem") { (x: SamEvidenceItem) -> Date? in x.occurredAt }
            .renamed(source: "occurredAt"))
        models.append(audit(context, name: "SamInsight") { (x: SamInsight) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "SamNote") { (x: SamNote) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "SamAnalysisArtifact") { (x: SamAnalysisArtifact) -> Date? in x.analyzedAt }
            .renamed(source: "analyzedAt"))
        models.append(audit(context, name: "UnknownSender") { (x: UnknownSender) -> Date? in x.firstSeenAt }
            .renamed(source: "firstSeenAt"))
        models.append(audit(context, name: "SamOutcome") { (x: SamOutcome) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "CoachingProfile") { (x: CoachingProfile) -> Date? in x.updatedAt }
            .renamed(source: "updatedAt"))
        models.append(audit(context, name: "NoteImage") { (x: NoteImage) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "SamDailyBriefing") { (x: SamDailyBriefing) -> Date? in x.generatedAt }
            .renamed(source: "generatedAt"))
        models.append(audit(context, name: "SamUndoEntry") { (x: SamUndoEntry) -> Date? in x.capturedAt }
            .renamed(source: "capturedAt"))
        models.append(audit(context, name: "TimeEntry") { (x: TimeEntry) -> Date? in x.startedAt }
            .renamed(source: "startedAt"))
        models.append(audit(context, name: "StageTransition") { (x: StageTransition) -> Date? in x.transitionDate }
            .renamed(source: "transitionDate"))
        models.append(audit(context, name: "RecruitingStage") { (x: RecruitingStage) -> Date? in x.enteredDate }
            .renamed(source: "enteredDate"))
        models.append(audit(context, name: "ProductionRecord") { (x: ProductionRecord) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "StrategicDigest") { (x: StrategicDigest) -> Date? in x.generatedAt }
            .renamed(source: "generatedAt"))
        models.append(audit(context, name: "ContentPost") { (x: ContentPost) -> Date? in x.postedAt }
            .renamed(source: "postedAt"))
        models.append(audit(context, name: "BusinessGoal") { (x: BusinessGoal) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "ComplianceAuditEntry") { (x: ComplianceAuditEntry) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "DeducedRelation") { (x: DeducedRelation) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "PendingEnrichment") { (x: PendingEnrichment) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "IntentionalTouch") { (x: IntentionalTouch) -> Date? in x.date }
            .renamed(source: "date"))
        models.append(audit(context, name: "LinkedInImport") { (x: LinkedInImport) -> Date? in x.importDate }
            .renamed(source: "importDate"))
        models.append(audit(context, name: "NotificationTypeTracker") { (x: NotificationTypeTracker) -> Date? in x.firstSeenDate }
            .renamed(source: "firstSeenDate"))
        models.append(audit(context, name: "ProfileAnalysisRecord") { (x: ProfileAnalysisRecord) -> Date? in x.analysisDate }
            .renamed(source: "analysisDate"))
        models.append(audit(context, name: "EngagementSnapshot") { (x: EngagementSnapshot) -> Date? in x.periodEnd }
            .renamed(source: "periodEnd"))
        models.append(audit(context, name: "SocialProfileSnapshot") { (x: SocialProfileSnapshot) -> Date? in x.importDate }
            .renamed(source: "importDate"))
        models.append(audit(context, name: "FacebookImport") { (x: FacebookImport) -> Date? in x.importDate }
            .renamed(source: "importDate"))
        models.append(audit(context, name: "SubstackImport") { (x: SubstackImport) -> Date? in x.importDate }
            .renamed(source: "importDate"))
        models.append(audit(context, name: "SamEvent") { (x: SamEvent) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "EventParticipation") { (x: EventParticipation) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "SamPresentation") { (x: SamPresentation) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "RoleDefinition") { (x: RoleDefinition) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "RoleCandidate") { (x: RoleCandidate) -> Date? in x.identifiedAt }
            .renamed(source: "identifiedAt"))
        models.append(audit(context, name: "GoalJournalEntry") { (x: GoalJournalEntry) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "EventEvaluation") { (x: EventEvaluation) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "SamTrip") { (x: SamTrip) -> Date? in x.date }
            .renamed(source: "date"))
        models.append(audit(context, name: "SamTripStop") { (x: SamTripStop) -> Date? in x.arrivedAt }
            .renamed(source: "arrivedAt"))
        models.append(audit(context, name: "SamSavedAddress") { (x: SamSavedAddress) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))
        models.append(audit(context, name: "TranscriptSession") { (x: TranscriptSession) -> Date? in x.recordedAt }
            .renamed(source: "recordedAt"))
        models.append(audit(context, name: "TranscriptSegment") { (_: TranscriptSegment) -> Date? in nil }
            .renamed(source: "(offset only)"))
        models.append(audit(context, name: "SpeakerProfile") { (x: SpeakerProfile) -> Date? in x.enrolledAt }
            .renamed(source: "enrolledAt"))
        models.append(audit(context, name: "PendingUpload") { (x: PendingUpload) -> Date? in x.recordedAt }
            .renamed(source: "recordedAt"))
        models.append(audit(context, name: "ProcessedSessionTombstone") { (x: ProcessedSessionTombstone) -> Date? in x.deletedAt }
            .renamed(source: "deletedAt"))
        models.append(audit(context, name: "SamCommitment") { (x: SamCommitment) -> Date? in x.createdAt }
            .renamed(source: "createdAt"))

        // Per-source breakdown for SamEvidenceItem (the heaviest grower).
        let evidenceBySource = (try? context.fetch(FetchDescriptor<SamEvidenceItem>()))
            .map { items -> [String: Int] in
                var result: [String: Int] = [:]
                for item in items {
                    result[item.source.rawValue, default: 0] += 1
                }
                return result
            } ?? [:]

        let files = measureFiles()

        return DatasetAuditReport(
            schemaVersion: SAMModelContainer.schemaVersion,
            generatedAt: Date(),
            models: models.sorted { $0.rowCount > $1.rowCount },
            evidenceBySource: evidenceBySource,
            files: files
        )
    }

    func reportJSON() throws -> Data {
        let report = try generateReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    // MARK: Audit helper

    private func audit<T: PersistentModel>(
        _ context: ModelContext,
        name: String,
        date: (T) -> Date?
    ) -> DatasetAuditReport.ModelAudit {
        let descriptor = FetchDescriptor<T>()
        do {
            let items = try context.fetch(descriptor)
            var weekly: [String: Int] = [:]
            for item in items {
                if let d = date(item) {
                    weekly[Self.weekKey(for: d), default: 0] += 1
                } else {
                    weekly["(unknown)", default: 0] += 1
                }
            }
            return DatasetAuditReport.ModelAudit(
                name: name,
                rowCount: items.count,
                histogramSource: "",  // Filled in via .renamed(source:)
                weekly: weekly
            )
        } catch {
            logger.error("Audit fetch failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return DatasetAuditReport.ModelAudit(
                name: name,
                rowCount: -1,
                histogramSource: "(fetch error)",
                weekly: [:]
            )
        }
    }

    private static func weekKey(for date: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
    }

    // MARK: File sizes

    private func measureFiles() -> DatasetAuditReport.FileSizes {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        // Store + WAL + SHM.
        let storeURL = SAMModelContainer.defaultStoreURL
        var storeBytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = storeURL.path + suffix
            storeBytes += fileSize(atPath: path)
        }

        // MeetingAudio dir.
        let audioDir = appSupport.appendingPathComponent("MeetingAudio", isDirectory: true)
        let (audioBytes, audioCount) = directorySize(at: audioDir)

        // Pre-open backup snapshots.
        let backupDir = appSupport.appendingPathComponent("SAM-PreOpenBackups", isDirectory: true)
        let (backupBytes, backupCount) = directorySize(at: backupDir)

        // Whole SAM application support tree (best-effort — Sandbox group container).
        let samRoot = appSupport // App's own support root; broad enough for our v1 audit.
        let (totalAppSupportBytes, _) = directorySize(at: samRoot)

        return DatasetAuditReport.FileSizes(
            storeBytes: storeBytes,
            storePath: storeURL.path,
            audioBytes: audioBytes,
            audioFileCount: audioCount,
            audioPath: audioDir.path,
            preOpenBackupBytes: backupBytes,
            preOpenBackupCount: backupCount,
            applicationSupportBytes: totalAppSupportBytes
        )
    }

    private func fileSize(atPath path: String) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private func directorySize(at url: URL) -> (bytes: Int64, fileCount: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (0, 0) }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var total: Int64 = 0
        var count = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
            count += 1
        }
        return (total, count)
    }
}

// MARK: - Builder helper

private extension DatasetAuditReport.ModelAudit {
    func renamed(source: String) -> DatasetAuditReport.ModelAudit {
        DatasetAuditReport.ModelAudit(
            name: name,
            rowCount: rowCount,
            histogramSource: source,
            weekly: weekly
        )
    }
}
