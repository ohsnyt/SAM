//
//  BackupPayload.swift
//  SAM_crm
//
//  The JSON envelope that gets encrypted into a .sam-backup file.
//  Contains a snapshot of all three runtime stores plus metadata so we
//  can version the format and reject incompatible files on restore.
//

import Foundation
import SwiftData

/// Top-level container for a SAM backup.
/// Version is bumped whenever the shape of any nested model changes in a
/// way that would break decoding.  The restore path checks this before
/// attempting to deserialise the inner arrays.
struct BackupPayload: Codable {
    // MARK: - Versioning
    static let currentVersion = 1

    /// Format version. Bump when breaking decode changes occur.
    let version: Int

    /// Human-readable creation timestamp (ISO 8601 with fractional seconds).
    let createdAt: String

    // MARK: - Snapshots (DTOs)
    let evidence: [BackupEvidenceItem]
    let people:   [BackupPerson]
    let contexts: [BackupContext]

    // MARK: - Factory (SwiftData)
    @MainActor
    static func current(using container: ModelContainer) -> BackupPayload {
        let context = ModelContext(container)

        let people: [SamPerson] = (try? context.fetch(FetchDescriptor<SamPerson>())) ?? []
        let contextsModels: [SamContext] = (try? context.fetch(FetchDescriptor<SamContext>())) ?? []
        let evidenceModels: [SamEvidenceItem] = (try? context.fetch(FetchDescriptor<SamEvidenceItem>())) ?? []

        let dtoPeople   = people.map(BackupPerson.init)
        let dtoContexts = contextsModels.map(BackupContext.init)
        let dtoEvidence = evidenceModels.map(BackupEvidenceItem.init)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return BackupPayload(
            version: BackupPayload.currentVersion,
            createdAt: iso.string(from: .now),
            evidence: dtoEvidence,
            people: dtoPeople,
            contexts: dtoContexts
        )
    }

    // MARK: - Restore (SwiftData)
    @MainActor
    func restore(into container: ModelContainer) {
        let context = ModelContext(container)

        // Delete in reverse-dependency order: Evidence first (it holds
        // relationships to People and Contexts), then Contexts, then People.
        // Deleting a parent before its dependents can trigger unexpected
        // cascade behaviour in SwiftData.
        let _ = try? context.delete(model: SamEvidenceItem.self)
        let _ = try? context.delete(model: SamContext.self)
        let _ = try? context.delete(model: SamPerson.self)

        // Recreate in order: people, contexts, evidence (to satisfy references)
        let peopleModels = people.map { $0.makeModel() }
        let contextModels = contexts.map { $0.makeModel() }
        let evidenceModels = evidence.map { $0.makeModel() }

        for m in peopleModels { context.insert(m) }
        for m in contextModels { context.insert(m) }
        for m in evidenceModels { context.insert(m) }

        // Re-link evidence relationships by UUID after all models are inserted
        let peopleByID = Dictionary(uniqueKeysWithValues: peopleModels.map { ($0.id, $0) })
        let contextsByID = Dictionary(uniqueKeysWithValues: contextModels.map { ($0.id, $0) })

        for (i, dto) in evidence.enumerated() {
            guard i < evidenceModels.count else { continue }
            let model = evidenceModels[i]
            // Link people
            model.linkedPeople = dto.linkedPeople.compactMap { peopleByID[$0] }
            // Link contexts
            model.linkedContexts = dto.linkedContexts.compactMap { contextsByID[$0] }
        }

        try? context.save()
    }
}

// MARK: - Backup DTOs

struct BackupPerson: Codable, Identifiable {
    let id: UUID
    let displayName: String
    let roleBadges: [String]
    let contactIdentifier: String?
    let email: String?
    let consentAlertsCount: Int
    let reviewAlertsCount: Int
    let responsibilityNotes: [String]
    let recentInteractions: [InteractionChip]
    let insights: [PersonInsight]
    let contextChips: [ContextChip]

    init(from model: SamPerson) {
        self.id = model.id
        self.displayName = model.displayName
        self.roleBadges = model.roleBadges
        self.contactIdentifier = model.contactIdentifier
        self.email = model.email
        self.consentAlertsCount = model.consentAlertsCount
        self.reviewAlertsCount = model.reviewAlertsCount
        self.responsibilityNotes = model.responsibilityNotes
        self.recentInteractions = model.recentInteractions
        self.insights = model.insights
        self.contextChips = model.contextChips
    }

    // Convenience for mapping
    init(id: UUID, displayName: String, roleBadges: [String], contactIdentifier: String?, email: String?, consentAlertsCount: Int, reviewAlertsCount: Int, responsibilityNotes: [String], recentInteractions: [InteractionChip], insights: [PersonInsight], contextChips: [ContextChip]) {
        self.id = id
        self.displayName = displayName
        self.roleBadges = roleBadges
        self.contactIdentifier = contactIdentifier
        self.email = email
        self.consentAlertsCount = consentAlertsCount
        self.reviewAlertsCount = reviewAlertsCount
        self.responsibilityNotes = responsibilityNotes
        self.recentInteractions = recentInteractions
        self.insights = insights
        self.contextChips = contextChips
    }

    func makeModel() -> SamPerson {
        let m = SamPerson(
            id: id,
            displayName: displayName,
            roleBadges: roleBadges,
            contactIdentifier: contactIdentifier,
            email: email,
            consentAlertsCount: consentAlertsCount,
            reviewAlertsCount: reviewAlertsCount
        )
        m.responsibilityNotes = responsibilityNotes
        m.recentInteractions = recentInteractions
        m.insights = insights
        m.contextChips = contextChips
        return m
    }
}
struct BackupContext: Codable, Identifiable {
    let id: UUID
    let name: String
    let kind: ContextKind
    let consentAlertCount: Int
    let reviewAlertCount: Int
    let followUpAlertCount: Int
    let productCards: [ContextProductModel]
    let recentInteractions: [InteractionModel]
    let insights: [ContextInsight]

    init(from model: SamContext) {
        self.id = model.id
        self.name = model.name
        self.kind = model.kind
        self.consentAlertCount = model.consentAlertCount
        self.reviewAlertCount = model.reviewAlertCount
        self.followUpAlertCount = model.followUpAlertCount
        self.productCards = model.productCards
        self.recentInteractions = model.recentInteractions
        self.insights = model.insights
    }

    func makeModel() -> SamContext {
        let m = SamContext(id: id, name: name, kind: kind, consentAlertCount: consentAlertCount, reviewAlertCount: reviewAlertCount, followUpAlertCount: followUpAlertCount)
        m.productCards = productCards
        m.recentInteractions = recentInteractions
        m.insights = insights
        return m
    }
}

struct BackupEvidenceItem: Codable, Identifiable {
    let id: UUID
    let sourceUID: String?
    let source: EvidenceSource
    let state: EvidenceTriageState
    let occurredAt: Date
    let title: String
    let snippet: String
    let bodyText: String?
    let signals: [EvidenceSignal]
    let participantHints: [ParticipantHint]
    let proposedLinks: [ProposedLink]
    let linkedPeople: [UUID]
    let linkedContexts: [UUID]

    init(from model: SamEvidenceItem) {
        self.id = model.id
        self.sourceUID = model.sourceUID
        self.source = model.source
        self.state = model.state
        self.occurredAt = model.occurredAt
        self.title = model.title
        self.snippet = model.snippet
        self.bodyText = model.bodyText
        self.signals = model.signals
        self.participantHints = model.participantHints
        self.proposedLinks = model.proposedLinks
        self.linkedPeople = model.linkedPeople.map { $0.id }
        self.linkedContexts = model.linkedContexts.map { $0.id }
    }

    func makeModel() -> SamEvidenceItem {
        SamEvidenceItem(
            id: id,
            state: state,
            sourceUID: sourceUID,
            source: source,
            occurredAt: occurredAt,
            title: title,
            snippet: snippet,
            bodyText: bodyText,
            participantHints: participantHints,
            signals: signals,
            proposedLinks: proposedLinks
        )
    }
}

