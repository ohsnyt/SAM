//
//  BackupCoordinator.swift
//  SAM
//
//  Export/import coordinator for SAM backup files.
//  Exports core data + preferences to .sambackup JSON;
//  imports by replacing all data and triggering onboarding.
//

import SwiftData
import Foundation
import os

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "BackupCoordinator")

// ─────────────────────────────────────────────────────────────────────
// MARK: - Status
// ─────────────────────────────────────────────────────────────────────

enum BackupStatus: Equatable {
    case idle
    case exporting
    case importing
    case validating
    case success(String)
    case failed(String)
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Coordinator
// ─────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class BackupCoordinator {
    static let shared = BackupCoordinator()

    var status: BackupStatus = .idle
    var progress: String = ""
    var pendingImport: (url: URL, preview: ImportPreview)?

    private init() {}

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Preference Keys
    // ─────────────────────────────────────────────────────────────────

    /// Keys included in backup (portable preferences).
    private static let includedPreferenceKeys: [String] = [
        "aiBackend", "coachingStyle", "outcomeAutoGenerate",
        "contentSuggestionsEnabled", "directSendEnabled",
        "strategicDigestEnabled", "strategicBriefingIntegration",
        "autoMeetingNoteTemplates", "autoRoleTransitionOutcomes", "weeklyDigestEnabled",
        "complianceCheckingEnabled", "complianceCat_guarantees", "complianceCat_returns",
        "complianceCat_promises", "complianceCat_comparativeClaims",
        "complianceCat_suitability", "complianceCat_specificAdvice",
        "complianceCustomKeywords", "complianceAuditRetentionDays",
        "briefingMorningEnabled", "briefingEveningEnabled",
        "briefingEveningHour", "briefingEveningMinute", "briefingNarrativeEnabled",
        "sam.dictation.silenceTimeout",
        "sam.ai.notePrompt", "sam.ai.emailPrompt", "sam.ai.messagePrompt",
        "sam.contacts.enabled", "calendarAutoImportEnabled",
        "mailImportEnabled", "commsMessagesEnabled", "commsCallsEnabled",
        "commsAnalyzeMessages", "commsLookbackDays", "mailLookbackDays",
        "mailImportInterval", "calendarImportIntervalSeconds",
        "insightAutoGenerateEnabled", "insightDaysSinceContactThreshold",
        "autoResetOnVersionChange", "autoDetectPermissionLoss", "pipelineBackfillComplete",
        "calendarLookbackDays",
    ]

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Export
    // ─────────────────────────────────────────────────────────────────

    func exportBackup(to url: URL) async {
        status = .exporting
        progress = "Fetching data..."
        logger.info("Export started")

        do {
            let context = ModelContext(SAMModelContainer.shared)

            // Fetch all 20 model types
            progress = "Reading people..."
            let people = try context.fetch(FetchDescriptor<SamPerson>())

            progress = "Reading contexts..."
            let contexts = try context.fetch(FetchDescriptor<SamContext>())

            progress = "Reading participations..."
            let participations = try context.fetch(FetchDescriptor<ContextParticipation>())

            progress = "Reading responsibilities..."
            let responsibilities = try context.fetch(FetchDescriptor<Responsibility>())

            progress = "Reading joint interests..."
            let jointInterests = try context.fetch(FetchDescriptor<JointInterest>())

            progress = "Reading consent requirements..."
            let consents = try context.fetch(FetchDescriptor<ConsentRequirement>())

            progress = "Reading products..."
            let products = try context.fetch(FetchDescriptor<Product>())

            progress = "Reading coverages..."
            let coverages = try context.fetch(FetchDescriptor<Coverage>())

            progress = "Reading evidence..."
            let evidence = try context.fetch(FetchDescriptor<SamEvidenceItem>())

            progress = "Reading notes..."
            let notes = try context.fetch(FetchDescriptor<SamNote>())

            progress = "Reading note images..."
            let noteImages = try context.fetch(FetchDescriptor<NoteImage>())

            progress = "Reading analysis artifacts..."
            let artifacts = try context.fetch(FetchDescriptor<SamAnalysisArtifact>())

            progress = "Reading coaching profile..."
            let profiles = try context.fetch(FetchDescriptor<CoachingProfile>())

            progress = "Reading time entries..."
            let timeEntries = try context.fetch(FetchDescriptor<TimeEntry>())

            progress = "Reading stage transitions..."
            let transitions = try context.fetch(FetchDescriptor<StageTransition>())

            progress = "Reading recruiting stages..."
            let stages = try context.fetch(FetchDescriptor<RecruitingStage>())

            progress = "Reading production records..."
            let productions = try context.fetch(FetchDescriptor<ProductionRecord>())

            progress = "Reading content posts..."
            let posts = try context.fetch(FetchDescriptor<ContentPost>())

            progress = "Reading business goals..."
            let goals = try context.fetch(FetchDescriptor<BusinessGoal>())

            progress = "Reading compliance entries..."
            let audits = try context.fetch(FetchDescriptor<ComplianceAuditEntry>())

            progress = "Reading deduced relations..."
            let deducedRelations = try context.fetch(FetchDescriptor<DeducedRelation>())

            // Map to DTOs
            progress = "Building backup document..."

            let personDTOs = people.map { p in
                PersonBackup(
                    id: p.id,
                    contactIdentifier: p.contactIdentifier,
                    displayNameCache: p.displayNameCache,
                    emailCache: p.emailCache,
                    emailAliases: p.emailAliases,
                    phoneAliases: p.phoneAliases,
                    photoThumbnailBase64: p.photoThumbnailCache.map { $0.base64EncodedString() },
                    lastSyncedAt: p.lastSyncedAt,
                    isArchived: p.isArchived,
                    isMe: p.isMe,
                    relationshipSummary: p.relationshipSummary,
                    relationshipKeyThemes: p.relationshipKeyThemes,
                    relationshipNextSteps: p.relationshipNextSteps,
                    summaryUpdatedAt: p.summaryUpdatedAt,
                    inferredChannelRawValue: p.inferredChannelRawValue,
                    preferredChannelRawValue: p.preferredChannelRawValue,
                    preferredCadenceDays: p.preferredCadenceDays,
                    displayName: p.displayName,
                    email: p.email,
                    roleBadges: p.roleBadges,
                    consentAlertsCount: p.consentAlertsCount,
                    reviewAlertsCount: p.reviewAlertsCount,
                    responsibilityNotes: p.responsibilityNotes,
                    recentInteractions: p.recentInteractions,
                    contextChips: p.contextChips,
                    referredByID: p.referredBy?.id
                )
            }

            let contextDTOs = contexts.map { c in
                ContextBackup(
                    id: c.id,
                    name: c.name,
                    kind: c.kind,
                    consentAlertCount: c.consentAlertCount,
                    reviewAlertCount: c.reviewAlertCount,
                    followUpAlertCount: c.followUpAlertCount,
                    productCards: c.productCards,
                    recentInteractions: c.recentInteractions
                )
            }

            let participationDTOs = participations.map { p in
                ParticipationBackup(
                    id: p.id,
                    personID: p.person?.id,
                    contextID: p.context?.id,
                    roleBadges: p.roleBadges,
                    isPrimary: p.isPrimary,
                    note: p.note,
                    startDate: p.startDate,
                    endDate: p.endDate
                )
            }

            let responsibilityDTOs = responsibilities.map { r in
                ResponsibilityBackup(
                    id: r.id,
                    guardianID: r.guardian?.id,
                    dependentID: r.dependent?.id,
                    reason: r.reason,
                    startDate: r.startDate,
                    endDate: r.endDate
                )
            }

            let jointInterestDTOs = jointInterests.map { j in
                JointInterestBackup(
                    id: j.id,
                    partyIDs: j.parties.map(\.id),
                    type: j.type,
                    survivorshipRights: j.survivorshipRights,
                    startDate: j.startDate,
                    endDate: j.endDate,
                    notes: j.notes,
                    productIDs: j.products.map(\.id)
                )
            }

            let consentDTOs = consents.map { c in
                ConsentRequirementBackup(
                    id: c.id,
                    personID: c.person?.id,
                    contextID: nil,
                    productID: c.product?.id,
                    title: c.title,
                    reason: c.reason,
                    jurisdiction: c.jurisdiction,
                    status: c.status,
                    requestedAt: c.requestedAt,
                    satisfiedAt: c.satisfiedAt,
                    revokedAt: c.revokedAt
                )
            }

            let productDTOs = products.map { p in
                ProductBackup(
                    id: p.id,
                    contextID: p.context?.id,
                    type: p.type,
                    name: p.name,
                    subtitle: p.subtitle,
                    statusDisplay: p.statusDisplay,
                    icon: p.icon,
                    issuedDate: p.issuedDate
                )
            }

            let coverageDTOs = coverages.map { c in
                CoverageBackup(
                    id: c.id,
                    personID: c.person?.id,
                    productID: c.product?.id,
                    role: c.role,
                    survivorshipRights: c.survivorshipRights
                )
            }

            let evidenceDTOs = evidence.map { e in
                EvidenceBackup(
                    id: e.id,
                    sourceUID: e.sourceUID,
                    source: e.source,
                    stateRawValue: e.stateRawValue,
                    occurredAt: e.occurredAt,
                    endedAt: e.endedAt,
                    title: e.title,
                    snippet: e.snippet,
                    bodyText: e.bodyText,
                    signals: e.signals,
                    participantHints: e.participantHints,
                    proposedLinks: e.proposedLinks,
                    linkedPeopleIDs: e.linkedPeople.map(\.id),
                    linkedContextIDs: e.linkedContexts.map(\.id)
                )
            }

            let noteDTOs = notes.map { n in
                NoteBackup(
                    id: n.id,
                    content: n.content,
                    summary: n.summary,
                    createdAt: n.createdAt,
                    updatedAt: n.updatedAt,
                    sourceTypeRawValue: n.sourceTypeRawValue,
                    sourceImportUID: n.sourceImportUID,
                    isAnalyzed: n.isAnalyzed,
                    analysisVersion: n.analysisVersion,
                    linkedPeopleIDs: n.linkedPeople.map(\.id),
                    linkedContextIDs: n.linkedContexts.map(\.id),
                    linkedEvidenceIDs: n.linkedEvidence.map(\.id),
                    extractedMentions: n.extractedMentions,
                    extractedActionItems: n.extractedActionItems,
                    extractedTopics: n.extractedTopics,
                    discoveredRelationships: n.discoveredRelationships,
                    lifeEvents: n.lifeEvents,
                    followUpDraft: n.followUpDraft
                )
            }

            let noteImageDTOs = noteImages.map { img in
                NoteImageBackup(
                    id: img.id,
                    noteID: img.note?.id,
                    imageDataBase64: img.imageData.map { $0.base64EncodedString() },
                    mimeType: img.mimeType,
                    displayOrder: img.displayOrder,
                    textInsertionPoint: img.textInsertionPoint,
                    createdAt: img.createdAt
                )
            }

            let artifactDTOs = artifacts.map { a in
                AnalysisArtifactBackup(
                    id: a.id,
                    noteID: a.note?.id,
                    sourceType: a.sourceType,
                    analyzedAt: a.analyzedAt,
                    peopleJSON: a.peopleJSON,
                    topicsJSON: a.topicsJSON,
                    factsJSON: a.factsJSON,
                    implicationsJSON: a.implicationsJSON,
                    actions: a.actions,
                    affect: a.affect,
                    usedLLM: a.usedLLM
                )
            }

            let profileDTO = profiles.first.map { p in
                CoachingProfileBackup(
                    id: p.id,
                    encouragementStyle: p.encouragementStyle,
                    preferredOutcomeKinds: p.preferredOutcomeKinds,
                    dismissPatterns: p.dismissPatterns,
                    avgResponseTimeMinutes: p.avgResponseTimeMinutes,
                    totalActedOn: p.totalActedOn,
                    totalDismissed: p.totalDismissed,
                    totalRated: p.totalRated,
                    avgRating: p.avgRating,
                    updatedAt: p.updatedAt
                )
            }

            let timeEntryDTOs = timeEntries.map { t in
                TimeEntryBackup(
                    id: t.id,
                    categoryRawValue: t.categoryRawValue,
                    title: t.title,
                    durationMinutes: t.durationMinutes,
                    startedAt: t.startedAt,
                    endedAt: t.endedAt,
                    isManualOverride: t.isManualOverride,
                    isManualEntry: t.isManualEntry,
                    sourceEvidenceID: t.sourceEvidenceID,
                    linkedPeopleIDs: t.linkedPeopleIDs,
                    createdAt: t.createdAt
                )
            }

            let transitionDTOs = transitions.map { t in
                StageTransitionBackup(
                    id: t.id,
                    personID: t.person?.id,
                    fromStage: t.fromStage,
                    toStage: t.toStage,
                    transitionDate: t.transitionDate,
                    pipelineTypeRawValue: t.pipelineTypeRawValue,
                    notes: t.notes
                )
            }

            let stageDTOs = stages.map { s in
                RecruitingStageBackup(
                    id: s.id,
                    personID: s.person?.id,
                    stageRawValue: s.stageRawValue,
                    enteredDate: s.enteredDate,
                    mentoringLastContact: s.mentoringLastContact,
                    notes: s.notes
                )
            }

            let productionDTOs = productions.map { p in
                ProductionRecordBackup(
                    id: p.id,
                    personID: p.person?.id,
                    productTypeRawValue: p.productTypeRawValue,
                    statusRawValue: p.statusRawValue,
                    carrierName: p.carrierName,
                    annualPremium: p.annualPremium,
                    submittedDate: p.submittedDate,
                    resolvedDate: p.resolvedDate,
                    policyNumber: p.policyNumber,
                    notes: p.notes,
                    createdAt: p.createdAt,
                    updatedAt: p.updatedAt
                )
            }

            let postDTOs = posts.map { p in
                ContentPostBackup(
                    id: p.id,
                    platformRawValue: p.platformRawValue,
                    topic: p.topic,
                    postedAt: p.postedAt,
                    sourceOutcomeID: p.sourceOutcomeID,
                    createdAt: p.createdAt
                )
            }

            let goalDTOs = goals.map { g in
                BusinessGoalBackup(
                    id: g.id,
                    goalTypeRawValue: g.goalTypeRawValue,
                    title: g.title,
                    targetValue: g.targetValue,
                    startDate: g.startDate,
                    endDate: g.endDate,
                    isActive: g.isActive,
                    notes: g.notes,
                    createdAt: g.createdAt,
                    updatedAt: g.updatedAt
                )
            }

            let auditDTOs = audits.map { a in
                ComplianceAuditBackup(
                    id: a.id,
                    channelRawValue: a.channelRawValue,
                    recipientName: a.recipientName,
                    recipientAddress: a.recipientAddress,
                    originalDraft: a.originalDraft,
                    finalDraft: a.finalDraft,
                    wasModified: a.wasModified,
                    complianceFlagsJSON: a.complianceFlagsJSON,
                    outcomeID: a.outcomeID,
                    createdAt: a.createdAt,
                    sentAt: a.sentAt
                )
            }

            let deducedRelationDTOs = deducedRelations.map { r in
                DeducedRelationBackup(
                    id: r.id,
                    personAID: r.personAID,
                    personBID: r.personBID,
                    relationTypeRawValue: r.relationTypeRawValue,
                    sourceLabel: r.sourceLabel,
                    isConfirmed: r.isConfirmed,
                    createdAt: r.createdAt,
                    confirmedAt: r.confirmedAt
                )
            }

            // Gather preferences
            progress = "Gathering preferences..."
            var prefs: [String: AnyCodableValue] = [:]
            for key in Self.includedPreferenceKeys {
                if let val = AnyCodableValue.from(userDefaults: .standard, key: key) {
                    prefs[key] = val
                }
            }

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

            let document = BackupDocument(
                metadata: BackupMetadata(
                    exportDate: .now,
                    schemaVersion: "SAM_v26",
                    appVersion: appVersion,
                    buildNumber: buildNumber,
                    backupFormatVersion: 1,
                    counts: BackupCounts(
                        people: personDTOs.count,
                        notes: noteDTOs.count,
                        evidence: evidenceDTOs.count,
                        contexts: contextDTOs.count
                    )
                ),
                preferences: prefs,
                people: personDTOs,
                contexts: contextDTOs,
                participations: participationDTOs,
                responsibilities: responsibilityDTOs,
                jointInterests: jointInterestDTOs,
                consentRequirements: consentDTOs,
                products: productDTOs,
                coverages: coverageDTOs,
                evidenceItems: evidenceDTOs,
                notes: noteDTOs,
                noteImages: noteImageDTOs,
                analysisArtifacts: artifactDTOs,
                coachingProfile: profileDTO,
                timeEntries: timeEntryDTOs,
                stageTransitions: transitionDTOs,
                recruitingStages: stageDTOs,
                productionRecords: productionDTOs,
                contentPosts: postDTOs,
                businessGoals: goalDTOs,
                complianceAuditEntries: auditDTOs,
                deducedRelations: deducedRelationDTOs
            )

            // Encode
            progress = "Writing file..."
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)

            let sizeMB = Double(data.count) / 1_048_576.0
            let summary = "\(personDTOs.count) people, \(noteDTOs.count) notes, \(evidenceDTOs.count) evidence (\(String(format: "%.1f", sizeMB)) MB)"
            logger.info("Export complete: \(summary)")
            status = .success(summary)
            progress = ""

        } catch {
            logger.error("Export failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
            progress = ""
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Validate
    // ─────────────────────────────────────────────────────────────────

    func validateBackup(from url: URL) async throws -> ImportPreview {
        status = .validating
        progress = "Reading backup file..."

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(BackupDocument.self, from: data)

        guard doc.metadata.backupFormatVersion == 1 else {
            throw BackupError.unsupportedFormat(doc.metadata.backupFormatVersion)
        }

        let schemaMatch = doc.metadata.schemaVersion == "SAM_v26"
        let preview = ImportPreview(metadata: doc.metadata, schemaMatch: schemaMatch)

        status = .idle
        progress = ""
        return preview
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Import
    // ─────────────────────────────────────────────────────────────────

    func performImport(from url: URL) async {
        status = .importing
        logger.info("Import started")

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            // 1. Safety backup
            progress = "Creating safety backup..."
            let safetyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SAM-pre-import-safety.sambackup")
            await exportSafetyBackup(to: safetyURL)
            logger.info("Safety backup saved to \(safetyURL.path)")

            // 2. Decode source
            progress = "Decoding backup..."
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(BackupDocument.self, from: data)

            // 3. Delete all existing data (individual deletes to avoid
            //    CoreData batch-delete failures on MTM nullify inverses)
            progress = "Clearing existing data..."
            let context = ModelContext(SAMModelContainer.shared)

            // First, sever many-to-many relationships that cause batch delete failures
            let allEvidence = try context.fetch(FetchDescriptor<SamEvidenceItem>())
            for e in allEvidence {
                e.linkedPeople.removeAll()
                e.linkedContexts.removeAll()
                e.linkedNotes.removeAll()
            }
            let allNotes = try context.fetch(FetchDescriptor<SamNote>())
            for n in allNotes {
                n.linkedPeople.removeAll()
                n.linkedContexts.removeAll()
                n.linkedEvidence.removeAll()
            }
            let allInsights = try context.fetch(FetchDescriptor<SamInsight>())
            for i in allInsights {
                i.basedOnEvidence.removeAll()
            }
            let allJointInterests = try context.fetch(FetchDescriptor<JointInterest>())
            for j in allJointInterests {
                j.parties.removeAll()
                j.products.removeAll()
            }
            try context.save()

            // Now delete all model instances individually
            for modelType in SAMSchema.allModels {
                try deleteAll(modelType, from: context)
            }
            try context.save()
            logger.info("All existing data deleted")

            // 4. Insert in dependency order

            // ── Pass 1: Independent entities ──────────────────────────
            progress = "Importing people..."
            var personByID: [UUID: SamPerson] = [:]
            for dto in doc.people {
                let person = SamPerson(
                    id: dto.id,
                    displayName: dto.displayName,
                    roleBadges: dto.roleBadges,
                    contactIdentifier: dto.contactIdentifier,
                    email: dto.email,
                    consentAlertsCount: dto.consentAlertsCount,
                    reviewAlertsCount: dto.reviewAlertsCount,
                    isMe: dto.isMe
                )
                person.displayNameCache = dto.displayNameCache
                person.emailCache = dto.emailCache
                person.emailAliases = dto.emailAliases
                person.phoneAliases = dto.phoneAliases
                person.photoThumbnailCache = dto.photoThumbnailBase64.flatMap { Data(base64Encoded: $0) }
                person.lastSyncedAt = dto.lastSyncedAt
                person.isArchived = dto.isArchived
                person.relationshipSummary = dto.relationshipSummary
                person.relationshipKeyThemes = dto.relationshipKeyThemes
                person.relationshipNextSteps = dto.relationshipNextSteps
                person.summaryUpdatedAt = dto.summaryUpdatedAt
                person.inferredChannelRawValue = dto.inferredChannelRawValue
                person.preferredChannelRawValue = dto.preferredChannelRawValue
                person.preferredCadenceDays = dto.preferredCadenceDays
                person.responsibilityNotes = dto.responsibilityNotes
                person.recentInteractions = dto.recentInteractions
                person.contextChips = dto.contextChips
                context.insert(person)
                personByID[dto.id] = person
            }

            progress = "Importing contexts..."
            var contextByID: [UUID: SamContext] = [:]
            for dto in doc.contexts {
                let ctx = SamContext(
                    id: dto.id,
                    name: dto.name,
                    kind: dto.kind,
                    consentAlertCount: dto.consentAlertCount,
                    reviewAlertCount: dto.reviewAlertCount,
                    followUpAlertCount: dto.followUpAlertCount
                )
                ctx.productCards = dto.productCards
                ctx.recentInteractions = dto.recentInteractions
                context.insert(ctx)
                contextByID[dto.id] = ctx
            }

            if let dto = doc.coachingProfile {
                let profile = CoachingProfile(
                    id: dto.id,
                    encouragementStyle: dto.encouragementStyle,
                    preferredOutcomeKinds: dto.preferredOutcomeKinds,
                    dismissPatterns: dto.dismissPatterns,
                    avgResponseTimeMinutes: dto.avgResponseTimeMinutes,
                    totalActedOn: dto.totalActedOn,
                    totalDismissed: dto.totalDismissed,
                    totalRated: dto.totalRated,
                    avgRating: dto.avgRating,
                    updatedAt: dto.updatedAt
                )
                context.insert(profile)
            }

            for dto in doc.businessGoals {
                let goal = BusinessGoal(
                    id: dto.id,
                    goalType: GoalType(rawValue: dto.goalTypeRawValue) ?? .newClients,
                    title: dto.title,
                    targetValue: dto.targetValue,
                    startDate: dto.startDate,
                    endDate: dto.endDate,
                    isActive: dto.isActive,
                    notes: dto.notes
                )
                goal.createdAt = dto.createdAt
                goal.updatedAt = dto.updatedAt
                context.insert(goal)
            }

            for dto in doc.contentPosts {
                let post = ContentPost(
                    id: dto.id,
                    platform: ContentPlatform(rawValue: dto.platformRawValue) ?? .other,
                    topic: dto.topic,
                    postedAt: dto.postedAt,
                    sourceOutcomeID: dto.sourceOutcomeID,
                    createdAt: dto.createdAt
                )
                context.insert(post)
            }

            for dto in doc.timeEntries {
                let entry = TimeEntry(
                    id: dto.id,
                    category: TimeCategory(rawValue: dto.categoryRawValue) ?? .other,
                    title: dto.title,
                    durationMinutes: dto.durationMinutes,
                    startedAt: dto.startedAt,
                    endedAt: dto.endedAt,
                    isManualOverride: dto.isManualOverride,
                    isManualEntry: dto.isManualEntry,
                    sourceEvidenceID: dto.sourceEvidenceID,
                    linkedPeopleIDs: dto.linkedPeopleIDs,
                    createdAt: dto.createdAt
                )
                context.insert(entry)
            }

            for dto in doc.complianceAuditEntries {
                let entry = ComplianceAuditEntry(
                    channel: dto.channelRawValue,
                    recipientName: dto.recipientName,
                    recipientAddress: dto.recipientAddress,
                    originalDraft: dto.originalDraft,
                    complianceFlagsJSON: dto.complianceFlagsJSON,
                    outcomeID: dto.outcomeID
                )
                // Overwrite auto-generated fields with backup values
                entry.id = dto.id
                entry.finalDraft = dto.finalDraft
                entry.wasModified = dto.wasModified
                entry.createdAt = dto.createdAt
                entry.sentAt = dto.sentAt
                context.insert(entry)
            }

            for dto in doc.deducedRelations {
                let relation = DeducedRelation(
                    id: dto.id,
                    personAID: dto.personAID,
                    personBID: dto.personBID,
                    relationType: DeducedRelationType(rawValue: dto.relationTypeRawValue) ?? .other,
                    sourceLabel: dto.sourceLabel,
                    isConfirmed: dto.isConfirmed,
                    createdAt: dto.createdAt,
                    confirmedAt: dto.confirmedAt
                )
                context.insert(relation)
            }

            try context.save()
            logger.info("Pass 1 complete: \(doc.people.count) people, \(doc.contexts.count) contexts")

            // ── Pass 2: Entities needing people/contexts ──────────────
            progress = "Importing participations & products..."

            for dto in doc.participations {
                guard let person = dto.personID.flatMap({ personByID[$0] }),
                      let ctx = dto.contextID.flatMap({ contextByID[$0] }) else { continue }
                let p = ContextParticipation(
                    id: dto.id,
                    person: person,
                    context: ctx,
                    roleBadges: dto.roleBadges,
                    isPrimary: dto.isPrimary,
                    note: dto.note,
                    startDate: dto.startDate
                )
                p.endDate = dto.endDate
                context.insert(p)
            }

            for dto in doc.responsibilities {
                guard let guardian = dto.guardianID.flatMap({ personByID[$0] }),
                      let dependent = dto.dependentID.flatMap({ personByID[$0] }) else { continue }
                let r = Responsibility(
                    id: dto.id,
                    guardian: guardian,
                    dependent: dependent,
                    reason: dto.reason,
                    startDate: dto.startDate
                )
                r.endDate = dto.endDate
                context.insert(r)
            }

            var productByID: [UUID: Product] = [:]
            for dto in doc.products {
                let prod = Product(
                    id: dto.id,
                    type: dto.type,
                    name: dto.name,
                    statusDisplay: dto.statusDisplay,
                    icon: dto.icon,
                    subtitle: dto.subtitle,
                    context: dto.contextID.flatMap { contextByID[$0] }
                )
                prod.issuedDate = dto.issuedDate
                context.insert(prod)
                productByID[dto.id] = prod
            }

            for dto in doc.coverages {
                guard let person = dto.personID.flatMap({ personByID[$0] }),
                      let product = dto.productID.flatMap({ productByID[$0] }) else { continue }
                let c = Coverage(
                    id: dto.id,
                    person: person,
                    product: product,
                    role: dto.role,
                    survivorshipRights: dto.survivorshipRights
                )
                context.insert(c)
            }

            for dto in doc.consentRequirements {
                let c = ConsentRequirement(
                    id: dto.id,
                    title: dto.title,
                    reason: dto.reason,
                    status: dto.status,
                    jurisdiction: dto.jurisdiction,
                    person: dto.personID.flatMap { personByID[$0] },
                    product: dto.productID.flatMap { productByID[$0] },
                    requestedAt: dto.requestedAt
                )
                c.satisfiedAt = dto.satisfiedAt
                c.revokedAt = dto.revokedAt
                context.insert(c)
            }

            for dto in doc.jointInterests {
                let parties = dto.partyIDs.compactMap { personByID[$0] }
                let j = JointInterest(
                    id: dto.id,
                    parties: parties,
                    type: dto.type,
                    survivorshipRights: dto.survivorshipRights,
                    startDate: dto.startDate
                )
                j.endDate = dto.endDate
                j.notes = dto.notes
                j.products = dto.productIDs.compactMap { productByID[$0] }
                context.insert(j)
            }

            for dto in doc.stageTransitions {
                let t = StageTransition(
                    id: dto.id,
                    person: dto.personID.flatMap { personByID[$0] },
                    fromStage: dto.fromStage,
                    toStage: dto.toStage,
                    transitionDate: dto.transitionDate,
                    pipelineType: PipelineType(rawValue: dto.pipelineTypeRawValue) ?? .client,
                    notes: dto.notes
                )
                context.insert(t)
            }

            for dto in doc.recruitingStages {
                let s = RecruitingStage(
                    id: dto.id,
                    person: dto.personID.flatMap { personByID[$0] },
                    stage: RecruitingStageKind(rawValue: dto.stageRawValue) ?? .prospect,
                    enteredDate: dto.enteredDate,
                    mentoringLastContact: dto.mentoringLastContact,
                    notes: dto.notes
                )
                context.insert(s)
            }

            for dto in doc.productionRecords {
                let p = ProductionRecord(
                    id: dto.id,
                    person: dto.personID.flatMap { personByID[$0] },
                    productType: WFGProductType(rawValue: dto.productTypeRawValue) ?? .other,
                    status: ProductionStatus(rawValue: dto.statusRawValue) ?? .submitted,
                    carrierName: dto.carrierName,
                    annualPremium: dto.annualPremium,
                    submittedDate: dto.submittedDate,
                    resolvedDate: dto.resolvedDate,
                    policyNumber: dto.policyNumber,
                    notes: dto.notes
                )
                p.createdAt = dto.createdAt
                p.updatedAt = dto.updatedAt
                context.insert(p)
            }

            try context.save()
            logger.info("Pass 2 complete: products, participations, coverages, etc.")

            // ── Pass 3: Cross-referencing entities ────────────────────
            progress = "Importing evidence & notes..."

            var evidenceByID: [UUID: SamEvidenceItem] = [:]
            for dto in doc.evidenceItems {
                let e = SamEvidenceItem(
                    id: dto.id,
                    state: EvidenceTriageState(rawValue: dto.stateRawValue) ?? .needsReview,
                    sourceUID: dto.sourceUID,
                    source: dto.source,
                    occurredAt: dto.occurredAt,
                    endedAt: dto.endedAt,
                    title: dto.title,
                    snippet: dto.snippet,
                    bodyText: dto.bodyText,
                    participantHints: dto.participantHints,
                    signals: dto.signals,
                    proposedLinks: dto.proposedLinks
                )
                // Wire relationships
                for pid in dto.linkedPeopleIDs {
                    if let person = personByID[pid] {
                        e.linkedPeople.append(person)
                    }
                }
                for cid in dto.linkedContextIDs {
                    if let ctx = contextByID[cid] {
                        e.linkedContexts.append(ctx)
                    }
                }
                context.insert(e)
                evidenceByID[dto.id] = e
            }

            var noteByID: [UUID: SamNote] = [:]
            for dto in doc.notes {
                let n = SamNote(
                    id: dto.id,
                    content: dto.content,
                    summary: dto.summary,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    isAnalyzed: dto.isAnalyzed,
                    analysisVersion: dto.analysisVersion,
                    sourceType: SamNote.SourceType(rawValue: dto.sourceTypeRawValue) ?? .typed,
                    sourceImportUID: dto.sourceImportUID
                )
                n.extractedMentions = dto.extractedMentions
                n.extractedActionItems = dto.extractedActionItems
                n.extractedTopics = dto.extractedTopics
                n.discoveredRelationships = dto.discoveredRelationships
                n.lifeEvents = dto.lifeEvents
                n.followUpDraft = dto.followUpDraft
                // Wire relationships
                for pid in dto.linkedPeopleIDs {
                    if let person = personByID[pid] {
                        n.linkedPeople.append(person)
                    }
                }
                for cid in dto.linkedContextIDs {
                    if let ctx = contextByID[cid] {
                        n.linkedContexts.append(ctx)
                    }
                }
                for eid in dto.linkedEvidenceIDs {
                    if let ev = evidenceByID[eid] {
                        n.linkedEvidence.append(ev)
                    }
                }
                context.insert(n)
                noteByID[dto.id] = n
            }

            // Note images
            for dto in doc.noteImages {
                let img = NoteImage(
                    id: dto.id,
                    imageData: dto.imageDataBase64.flatMap { Data(base64Encoded: $0) },
                    mimeType: dto.mimeType,
                    displayOrder: dto.displayOrder,
                    textInsertionPoint: dto.textInsertionPoint ?? Int.max,
                    createdAt: dto.createdAt
                )
                img.note = dto.noteID.flatMap { noteByID[$0] }
                context.insert(img)
            }

            // Analysis artifacts
            for dto in doc.analysisArtifacts {
                let a = SamAnalysisArtifact(
                    id: dto.id,
                    sourceType: dto.sourceType,
                    analyzedAt: dto.analyzedAt,
                    peopleJSON: dto.peopleJSON,
                    topicsJSON: dto.topicsJSON,
                    factsJSON: dto.factsJSON,
                    implicationsJSON: dto.implicationsJSON,
                    actions: dto.actions,
                    affect: dto.affect,
                    usedLLM: dto.usedLLM
                )
                a.note = dto.noteID.flatMap { noteByID[$0] }
                context.insert(a)
            }

            try context.save()
            logger.info("Pass 3 complete: evidence, notes, images, artifacts")

            // ── Pass 4: Deferred self-references ──────────────────────
            progress = "Wiring referrals..."
            for dto in doc.people {
                if let refID = dto.referredByID,
                   let person = personByID[dto.id],
                   let referrer = personByID[refID] {
                    person.referredBy = referrer
                }
            }
            try context.save()
            logger.info("Pass 4 complete: referral links")

            // 5. Apply preferences
            progress = "Applying preferences..."
            for (key, value) in doc.preferences {
                value.apply(to: .standard, key: key)
            }

            let summary = "\(doc.people.count) people, \(doc.notes.count) notes, \(doc.evidenceItems.count) evidence. If restoring on a new machine, use Reset Onboarding in Settings to reconfigure permissions."
            logger.info("Import complete: \(summary)")
            status = .success(summary)
            progress = ""

        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
            progress = ""
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Safety Backup (silent, no status updates)
    // ─────────────────────────────────────────────────────────────────

    /// Fetch all instances of a model type and delete them one by one.
    /// Unlike `context.delete(model:)` (batch), this avoids CoreData
    /// constraint failures on many-to-many nullify inverses.
    private func deleteAll<T: PersistentModel>(_ type: T.Type, from context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<T>())
        for obj in all {
            context.delete(obj)
        }
    }

    private func exportSafetyBackup(to url: URL) async {
        let savedStatus = status
        let savedProgress = progress

        // Temporarily suppress status updates by running export logic inline
        do {
            let context = ModelContext(SAMModelContainer.shared)

            let people = try context.fetch(FetchDescriptor<SamPerson>())
            let contexts = try context.fetch(FetchDescriptor<SamContext>())
            let participations = try context.fetch(FetchDescriptor<ContextParticipation>())
            let responsibilities = try context.fetch(FetchDescriptor<Responsibility>())
            let jointInterests = try context.fetch(FetchDescriptor<JointInterest>())
            let consents = try context.fetch(FetchDescriptor<ConsentRequirement>())
            let products = try context.fetch(FetchDescriptor<Product>())
            let coverages = try context.fetch(FetchDescriptor<Coverage>())
            let evidence = try context.fetch(FetchDescriptor<SamEvidenceItem>())
            let notes = try context.fetch(FetchDescriptor<SamNote>())
            let noteImages = try context.fetch(FetchDescriptor<NoteImage>())
            let artifacts = try context.fetch(FetchDescriptor<SamAnalysisArtifact>())
            let profiles = try context.fetch(FetchDescriptor<CoachingProfile>())
            let timeEntries = try context.fetch(FetchDescriptor<TimeEntry>())
            let transitions = try context.fetch(FetchDescriptor<StageTransition>())
            let stages = try context.fetch(FetchDescriptor<RecruitingStage>())
            let productions = try context.fetch(FetchDescriptor<ProductionRecord>())
            let posts = try context.fetch(FetchDescriptor<ContentPost>())
            let goals = try context.fetch(FetchDescriptor<BusinessGoal>())
            let audits = try context.fetch(FetchDescriptor<ComplianceAuditEntry>())
            let deducedRelations = try context.fetch(FetchDescriptor<DeducedRelation>())

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

            var prefs: [String: AnyCodableValue] = [:]
            for key in Self.includedPreferenceKeys {
                if let val = AnyCodableValue.from(userDefaults: .standard, key: key) {
                    prefs[key] = val
                }
            }

            let doc = BackupDocument(
                metadata: BackupMetadata(
                    exportDate: .now,
                    schemaVersion: "SAM_v26",
                    appVersion: appVersion,
                    buildNumber: buildNumber,
                    backupFormatVersion: 1,
                    counts: BackupCounts(
                        people: people.count,
                        notes: notes.count,
                        evidence: evidence.count,
                        contexts: contexts.count
                    )
                ),
                preferences: prefs,
                people: people.map { p in
                    PersonBackup(
                        id: p.id, contactIdentifier: p.contactIdentifier,
                        displayNameCache: p.displayNameCache, emailCache: p.emailCache,
                        emailAliases: p.emailAliases, phoneAliases: p.phoneAliases,
                        photoThumbnailBase64: p.photoThumbnailCache.map { $0.base64EncodedString() },
                        lastSyncedAt: p.lastSyncedAt, isArchived: p.isArchived, isMe: p.isMe,
                        relationshipSummary: p.relationshipSummary,
                        relationshipKeyThemes: p.relationshipKeyThemes,
                        relationshipNextSteps: p.relationshipNextSteps,
                        summaryUpdatedAt: p.summaryUpdatedAt,
                        inferredChannelRawValue: p.inferredChannelRawValue,
                        preferredChannelRawValue: p.preferredChannelRawValue,
                        preferredCadenceDays: p.preferredCadenceDays,
                        displayName: p.displayName, email: p.email,
                        roleBadges: p.roleBadges, consentAlertsCount: p.consentAlertsCount,
                        reviewAlertsCount: p.reviewAlertsCount,
                        responsibilityNotes: p.responsibilityNotes,
                        recentInteractions: p.recentInteractions,
                        contextChips: p.contextChips, referredByID: p.referredBy?.id
                    )
                },
                contexts: contexts.map { c in
                    ContextBackup(
                        id: c.id, name: c.name, kind: c.kind,
                        consentAlertCount: c.consentAlertCount,
                        reviewAlertCount: c.reviewAlertCount,
                        followUpAlertCount: c.followUpAlertCount,
                        productCards: c.productCards,
                        recentInteractions: c.recentInteractions
                    )
                },
                participations: participations.map { p in
                    ParticipationBackup(
                        id: p.id, personID: p.person?.id, contextID: p.context?.id,
                        roleBadges: p.roleBadges, isPrimary: p.isPrimary,
                        note: p.note, startDate: p.startDate, endDate: p.endDate
                    )
                },
                responsibilities: responsibilities.map { r in
                    ResponsibilityBackup(
                        id: r.id, guardianID: r.guardian?.id, dependentID: r.dependent?.id,
                        reason: r.reason, startDate: r.startDate, endDate: r.endDate
                    )
                },
                jointInterests: jointInterests.map { j in
                    JointInterestBackup(
                        id: j.id, partyIDs: j.parties.map(\.id), type: j.type,
                        survivorshipRights: j.survivorshipRights, startDate: j.startDate,
                        endDate: j.endDate, notes: j.notes, productIDs: j.products.map(\.id)
                    )
                },
                consentRequirements: consents.map { c in
                    ConsentRequirementBackup(
                        id: c.id, personID: c.person?.id, contextID: nil,
                        productID: c.product?.id, title: c.title, reason: c.reason,
                        jurisdiction: c.jurisdiction, status: c.status,
                        requestedAt: c.requestedAt, satisfiedAt: c.satisfiedAt, revokedAt: c.revokedAt
                    )
                },
                products: products.map { p in
                    ProductBackup(
                        id: p.id, contextID: p.context?.id, type: p.type,
                        name: p.name, subtitle: p.subtitle,
                        statusDisplay: p.statusDisplay, icon: p.icon, issuedDate: p.issuedDate
                    )
                },
                coverages: coverages.map { c in
                    CoverageBackup(
                        id: c.id, personID: c.person?.id, productID: c.product?.id,
                        role: c.role, survivorshipRights: c.survivorshipRights
                    )
                },
                evidenceItems: evidence.map { e in
                    EvidenceBackup(
                        id: e.id, sourceUID: e.sourceUID, source: e.source,
                        stateRawValue: e.stateRawValue, occurredAt: e.occurredAt,
                        endedAt: e.endedAt, title: e.title, snippet: e.snippet,
                        bodyText: e.bodyText, signals: e.signals,
                        participantHints: e.participantHints, proposedLinks: e.proposedLinks,
                        linkedPeopleIDs: e.linkedPeople.map(\.id),
                        linkedContextIDs: e.linkedContexts.map(\.id)
                    )
                },
                notes: notes.map { n in
                    NoteBackup(
                        id: n.id, content: n.content, summary: n.summary,
                        createdAt: n.createdAt, updatedAt: n.updatedAt,
                        sourceTypeRawValue: n.sourceTypeRawValue,
                        sourceImportUID: n.sourceImportUID,
                        isAnalyzed: n.isAnalyzed, analysisVersion: n.analysisVersion,
                        linkedPeopleIDs: n.linkedPeople.map(\.id),
                        linkedContextIDs: n.linkedContexts.map(\.id),
                        linkedEvidenceIDs: n.linkedEvidence.map(\.id),
                        extractedMentions: n.extractedMentions,
                        extractedActionItems: n.extractedActionItems,
                        extractedTopics: n.extractedTopics,
                        discoveredRelationships: n.discoveredRelationships,
                        lifeEvents: n.lifeEvents, followUpDraft: n.followUpDraft
                    )
                },
                noteImages: noteImages.map { img in
                    NoteImageBackup(
                        id: img.id, noteID: img.note?.id,
                        imageDataBase64: img.imageData.map { $0.base64EncodedString() },
                        mimeType: img.mimeType, displayOrder: img.displayOrder,
                        textInsertionPoint: img.textInsertionPoint, createdAt: img.createdAt
                    )
                },
                analysisArtifacts: artifacts.map { a in
                    AnalysisArtifactBackup(
                        id: a.id, noteID: a.note?.id, sourceType: a.sourceType,
                        analyzedAt: a.analyzedAt, peopleJSON: a.peopleJSON,
                        topicsJSON: a.topicsJSON, factsJSON: a.factsJSON,
                        implicationsJSON: a.implicationsJSON, actions: a.actions,
                        affect: a.affect, usedLLM: a.usedLLM
                    )
                },
                coachingProfile: profiles.first.map { p in
                    CoachingProfileBackup(
                        id: p.id, encouragementStyle: p.encouragementStyle,
                        preferredOutcomeKinds: p.preferredOutcomeKinds,
                        dismissPatterns: p.dismissPatterns,
                        avgResponseTimeMinutes: p.avgResponseTimeMinutes,
                        totalActedOn: p.totalActedOn, totalDismissed: p.totalDismissed,
                        totalRated: p.totalRated, avgRating: p.avgRating, updatedAt: p.updatedAt
                    )
                },
                timeEntries: timeEntries.map { t in
                    TimeEntryBackup(
                        id: t.id, categoryRawValue: t.categoryRawValue,
                        title: t.title, durationMinutes: t.durationMinutes,
                        startedAt: t.startedAt, endedAt: t.endedAt,
                        isManualOverride: t.isManualOverride, isManualEntry: t.isManualEntry,
                        sourceEvidenceID: t.sourceEvidenceID,
                        linkedPeopleIDs: t.linkedPeopleIDs, createdAt: t.createdAt
                    )
                },
                stageTransitions: transitions.map { t in
                    StageTransitionBackup(
                        id: t.id, personID: t.person?.id,
                        fromStage: t.fromStage, toStage: t.toStage,
                        transitionDate: t.transitionDate,
                        pipelineTypeRawValue: t.pipelineTypeRawValue, notes: t.notes
                    )
                },
                recruitingStages: stages.map { s in
                    RecruitingStageBackup(
                        id: s.id, personID: s.person?.id,
                        stageRawValue: s.stageRawValue, enteredDate: s.enteredDate,
                        mentoringLastContact: s.mentoringLastContact, notes: s.notes
                    )
                },
                productionRecords: productions.map { p in
                    ProductionRecordBackup(
                        id: p.id, personID: p.person?.id,
                        productTypeRawValue: p.productTypeRawValue,
                        statusRawValue: p.statusRawValue,
                        carrierName: p.carrierName, annualPremium: p.annualPremium,
                        submittedDate: p.submittedDate, resolvedDate: p.resolvedDate,
                        policyNumber: p.policyNumber, notes: p.notes,
                        createdAt: p.createdAt, updatedAt: p.updatedAt
                    )
                },
                contentPosts: posts.map { p in
                    ContentPostBackup(
                        id: p.id, platformRawValue: p.platformRawValue,
                        topic: p.topic, postedAt: p.postedAt,
                        sourceOutcomeID: p.sourceOutcomeID, createdAt: p.createdAt
                    )
                },
                businessGoals: goals.map { g in
                    BusinessGoalBackup(
                        id: g.id, goalTypeRawValue: g.goalTypeRawValue,
                        title: g.title, targetValue: g.targetValue,
                        startDate: g.startDate, endDate: g.endDate,
                        isActive: g.isActive, notes: g.notes,
                        createdAt: g.createdAt, updatedAt: g.updatedAt
                    )
                },
                complianceAuditEntries: audits.map { a in
                    ComplianceAuditBackup(
                        id: a.id, channelRawValue: a.channelRawValue,
                        recipientName: a.recipientName, recipientAddress: a.recipientAddress,
                        originalDraft: a.originalDraft, finalDraft: a.finalDraft,
                        wasModified: a.wasModified, complianceFlagsJSON: a.complianceFlagsJSON,
                        outcomeID: a.outcomeID, createdAt: a.createdAt, sentAt: a.sentAt
                    )
                },
                deducedRelations: deducedRelations.map { r in
                    DeducedRelationBackup(
                        id: r.id, personAID: r.personAID, personBID: r.personBID,
                        relationTypeRawValue: r.relationTypeRawValue,
                        sourceLabel: r.sourceLabel, isConfirmed: r.isConfirmed,
                        createdAt: r.createdAt, confirmedAt: r.confirmedAt
                    )
                }
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(doc)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("Safety backup failed (non-fatal): \(error.localizedDescription)")
        }

        // Restore status
        status = savedStatus
        progress = savedProgress
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Errors
// ─────────────────────────────────────────────────────────────────────

enum BackupError: LocalizedError {
    case unsupportedFormat(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let v):
            return "Unsupported backup format version \(v). This backup was created with a newer version of SAM."
        }
    }
}
