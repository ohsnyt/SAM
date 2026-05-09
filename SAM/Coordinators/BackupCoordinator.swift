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
import CryptoKit
import LocalAuthentication

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

    /// Names of background coordinators currently blocking the settle phase.
    /// Empty when not in settle phase or when nothing is blocking. Drives the
    /// "Waiting for X to finish" detail line in the restore overlay.
    var blockedBy: [String] = []
    var pendingImport: (url: URL, preview: ImportPreview)?
    var isEncryptedBackup: Bool = false
    var needsPassphrase: Bool = false

    private init() {}

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Restore Flag (cross-actor readable)
    // ─────────────────────────────────────────────────────────────────

    /// Set true the moment the user confirms a restore — before the safety
    /// backup, well before the wipe — and cleared in `refreshAfterRestore`.
    /// Long-running coordinators read this from background actors and bail
    /// at safe points to avoid dereferencing SwiftData objects mid-wipe.
    private static let _isRestoring = OSAllocatedUnfairLock<Bool>(initialState: false)

    nonisolated static var isRestoring: Bool {
        _isRestoring.withLock { $0 }
    }

    nonisolated private static func setIsRestoring(_ value: Bool) {
        _isRestoring.withLock { $0 = value }
    }

    /// Poll the major running coordinators until they're all idle, with a
    /// hard timeout so a stuck import can't block restore forever. Called
    /// after `isRestoring` is set true and before the wipe; the flag itself
    /// makes new work inert, this loop just waits for in-flight work to
    /// finish its current iteration cleanly.
    private func waitForInFlightWorkToSettle(timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        var loggedWaiting = false
        while Date() < deadline {
            let comms = CommunicationsImportCoordinator.shared.importStatus == .importing
            let mail = MailImportCoordinator.shared.importStatus == .importing
            let cal = CalendarImportCoordinator.shared.importStatus == .importing
            let contacts = ContactsImportCoordinator.isImportingContacts
            let outcome = OutcomeEngine.shared.generationStatus == .generating
            let strategic = StrategicCoordinator.shared.generationStatus == .generating
            let role = RoleDeductionEngine.shared.deductionStatus == .running
            let busy = comms || mail || cal || contacts || outcome || strategic || role
            if !busy {
                blockedBy = []
                if loggedWaiting {
                    logger.info("In-flight work settled — proceeding with restore")
                }
                return
            }
            var blockers: [String] = []
            if comms    { blockers.append("communications import") }
            if mail     { blockers.append("mail import") }
            if cal      { blockers.append("calendar import") }
            if contacts { blockers.append("contacts import") }
            if outcome  { blockers.append("outcome generation") }
            if strategic { blockers.append("strategic digest") }
            if role     { blockers.append("role deduction") }
            blockedBy = blockers
            if !loggedWaiting {
                progress = "Waiting for background work to finish..."
                logger.info("Restore waiting for in-flight work — comms=\(comms) mail=\(mail) cal=\(cal) contacts=\(contacts) outcome=\(outcome) strategic=\(strategic) role=\(role)")
                loggedWaiting = true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        logger.warning("Restore settle timeout after \(Int(timeout))s — proceeding anyway (some work may still be in flight)")
        blockedBy = []
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Preference Keys
    // ─────────────────────────────────────────────────────────────────

    /// Keys included in backup (portable preferences).
    private static let includedPreferenceKeys: [String] = [
        "coachingStyle", "outcomeAutoGenerate",
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
        // Business profile & social profiles (user-entered context)
        "sam.businessProfile",
        "sam.userLinkedInProfile", "sam.userFacebookProfile", "sam.userSubstackProfile",
        "sam.profileAnalyses", "sam.profileAnalysisSnapshot", "sam.facebookAnalysisSnapshot",
        // Import watermarks — exported so a restore on a new Mac resumes
        // from the same point, and a same-Mac restore doesn't skip messages
        // newer than the backup. Legacy backups without these keys trigger a
        // watermark reset in refreshAfterRestore so the next pass walks the
        // full lookback window.
        "mailLastWatermark", "mailLastSentWatermark",
        "commsLastMessageWatermark", "commsLastCallWatermark",
        "commsLastWhatsAppMessageWatermark", "commsLastWhatsAppCallWatermark",
    ]

    /// Watermark keys that, when absent from a restored backup, must be
    /// cleared locally so the next import pass scans the full lookback window.
    private static let watermarkKeys: [String] = [
        "mailLastWatermark", "mailLastSentWatermark",
        "commsLastMessageWatermark", "commsLastCallWatermark",
        "commsLastWhatsAppMessageWatermark", "commsLastWhatsAppCallWatermark",
    ]

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Export
    // ─────────────────────────────────────────────────────────────────

    func exportBackup(to url: URL, passphrase: String? = nil) async {
        await exportBackup(to: url, container: SAMModelContainer.shared, passphrase: passphrase)
    }

    /// Export backup from a specific container (used by legacy migration).
    func exportBackup(to url: URL, container: ModelContainer, passphrase: String? = nil) async {
        status = .exporting
        progress = "Fetching data..."
        logger.info("Export started")

        do {
            let context = ModelContext(container)

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

            progress = "Reading Substack imports..."
            let substackImports = try context.fetch(FetchDescriptor<SubstackImport>())

            progress = "Reading goal journal entries..."
            let journalEntries = try context.fetch(FetchDescriptor<GoalJournalEntry>())

            progress = "Reading trips..."
            let trips = try context.fetch(FetchDescriptor<SamTrip>())
            let tripStops = try context.fetch(FetchDescriptor<SamTripStop>())
            let savedAddresses = try context.fetch(FetchDescriptor<SamSavedAddress>())

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
                    isArchived: p.isArchivedLegacy,
                    isMe: p.isMe,
                    lifecycleStatusRawValue: p.lifecycleStatusRawValue,
                    lifecycleChangedAt: p.lifecycleChangedAt,
                    relationshipSummary: p.relationshipSummary,
                    relationshipKeyThemes: p.relationshipKeyThemes,
                    relationshipNextSteps: p.relationshipNextSteps,
                    summaryUpdatedAt: p.summaryUpdatedAt,
                    inferredChannelRawValue: p.inferredChannelRawValue,
                    preferredChannelRawValue: p.preferredChannelRawValue,
                    preferredCadenceDays: p.preferredCadenceDays,
                    preferredQuickChannelRawValue: p.preferredQuickChannelRawValue,
                    preferredDetailedChannelRawValue: p.preferredDetailedChannelRawValue,
                    preferredSocialChannelRawValue: p.preferredSocialChannelRawValue,
                    inferredQuickChannelRawValue: p.inferredQuickChannelRawValue,
                    inferredDetailedChannelRawValue: p.inferredDetailedChannelRawValue,
                    inferredSocialChannelRawValue: p.inferredSocialChannelRawValue,
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
                    isRejected: r.isRejected,
                    createdAt: r.createdAt,
                    confirmedAt: r.confirmedAt
                )
            }

            let substackImportDTOs = substackImports.map { s in
                SubstackImportBackup(
                    id: s.id,
                    importDate: s.importDate,
                    archiveFileName: s.archiveFileName,
                    postCount: s.postCount,
                    subscriberCount: s.subscriberCount,
                    matchedSubscriberCount: s.matchedSubscriberCount,
                    newLeadsFound: s.newLeadsFound,
                    touchEventsCreated: s.touchEventsCreated,
                    statusRawValue: s.statusRawValue
                )
            }

            let journalEntryDTOs = journalEntries.map { e in
                GoalJournalEntryBackup(
                    id: e.id,
                    goalID: e.goalID,
                    goalTypeRawValue: e.goalTypeRawValue,
                    headline: e.headline,
                    whatsWorking: e.whatsWorking,
                    whatsNotWorking: e.whatsNotWorking,
                    barriers: e.barriers,
                    adjustedStrategy: e.adjustedStrategy,
                    keyInsight: e.keyInsight,
                    commitmentActions: e.commitmentActions,
                    paceAtCheckInRawValue: e.paceAtCheckInRawValue,
                    progressAtCheckIn: e.progressAtCheckIn,
                    conversationTurnCount: e.conversationTurnCount,
                    createdAt: e.createdAt
                )
            }

            let tripDTOs = trips.map { t in
                TripBackup(
                    id: t.id,
                    date: t.date,
                    totalDistanceMiles: t.totalDistanceMiles,
                    businessDistanceMiles: t.businessDistanceMiles,
                    personalDistanceMiles: t.personalDistanceMiles,
                    startOdometer: t.startOdometer,
                    endOdometer: t.endOdometer,
                    statusRawValue: t.statusRawValue,
                    notes: t.notes,
                    startedAt: t.startedAt,
                    endedAt: t.endedAt,
                    startAddress: t.startAddress,
                    vehicle: t.vehicle,
                    tripPurposeRawValue: t.tripPurposeRawValue,
                    confirmedAt: t.confirmedAt,
                    isCommuting: t.isCommuting
                )
            }

            let tripStopDTOs = tripStops.compactMap { s -> TripStopBackup? in
                guard let tripID = s.trip?.id else { return nil }
                return TripStopBackup(
                    id: s.id,
                    tripID: tripID,
                    latitude: s.latitude,
                    longitude: s.longitude,
                    address: s.address,
                    locationName: s.locationName,
                    arrivedAt: s.arrivedAt,
                    departedAt: s.departedAt,
                    distanceFromPreviousMiles: s.distanceFromPreviousMiles,
                    purposeRawValue: s.purposeRawValue,
                    outcomeRawValue: s.outcomeRawValue,
                    notes: s.notes,
                    sortOrder: s.sortOrder,
                    linkedPersonID: s.linkedPerson?.id,
                    linkedEvidenceID: s.linkedEvidence?.id
                )
            }

            let savedAddressDTOs = savedAddresses.map { a in
                SavedAddressBackup(
                    id: a.id,
                    label: a.label,
                    formattedAddress: a.formattedAddress,
                    latitude: a.latitude,
                    longitude: a.longitude,
                    kindRawValue: a.kindRawValue,
                    createdAt: a.createdAt,
                    lastUsedAt: a.lastUsedAt,
                    useCount: a.useCount
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
                    schemaVersion: SAMModelContainer.schemaVersion,
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
                deducedRelations: deducedRelationDTOs,
                substackImports: substackImportDTOs,
                goalJournalEntries: journalEntryDTOs,
                trips: tripDTOs,
                tripStops: tripStopDTOs,
                savedAddresses: savedAddressDTOs
            )

            // Encode
            progress = "Writing file..."
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(document)
            let outputData: Data
            if let passphrase, !passphrase.isEmpty {
                outputData = try encrypt(data, passphrase: passphrase)
                logger.debug("Backup encrypted with user passphrase")
            } else {
                outputData = data
            }
            try outputData.write(to: url, options: .atomic)

            let sizeMB = Double(outputData.count) / 1_048_576.0
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

    func validateBackup(from url: URL, passphrase: String? = nil) async throws -> ImportPreview {
        status = .validating
        progress = "Reading backup file..."

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let jsonData: Data
        if data.starts(with: Data("SAMENC1".utf8)) {
            isEncryptedBackup = true
            guard let passphrase, !passphrase.isEmpty else {
                needsPassphrase = true
                throw BackupError.authenticationRequired
            }
            jsonData = try decrypt(data, passphrase: passphrase)
        } else {
            isEncryptedBackup = false
            jsonData = data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(BackupDocument.self, from: jsonData)

        guard doc.metadata.backupFormatVersion == 1 else {
            throw BackupError.unsupportedFormat(doc.metadata.backupFormatVersion)
        }

        let schemaMatch = doc.metadata.schemaVersion == SAMModelContainer.schemaVersion
        let preview = ImportPreview(metadata: doc.metadata, schemaMatch: schemaMatch)

        status = .idle
        progress = ""
        return preview
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Import
    // ─────────────────────────────────────────────────────────────────

    func performImport(from url: URL, passphrase: String? = nil) async {
        status = .importing
        logger.info("Import started")

        // Signal restore-in-progress immediately so any background coordinator
        // checking the flag bails at its next safe point. The settle wait
        // below gives in-flight work time to finish its current iteration
        // before we start tearing down the SwiftData store.
        Self.setIsRestoring(true)
        defer { Self.setIsRestoring(false) }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            // 1. Safety backup
            progress = "Creating safety backup..."
            let safetyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SAM-pre-import-safety.sambackup")
            await exportSafetyBackup(to: safetyURL)
            logger.debug("Safety backup saved to \(safetyURL.path)")

            // 1b. Wait for in-flight imports/engines to settle so the wipe
            // pass below doesn't yank SwiftData objects out from under them.
            await waitForInFlightWorkToSettle()

            // 2. Decode source
            progress = "Decoding backup..."
            let data = try Data(contentsOf: url)
            let jsonData: Data
            if data.starts(with: Data("SAMENC1".utf8)) {
                guard let passphrase, !passphrase.isEmpty else {
                    throw BackupError.authenticationRequired
                }
                jsonData = try decrypt(data, passphrase: passphrase)
            } else {
                jsonData = data
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(BackupDocument.self, from: jsonData)

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
            logger.debug("All existing data deleted")

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
                person.isArchivedLegacy = dto.isArchived
                // Import lifecycle status: prefer new field, fall back to isArchived for old backups
                if let rawValue = dto.lifecycleStatusRawValue {
                    person.lifecycleStatusRawValue = rawValue
                } else if dto.isArchived {
                    person.lifecycleStatusRawValue = ContactLifecycleStatus.archived.rawValue
                }
                person.lifecycleChangedAt = dto.lifecycleChangedAt
                person.relationshipSummary = dto.relationshipSummary
                person.relationshipKeyThemes = dto.relationshipKeyThemes
                person.relationshipNextSteps = dto.relationshipNextSteps
                person.summaryUpdatedAt = dto.summaryUpdatedAt
                person.inferredChannelRawValue = dto.inferredChannelRawValue
                person.preferredChannelRawValue = dto.preferredChannelRawValue
                person.preferredCadenceDays = dto.preferredCadenceDays
                person.preferredQuickChannelRawValue = dto.preferredQuickChannelRawValue
                person.preferredDetailedChannelRawValue = dto.preferredDetailedChannelRawValue
                person.preferredSocialChannelRawValue = dto.preferredSocialChannelRawValue
                person.inferredQuickChannelRawValue = dto.inferredQuickChannelRawValue
                person.inferredDetailedChannelRawValue = dto.inferredDetailedChannelRawValue
                person.inferredSocialChannelRawValue = dto.inferredSocialChannelRawValue
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

            for dto in doc.goalJournalEntries ?? [] {
                let entry = GoalJournalEntry(
                    id: dto.id,
                    goalID: dto.goalID,
                    goalType: GoalType(rawValue: dto.goalTypeRawValue) ?? .newClients,
                    headline: dto.headline,
                    whatsWorking: dto.whatsWorking,
                    whatsNotWorking: dto.whatsNotWorking,
                    barriers: dto.barriers,
                    adjustedStrategy: dto.adjustedStrategy,
                    keyInsight: dto.keyInsight,
                    commitmentActions: dto.commitmentActions,
                    paceAtCheckIn: GoalPace(rawValue: dto.paceAtCheckInRawValue) ?? .onTrack,
                    progressAtCheckIn: dto.progressAtCheckIn,
                    conversationTurnCount: dto.conversationTurnCount
                )
                entry.createdAt = dto.createdAt
                context.insert(entry)
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
                    isRejected: dto.isRejected ?? false,
                    createdAt: dto.createdAt,
                    confirmedAt: dto.confirmedAt
                )
                context.insert(relation)
            }

            for dto in doc.substackImports ?? [] {
                let record = SubstackImport(
                    importDate: dto.importDate,
                    archiveFileName: dto.archiveFileName,
                    postCount: dto.postCount,
                    subscriberCount: dto.subscriberCount,
                    matchedSubscriberCount: dto.matchedSubscriberCount,
                    newLeadsFound: dto.newLeadsFound,
                    touchEventsCreated: dto.touchEventsCreated,
                    status: SubstackImportStatus(rawValue: dto.statusRawValue) ?? .complete
                )
                context.insert(record)
            }

            // Phase 0b: trips, stops, saved addresses (backward-compatible).
            // Trips first so stops can resolve their parent by UUID.
            var tripByID: [UUID: SamTrip] = [:]
            for dto in doc.trips ?? [] {
                let trip = SamTrip(
                    id: dto.id,
                    date: dto.date,
                    totalDistanceMiles: dto.totalDistanceMiles,
                    businessDistanceMiles: dto.businessDistanceMiles,
                    personalDistanceMiles: dto.personalDistanceMiles,
                    status: TripStatus(rawValue: dto.statusRawValue) ?? .recorded,
                    notes: dto.notes,
                    startedAt: dto.startedAt,
                    endedAt: dto.endedAt,
                    startAddress: dto.startAddress,
                    vehicle: dto.vehicle,
                    tripPurpose: dto.tripPurposeRawValue.flatMap { StopPurpose(rawValue: $0) },
                    confirmedAt: dto.confirmedAt,
                    isCommuting: dto.isCommuting
                )
                trip.startOdometer = dto.startOdometer
                trip.endOdometer = dto.endOdometer
                context.insert(trip)
                tripByID[dto.id] = trip
            }

            for dto in doc.tripStops ?? [] {
                guard let parentTrip = tripByID[dto.tripID] else { continue }
                let stop = SamTripStop(
                    id: dto.id,
                    latitude: dto.latitude,
                    longitude: dto.longitude,
                    address: dto.address,
                    locationName: dto.locationName,
                    arrivedAt: dto.arrivedAt,
                    departedAt: dto.departedAt,
                    distanceFromPreviousMiles: dto.distanceFromPreviousMiles,
                    purpose: StopPurpose(rawValue: dto.purposeRawValue) ?? .prospecting,
                    outcome: dto.outcomeRawValue.flatMap { VisitOutcome(rawValue: $0) },
                    notes: dto.notes,
                    sortOrder: dto.sortOrder
                )
                stop.trip = parentTrip
                if let pid = dto.linkedPersonID {
                    stop.linkedPerson = personByID[pid]
                }
                context.insert(stop)
            }

            for dto in doc.savedAddresses ?? [] {
                let addr = SamSavedAddress(
                    id: dto.id,
                    label: dto.label,
                    formattedAddress: dto.formattedAddress,
                    latitude: dto.latitude,
                    longitude: dto.longitude,
                    kind: SavedAddressKind(rawValue: dto.kindRawValue) ?? .recent,
                    createdAt: dto.createdAt,
                    lastUsedAt: dto.lastUsedAt,
                    useCount: dto.useCount
                )
                context.insert(addr)
            }

            try context.save()
            logger.debug("Pass 1 complete: \(doc.people.count) people, \(doc.contexts.count) contexts")

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
            logger.debug("Pass 2 complete: products, participations, coverages, etc.")

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
            logger.debug("Pass 3 complete: evidence, notes, images, artifacts")

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
            logger.debug("Pass 4 complete: referral links")

            // 5. Apply preferences
            progress = "Applying preferences..."
            for (key, value) in doc.preferences {
                value.apply(to: .standard, key: key)
            }
            let importedPreferenceKeys = Set(doc.preferences.keys)

            let summary = "\(doc.people.count) people, \(doc.notes.count) notes, \(doc.evidenceItems.count) evidence. If restoring on a new machine, use Reset Onboarding in Settings to reconfigure permissions."
            logger.info("Import complete: \(summary)")
            status = .success(summary)
            progress = ""

            // Post-restore: clear date gates and trigger regeneration
            await refreshAfterRestore(importedPreferenceKeys: importedPreferenceKeys)

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
            let substackImports = try context.fetch(FetchDescriptor<SubstackImport>())
            let journalEntries = try context.fetch(FetchDescriptor<GoalJournalEntry>())
            let trips = try context.fetch(FetchDescriptor<SamTrip>())
            let tripStops = try context.fetch(FetchDescriptor<SamTripStop>())
            let savedAddresses = try context.fetch(FetchDescriptor<SamSavedAddress>())

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
                    schemaVersion: SAMModelContainer.schemaVersion,
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
                        lastSyncedAt: p.lastSyncedAt, isArchived: p.isArchivedLegacy, isMe: p.isMe,
                        lifecycleStatusRawValue: p.lifecycleStatusRawValue,
                        lifecycleChangedAt: p.lifecycleChangedAt,
                        relationshipSummary: p.relationshipSummary,
                        relationshipKeyThemes: p.relationshipKeyThemes,
                        relationshipNextSteps: p.relationshipNextSteps,
                        summaryUpdatedAt: p.summaryUpdatedAt,
                        inferredChannelRawValue: p.inferredChannelRawValue,
                        preferredChannelRawValue: p.preferredChannelRawValue,
                        preferredCadenceDays: p.preferredCadenceDays,
                        preferredQuickChannelRawValue: p.preferredQuickChannelRawValue,
                        preferredDetailedChannelRawValue: p.preferredDetailedChannelRawValue,
                        preferredSocialChannelRawValue: p.preferredSocialChannelRawValue,
                        inferredQuickChannelRawValue: p.inferredQuickChannelRawValue,
                        inferredDetailedChannelRawValue: p.inferredDetailedChannelRawValue,
                        inferredSocialChannelRawValue: p.inferredSocialChannelRawValue,
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
                        isRejected: r.isRejected,
                        createdAt: r.createdAt, confirmedAt: r.confirmedAt
                    )
                },
                substackImports: substackImports.map { s in
                    SubstackImportBackup(
                        id: s.id, importDate: s.importDate,
                        archiveFileName: s.archiveFileName, postCount: s.postCount,
                        subscriberCount: s.subscriberCount, matchedSubscriberCount: s.matchedSubscriberCount,
                        newLeadsFound: s.newLeadsFound, touchEventsCreated: s.touchEventsCreated,
                        statusRawValue: s.statusRawValue
                    )
                },
                goalJournalEntries: journalEntries.map { e in
                    GoalJournalEntryBackup(
                        id: e.id, goalID: e.goalID, goalTypeRawValue: e.goalTypeRawValue,
                        headline: e.headline, whatsWorking: e.whatsWorking,
                        whatsNotWorking: e.whatsNotWorking, barriers: e.barriers,
                        adjustedStrategy: e.adjustedStrategy, keyInsight: e.keyInsight,
                        commitmentActions: e.commitmentActions,
                        paceAtCheckInRawValue: e.paceAtCheckInRawValue,
                        progressAtCheckIn: e.progressAtCheckIn,
                        conversationTurnCount: e.conversationTurnCount, createdAt: e.createdAt
                    )
                },
                trips: trips.map { t in
                    TripBackup(
                        id: t.id, date: t.date,
                        totalDistanceMiles: t.totalDistanceMiles,
                        businessDistanceMiles: t.businessDistanceMiles,
                        personalDistanceMiles: t.personalDistanceMiles,
                        startOdometer: t.startOdometer, endOdometer: t.endOdometer,
                        statusRawValue: t.statusRawValue, notes: t.notes,
                        startedAt: t.startedAt, endedAt: t.endedAt,
                        startAddress: t.startAddress, vehicle: t.vehicle,
                        tripPurposeRawValue: t.tripPurposeRawValue,
                        confirmedAt: t.confirmedAt, isCommuting: t.isCommuting
                    )
                },
                tripStops: tripStops.compactMap { s -> TripStopBackup? in
                    guard let tripID = s.trip?.id else { return nil }
                    return TripStopBackup(
                        id: s.id, tripID: tripID,
                        latitude: s.latitude, longitude: s.longitude,
                        address: s.address, locationName: s.locationName,
                        arrivedAt: s.arrivedAt, departedAt: s.departedAt,
                        distanceFromPreviousMiles: s.distanceFromPreviousMiles,
                        purposeRawValue: s.purposeRawValue,
                        outcomeRawValue: s.outcomeRawValue, notes: s.notes,
                        sortOrder: s.sortOrder,
                        linkedPersonID: s.linkedPerson?.id,
                        linkedEvidenceID: s.linkedEvidence?.id
                    )
                },
                savedAddresses: savedAddresses.map { a in
                    SavedAddressBackup(
                        id: a.id, label: a.label,
                        formattedAddress: a.formattedAddress,
                        latitude: a.latitude, longitude: a.longitude,
                        kindRawValue: a.kindRawValue,
                        createdAt: a.createdAt, lastUsedAt: a.lastUsedAt,
                        useCount: a.useCount
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

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Post-Restore Refresh
    // ─────────────────────────────────────────────────────────────────

    /// After restoring from backup, clear stale date gates and regenerate
    /// outcomes, briefings, and other derived data from the restored dataset.
    ///
    /// `importedPreferenceKeys` is the set of preference keys that came from
    /// the backup. Watermarks not present (legacy backups) are reset locally
    /// so the next import pass walks the full lookback window.
    private func refreshAfterRestore(importedPreferenceKeys: Set<String> = []) async {
        logger.debug("Post-restore refresh starting")

        // Clear briefing date gate so a new briefing generates from restored data
        UserDefaults.standard.removeObject(forKey: "lastBriefingDate")
        UserDefaults.standard.removeObject(forKey: "lastWeeklyDigestWeek")

        // Reset any import watermark the backup didn't carry. On a legacy
        // backup this forces a full lookback re-scan; on a new backup the
        // restored watermark survives and imports resume from that point.
        var resetWatermarks: [String] = []
        for key in Self.watermarkKeys where !importedPreferenceKeys.contains(key) {
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
                resetWatermarks.append(key)
            }
        }
        if !resetWatermarks.isEmpty {
            let joined = resetWatermarks.joined(separator: ", ")
            logger.info("Reset \(resetWatermarks.count) watermark(s) absent from backup: \(joined)")
        }

        // Prune expired outcomes/undo entries
        try? OutcomeRepository.shared.pruneExpired()
        try? OutcomeRepository.shared.purgeOld()
        try? UndoRepository.shared.pruneExpired()

        // Write a placeholder briefing so the user (and the phone via CloudKit)
        // sees an explicit "restoring" state until a real briefing regenerates.
        await writeRestorePlaceholderBriefing()

        // Regenerate outcomes from restored data. Skip AI enrichment on the
        // first cycle — every person has fresh outcomes with no cached AI
        // rationale, so enrichWithAI would otherwise spend several minutes
        // making LLM calls before the user sees anything on Today.
        // The next scheduled OutcomeEngine cycle fills in AI rationale.
        let autoGenerate = UserDefaults.standard.object(forKey: "outcomeAutoGenerate") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "outcomeAutoGenerate")
        if autoGenerate {
            OutcomeEngine.shared.skipEnrichmentNextRun = true
            OutcomeEngine.shared.startGeneration()
        }

        // Refresh meeting prep from restored evidence
        await MeetingPrepCoordinator.shared.refresh()

        // Re-run the launch-time import + deferred work so imports resume
        // (Contacts → Calendar/Mail/Comms → role deduction → briefing).
        // Imports honor the watermark logic above; legacy backups will do a
        // full lookback re-scan, fresh backups will resume from where the
        // source Mac left off.
        SAMApp.runPostRestoreStartup()

        // Park the user on Today (matches the placeholder briefing we just
        // wrote) and notify cache-holding @Observable coordinators to
        // invalidate derived state. SwiftData @Query-bound views auto-repaint
        // from the rewritten store.
        UserDefaults.standard.set("today", forKey: "sam.sidebar.selection")
        NotificationCenter.default.post(name: .samBackupDidRestore, object: nil)

        logger.debug("Post-restore refresh complete")
    }

    /// Write a placeholder SamDailyBriefing locally and push the same payload
    /// to CloudKit so the iPhone companion stops showing the pre-restore
    /// briefing. The placeholder is replaced when DailyBriefingCoordinator
    /// generates the next real briefing.
    private func writeRestorePlaceholderBriefing() async {
        let placeholderNarrative = "SAM has just restored data from a backup. A fresh briefing will be available shortly."

        // Write locally so the Mac UI shows the same placeholder until regen.
        do {
            let context = ModelContext(SAMModelContainer.shared)
            // Remove any existing briefings — they reflect pre-restore state.
            let existing = try context.fetch(FetchDescriptor<SamDailyBriefing>())
            for old in existing {
                context.delete(old)
            }
            let placeholder = SamDailyBriefing(
                briefingType: .morning,
                dateKey: Calendar.current.startOfDay(for: .now)
            )
            placeholder.narrativeSummary = placeholderNarrative
            placeholder.ttsNarrative = placeholderNarrative
            context.insert(placeholder)
            try context.save()
            logger.debug("Restore placeholder briefing written locally")
        } catch {
            logger.error("Failed to write placeholder briefing: \(error.localizedDescription)")
        }

        // Push the same placeholder to CloudKit so the phone replaces the
        // pre-restore briefing it cached. Schema mirrors DailyBriefingCoordinator.pushBriefingToCloud.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var dict: [String: String] = [
            "date": ISO8601DateFormatter().string(from: .now),
            "meetingCount": "0",
            "narrativeSummary": placeholderNarrative,
            "sectionHeading": "Restoring backup"
        ]
        let emptyCalendar: [BriefingCalendarItem] = []
        let emptyActions: [BriefingAction] = []
        let emptyFollowUps: [BriefingFollowUp] = []
        if let d = try? encoder.encode(emptyCalendar) { dict["calendarItems"] = String(data: d, encoding: .utf8) }
        if let d = try? encoder.encode(emptyActions) { dict["priorityActions"] = String(data: d, encoding: .utf8) }
        if let d = try? encoder.encode(emptyFollowUps) { dict["followUps"] = String(data: d, encoding: .utf8) }
        if let d = try? encoder.encode(emptyActions) { dict["strategicHighlights"] = String(data: d, encoding: .utf8) }
        if let data = try? encoder.encode(dict),
           let json = String(data: data, encoding: .utf8) {
            await CloudSyncService.shared.pushBriefing(briefingJSON: json)
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Encryption
    // ─────────────────────────────────────────────────────────────────

    /// Derive a symmetric key from a user-provided passphrase using HKDF.
    private func deriveKey(from passphrase: String) -> SymmetricKey {
        let inputKey = SymmetricKey(data: Data(passphrase.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: "com.matthewsessions.SAM.backup".data(using: .utf8)!,
            info: Data(),
            outputByteCount: 32
        )
    }

    /// Encrypt data using AES-GCM with the given passphrase.
    private func encrypt(_ data: Data, passphrase: String) throws -> Data {
        let key = deriveKey(from: passphrase)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw BackupError.encryptionFailed
        }
        // Prepend a magic header so we can detect encrypted vs plain backups
        var result = Data("SAMENC1".utf8)
        result.append(combined)
        return result
    }

    /// Decrypt data using AES-GCM with the given passphrase.
    private func decrypt(_ data: Data, passphrase: String) throws -> Data {
        let header = Data("SAMENC1".utf8)
        guard data.starts(with: header) else {
            // Not encrypted — return as-is for backward compatibility
            return data
        }
        let encryptedData = data.dropFirst(header.count)
        let key = deriveKey(from: passphrase)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Errors
// ─────────────────────────────────────────────────────────────────────

enum BackupError: LocalizedError, Equatable {
    case unsupportedFormat(Int)
    case encryptionFailed
    case decryptionFailed
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let v):
            return "Unsupported backup format version \(v). This backup was created with a newer version of SAM."
        case .encryptionFailed:
            return "Failed to encrypt backup data"
        case .decryptionFailed:
            return "Failed to decrypt backup — check your passphrase"
        case .authenticationRequired:
            return "This backup is encrypted. Please enter the passphrase."
        }
    }
}
