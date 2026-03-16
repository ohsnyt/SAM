//
//  NoteAnalysisCoordinator.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase H: Notes & Note Intelligence
//
//  Orchestrates: note saved → LLM analysis → store results → create evidence.
//  Follows standard coordinator API pattern from context.md §2.4.
//

import Foundation
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "NoteAnalysisCoordinator")

@MainActor
@Observable
final class NoteAnalysisCoordinator {

    // MARK: - Singleton

    static let shared = NoteAnalysisCoordinator()

    private init() {}

    // MARK: - Dependencies

    private let analysisService = NoteAnalysisService.shared
    private let notesRepository = NotesRepository.shared
    private let evidenceRepository = EvidenceRepository.shared
    private let peopleRepository = PeopleRepository.shared
    private let contextsRepository = ContextsRepository.shared

    // MARK: - Observable State

    /// Current analysis status
    var analysisStatus: AnalysisStatus = .idle

    /// Timestamp of last successful analysis
    var lastAnalyzedAt: Date?

    /// Count of notes analyzed in last batch operation
    var lastAnalysisCount: Int = 0

    /// Error message if analysis failed
    var lastError: String?

    /// Person detected as deceased from note analysis, pending user confirmation
    var deceasedCandidate: DeceasedCandidate?

    /// Holds a person detected as deceased so the UI can prompt the user
    struct DeceasedCandidate: Identifiable {
        let id = UUID()
        let person: SamPerson
        let eventDescription: String
    }

    // MARK: - Model Availability

    /// Check if on-device LLM is available
    func checkModelAvailability() async -> ModelAvailability {
        return await analysisService.checkAvailability()
    }

    // MARK: - Analysis Operations

    /// Analyze a single note immediately after save
    func analyzeNote(_ note: SamNote) async {
        guard !note.content.isEmpty else {
            logger.debug("Skipping analysis of empty note")
            return
        }

        analysisStatus = .analyzing
        lastError = nil

        do {
            // Step 1: Build role context from linked people
            let roleContext = buildRoleContext(for: note)

            // Step 2: Call LLM service with role context
            let analysis = try await analysisService.analyzeNote(content: note.content, roleContext: roleContext)

            // Step 3: Convert DTO to model types
            let mentions = analysis.people.map { dto in
                ExtractedPersonMention(
                    name: dto.name,
                    role: dto.role,
                    relationshipTo: dto.relationshipTo,
                    contactUpdates: dto.contactUpdates.map { updateDTO in
                        ContactFieldUpdate(
                            field: ContactFieldUpdate.ContactUpdateField(rawValue: updateDTO.field) ?? .nickname,
                            value: updateDTO.value,
                            confidence: updateDTO.confidence
                        )
                    },
                    matchedPersonID: nil,  // Will auto-match below
                    confidence: dto.confidence
                )
            }

            let actionItems = analysis.actionItems.map { dto in
                NoteActionItem(
                    type: NoteActionItem.ActionType(rawValue: dto.type) ?? .generalFollowUp,
                    description: dto.description,
                    suggestedText: dto.suggestedText,
                    suggestedChannel: dto.suggestedChannel.flatMap { NoteActionItem.MessageChannel(rawValue: $0) },
                    urgency: NoteActionItem.Urgency(rawValue: dto.urgency) ?? .standard,
                    linkedPersonName: dto.personName,
                    linkedPersonID: nil,  // Will match below
                    status: .pending
                )
            }

            let discoveredRelationships = analysis.discoveredRelationships.map { dto in
                // Use the AI's category to classify; fall back to enum matching for legacy prompts
                let parsedType: DiscoveredRelationship.RelationshipType
                if dto.relationshipCategory == "business" {
                    parsedType = DiscoveredRelationship.RelationshipType(rawValue: dto.relationshipType) ?? .businessPartner
                } else {
                    // Family — pick closest enum case, defaulting to siblingOf as a generic family type
                    parsedType = DiscoveredRelationship.RelationshipType(rawValue: dto.relationshipType) ?? .siblingOf
                }
                return DiscoveredRelationship(
                    personName: dto.personName,
                    relationshipType: parsedType,
                    relatedTo: dto.relatedTo,
                    confidence: dto.confidence
                )
            }

            let lifeEvents = analysis.lifeEvents.map { dto in
                LifeEvent(
                    personName: dto.personName,
                    eventType: dto.eventType,
                    eventDescription: dto.eventDescription,
                    approximateDate: dto.approximateDate,
                    outreachSuggestion: dto.outreachSuggestion,
                    status: .pending
                )
            }

            // Step 4: Auto-match extracted people to existing SamPerson records
            let matchedMentions = try autoMatchPeople(mentions)
            let matchedActions = try autoMatchActions(actionItems)

            // Step 4b: Auto-link unlinked notes to matched people
            if note.linkedPeople.isEmpty {
                let matchedPersonIDs = Set(matchedMentions.compactMap(\.matchedPersonID))
                if !matchedPersonIDs.isEmpty {
                    try notesRepository.updateLinks(
                        note: note,
                        peopleIDs: Array(matchedPersonIDs)
                    )
                    logger.debug("Auto-linked note to \(matchedPersonIDs.count) people from extracted mentions")
                }
            }

            // Step 5: Store analysis results
            try notesRepository.storeAnalysis(
                note: note,
                summary: analysis.summary,
                extractedMentions: matchedMentions,
                extractedActionItems: matchedActions,
                extractedTopics: analysis.topics,
                discoveredRelationships: discoveredRelationships,
                lifeEvents: lifeEvents,
                analysisVersion: analysis.analysisVersion
            )

            // Step 6: Create family references from discovered relationships
            let familyDTOs = analysis.discoveredRelationships.filter { $0.relationshipCategory == "family" }
            createFamilyReferences(from: familyDTOs, note: note)

            // Step 7: Create evidence item from note
            try createEvidenceFromNote(note)

            // Step 8: Refresh relationship summaries for linked people
            for person in note.linkedPeople {
                await refreshRelationshipSummary(for: person)
            }

            // Step 9: Generate follow-up draft if this is a meeting-related note
            await generateFollowUpDraftIfMeeting(note)

            // Step 10: Auto-create outcomes from extracted action items
            await createOutcomesFromAnalysis(note)

            // Step 11: Detect death events and prompt to mark as deceased
            detectDeceasedFromLifeEvents(lifeEvents, linkedPeople: note.linkedPeople)

            // Update state
            analysisStatus = .success
            lastAnalyzedAt = .now
            lastAnalysisCount = 1

        } catch {
            analysisStatus = .failed
            lastError = error.localizedDescription
            logger.error("Analysis failed: \(error)")
        }
    }

    /// Analyze all unanalyzed notes in batch
    func analyzeUnanalyzedNotes() async {
        analysisStatus = .analyzing
        lastError = nil

        do {
            let unanalyzedNotes = try notesRepository.fetchUnanalyzedNotes()

            guard !unanalyzedNotes.isEmpty else {
                analysisStatus = .idle
                return
            }

            logger.debug("Analyzing \(unanalyzedNotes.count) unanalyzed notes")

            var successCount = 0

            for note in unanalyzedNotes {
                await analyzeNote(note)
                if analysisStatus == .success {
                    successCount += 1
                }
            }

            analysisStatus = .success
            lastAnalyzedAt = .now
            lastAnalysisCount = successCount

            logger.info("Batch analysis complete: \(successCount)/\(unanalyzedNotes.count) succeeded")

        } catch {
            analysisStatus = .failed
            lastError = error.localizedDescription
            logger.error("Batch analysis failed: \(error)")
        }
    }

    // MARK: - Deceased Detection

    /// Check life events for a "death" event matching a linked person and surface a prompt
    private func detectDeceasedFromLifeEvents(_ lifeEvents: [LifeEvent], linkedPeople: [SamPerson]) {
        guard !lifeEvents.isEmpty, !linkedPeople.isEmpty else { return }

        for event in lifeEvents where event.eventType == "death" {
            // Match by name against linked people who are still active
            if let match = linkedPeople.first(where: {
                $0.lifecycleStatus == .active &&
                $0.displayName.localizedCaseInsensitiveContains(event.personName)
            }) {
                deceasedCandidate = DeceasedCandidate(
                    person: match,
                    eventDescription: event.eventDescription
                )
                logger.debug("Detected death event for \(match.displayName), prompting user")
                return // Only one prompt at a time
            }
        }
    }

    /// User confirmed: mark the person as deceased
    func confirmDeceased(_ candidate: DeceasedCandidate) {
        let previousStatus = candidate.person.lifecycleStatusRawValue
        let personName = candidate.person.displayNameCache ?? candidate.person.displayName

        let snapshot = LifecycleChangeSnapshot(
            personID: candidate.person.id,
            personName: personName,
            previousStatusRawValue: previousStatus,
            newStatusRawValue: ContactLifecycleStatus.deceased.rawValue
        )
        if let entry = try? UndoRepository.shared.capture(
            operation: .statusChanged,
            entityType: .person,
            entityID: candidate.person.id,
            entityDisplayName: personName,
            snapshot: snapshot
        ) {
            UndoCoordinator.shared.showToast(for: entry)
        }

        try? PeopleRepository.shared.setLifecycleStatus(.deceased, for: candidate.person)
        NotificationCenter.default.post(name: .samPersonDidChange, object: nil)
        deceasedCandidate = nil
    }

    /// User dismissed the deceased prompt
    func dismissDeceasedCandidate() {
        deceasedCandidate = nil
    }

    // MARK: - Relationship Summary

    /// Refresh the AI-generated relationship summary for a person.
    /// Called after note analysis completes for notes linked to this person.
    func refreshRelationshipSummary(for person: SamPerson) async {
        let displayName = person.displayNameCache ?? person.displayName
        do {
            // Gather notes
            let notes = try notesRepository.fetchNotes(forPerson: person)
            let noteContents = notes.prefix(10).map { $0.content }

            // Gather recent topics from analyzed notes
            let recentTopics = Array(Set(notes.flatMap { $0.extractedTopics })).prefix(10)

            // Gather pending action items
            let pendingActions = notes.flatMap { $0.extractedActionItems }
                .filter { $0.status == .pending }
                .prefix(5)
                .map { $0.description }

            // Get relationship health info
            let health = MeetingPrepCoordinator.shared.computeHealth(for: person)
            let healthInfo = "\(health.statusLabel), trend: \(health.trend)"

            // Gather communications evidence (iMessage, calls, FaceTime)
            let commsSummaries = gatherCommunicationsSummaries(for: person)

            guard !noteContents.isEmpty || !commsSummaries.isEmpty else {
                logger.debug("No notes or communications for \(displayName, privacy: .private), skipping summary")
                return
            }

            let summary = try await analysisService.generateRelationshipSummary(
                personName: displayName,
                role: person.roleBadges.first,
                notes: noteContents,
                recentTopics: Array(recentTopics),
                pendingActions: Array(pendingActions),
                healthInfo: healthInfo,
                communicationsSummaries: commsSummaries
            )

            // Store on person
            person.relationshipSummary = summary.overview
            person.relationshipKeyThemes = summary.keyThemes
            person.relationshipNextSteps = summary.suggestedNextSteps
            person.summaryUpdatedAt = .now

            logger.debug("Updated relationship summary for \(displayName, privacy: .private)")
        } catch {
            logger.debug("Relationship summary skipped for \(displayName, privacy: .public): \(error.localizedDescription)")
        }
    }

    // MARK: - Communications Evidence

    /// Gather recent communications evidence snippets for a person to include in relationship summary.
    private func gatherCommunicationsSummaries(for person: SamPerson) -> [String] {
        let commsSources: Set<EvidenceSource> = [.iMessage, .phoneCall, .faceTime, .whatsApp, .whatsAppCall]
        let personID = person.id

        guard let allEvidence = try? evidenceRepository.fetchAll() else { return [] }

        let commsEvidence = allEvidence.filter { item in
            commsSources.contains(item.source)
            && item.linkedPeople.contains(where: { $0.id == personID })
        }

        // Take up to 15 most recent, format as summaries
        return commsEvidence.prefix(15).compactMap { item in
            let dateStr = item.occurredAt.formatted(date: .abbreviated, time: .shortened)
            let source = item.source == .iMessage ? "iMessage" : item.source == .phoneCall ? "Phone call" : "FaceTime"
            if !item.snippet.isEmpty {
                return "[\(dateStr)] \(source): \(item.snippet)"
            } else if !item.title.isEmpty {
                return "[\(dateStr)] \(source): \(item.title)"
            }
            return nil
        }
    }

    // MARK: - Role Context

    /// Build role context from linked people on a note for LLM prompt injection.
    private func buildRoleContext(for note: SamNote) -> NoteAnalysisService.RoleContext? {
        let people = note.linkedPeople.filter { !$0.isMe }
        guard let primary = people.first else { return nil }

        let primaryName = primary.displayNameCache ?? primary.displayName
        let primaryRole = primary.roleBadges.first ?? "Contact"

        let others = people.dropFirst().map { person in
            (
                name: person.displayNameCache ?? person.displayName,
                role: person.roleBadges.first ?? "Contact"
            )
        }

        return NoteAnalysisService.RoleContext(
            primaryPersonName: primaryName,
            primaryRole: primaryRole,
            otherLinkedPeople: others
        )
    }

    // MARK: - Auto-Matching

    /// Auto-match extracted person mentions to existing SamPerson records by name
    private func autoMatchPeople(_ mentions: [ExtractedPersonMention]) throws -> [ExtractedPersonMention] {
        let allPeople = try peopleRepository.fetchAll()

        return mentions.map { mention in
            var matched = mention

            // Try to match by display name (case-insensitive)
            if let person = allPeople.first(where: {
                ($0.displayNameCache ?? $0.displayName).lowercased() == mention.name.lowercased()
            }) {
                matched.matchedPersonID = person.id
                logger.debug("Auto-matched '\(mention.name, privacy: .private)' to \(person.displayNameCache ?? person.displayName, privacy: .private)")
            }

            return matched
        }
    }

    /// Auto-match action items to people by name
    private func autoMatchActions(_ actions: [NoteActionItem]) throws -> [NoteActionItem] {
        let allPeople = try peopleRepository.fetchAll()

        return actions.map { action in
            var matched = action

            if let personName = action.linkedPersonName,
               let person = allPeople.first(where: {
                   ($0.displayNameCache ?? $0.displayName).lowercased() == personName.lowercased()
               }) {
                matched.linkedPersonID = person.id
                logger.debug("Auto-matched action to \(person.displayNameCache ?? person.displayName, privacy: .private)")
            }

            return matched
        }
    }

    // MARK: - Follow-Up Draft

    /// Generate a follow-up message draft if the note is linked to a person
    /// who has a recent calendar event (meeting). Best-effort — failures are logged and ignored.
    private func generateFollowUpDraftIfMeeting(_ note: SamNote) async {
        // Must have at least one linked person (excluding Me)
        let linkedNonMe = note.linkedPeople.filter { !$0.isMe }
        guard let primaryPerson = linkedNonMe.first else { return }

        // Check if this person has a recent calendar event (within 24 hours)
        let recentMeeting = evidenceRepository.findRecentMeeting(
            forPersonID: primaryPerson.id,
            maxWindow: 86400  // 24 hours
        )
        guard recentMeeting != nil else { return }

        let personName = primaryPerson.displayNameCache ?? primaryPerson.displayName
        let role = primaryPerson.roleBadges.first

        do {
            let draft = try await analysisService.generateFollowUpDraft(
                noteContent: note.content,
                personName: personName,
                role: role
            )
            note.followUpDraft = draft
            logger.debug("Generated follow-up draft for note linked to \(personName, privacy: .private)")
        } catch {
            logger.debug("Follow-up draft skipped for \(personName, privacy: .private): \(error.localizedDescription)")
        }
    }

    // MARK: - Auto Outcome Creation (Step 10)

    /// Create outcomes from extracted action items after analysis.
    /// Max 5 outcomes per note to avoid flooding the Action Queue.
    private func createOutcomesFromAnalysis(_ note: SamNote) async {
        let pendingActions = note.extractedActionItems.filter { $0.status == .pending && $0.linkedPersonID != nil }
        guard !pendingActions.isEmpty else { return }

        let outcomeRepo = OutcomeRepository.shared
        var createdCount = 0

        for action in pendingActions {
            guard createdCount < 5 else { break }
            guard let personID = action.linkedPersonID else { continue }

            // Map action type to outcome kind
            let outcomeKind: OutcomeKind
            switch action.type {
            case .generalFollowUp, .sendReminder:
                outcomeKind = .followUp
            case .createProposal:
                outcomeKind = .proposal
            case .scheduleMeeting:
                outcomeKind = .preparation
            case .sendCongratulations:
                outcomeKind = .outreach
            case .updateContact, .updateBeneficiary:
                outcomeKind = .compliance
            }

            // Dedup: skip if a similar outcome already exists
            if let hasSimilar = try? outcomeRepo.hasSimilarOutcome(kind: outcomeKind, personID: personID),
               hasSimilar {
                continue
            }

            // Fetch person for linking
            guard let person = try? peopleRepository.fetch(id: personID) else { continue }

            // Map urgency to deadline
            let deadline: Date?
            switch action.urgency {
            case .immediate:
                deadline = Calendar.current.date(byAdding: .hour, value: 4, to: .now)
            case .soon:
                deadline = Calendar.current.date(byAdding: .day, value: 3, to: .now)
            case .standard:
                deadline = Calendar.current.date(byAdding: .day, value: 7, to: .now)
            case .low:
                deadline = Calendar.current.date(byAdding: .day, value: 14, to: .now)
            }

            let outcome = SamOutcome(
                title: action.description,
                rationale: "Extracted from note analysis",
                outcomeKind: outcomeKind,
                deadlineDate: deadline,
                sourceInsightSummary: "Auto-created from note action item",
                suggestedNextStep: action.suggestedText,
                linkedPerson: person
            )

            // Set draft message text if available
            if let draft = action.suggestedText {
                outcome.draftMessageText = draft
            }

            do {
                try outcomeRepo.upsert(outcome: outcome)
                createdCount += 1
                logger.debug("Auto-created outcome '\(action.description)' for \(person.displayNameCache ?? person.displayName, privacy: .private)")
            } catch {
                logger.debug("Failed to create outcome from action: \(error.localizedDescription)")
            }
        }

        if createdCount > 0 {
            logger.info("Created \(createdCount) outcome(s) from note analysis")
        }
    }

    // MARK: - Relationship Type Normalization

    /// Maps common AI-generated relationship type variants to canonical enum values.
    /// The LLM sometimes returns gendered, hyphenated, or in-law forms.
    /// Normalizes hyphens to underscores first so both "brother-in-law" and "brother_in_law" match.
    private static func normalizeRelationshipType(_ raw: String) -> DiscoveredRelationship.RelationshipType? {
        let key = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        switch key {
        case "daughter_of", "son_of", "child_of",
             "stepson_of", "stepdaughter_of", "stepchild_of":
            return .childOf
        case "father_of", "mother_of", "parent_of",
             "stepfather_of", "stepmother_of", "stepparent_of":
            return .parentOf
        case "wife_of", "husband_of", "spouse_of":
            return .spouseOf
        case "brother_of", "sister_of", "sibling_of",
             "half_brother_of", "half_sister_of",
             "brother_in_law", "sister_in_law",
             "brother_in_law_of", "sister_in_law_of":
            return .siblingOf
        case "father_in_law", "mother_in_law",
             "father_in_law_of", "mother_in_law_of":
            return .parentOf
        case "son_in_law", "daughter_in_law",
             "son_in_law_of", "daughter_in_law_of":
            return .childOf
        case "referral_by", "referred_by":
            return .referralBy
        case "referred_to":
            return .referredTo
        case "business_partner", "partner_of", "colleague_of":
            return .businessPartner
        default:
            return nil
        }
    }

    // MARK: - Family References

    /// Create FamilyReference entries on SamPerson from discovered family relationships.
    /// Uses the AI's freeform label directly — no enum mapping needed.
    ///
    /// The AI returns: `personName` IS `relationshipType` OF `relatedTo`.
    /// Either name could be the note's linked person. We figure out which is the "owner"
    /// (linked person on the note) and store a reference to the OTHER person.
    private func createFamilyReferences(from familyDTOs: [DiscoveredRelationshipDTO], note: SamNote) {
        guard !familyDTOs.isEmpty else { return }

        let linkedPeople = note.linkedPeople.filter { !$0.isMe }
        let allPeople = (try? peopleRepository.fetchAll()) ?? []

        for dto in familyDTOs {
            // Guard: both names identical = true self-reference
            guard dto.personName.lowercased() != dto.relatedTo.lowercased() else {
                logger.debug("Skipping self-reference: \(dto.personName) == \(dto.relatedTo)")
                continue
            }

            // Determine which name is the owner (linked person on this note) and which is the "other"
            // AI says: personName IS relationshipType OF relatedTo
            // e.g. "Albert Vasquez is brother_of Anthony Russo"
            let ownerFromPersonName = linkedPeople.first {
                ($0.displayNameCache ?? $0.displayName).lowercased() == dto.personName.lowercased()
            }
            let ownerFromRelatedTo = linkedPeople.first {
                ($0.displayNameCache ?? $0.displayName).lowercased() == dto.relatedTo.lowercased()
            }

            // The referenced (other) person's name and the relationship label depend on
            // which side the owner is on.
            let owner: SamPerson
            let referencedName: String
            let relationshipLabel: String

            let rawType = dto.relationshipType

            if let matched = ownerFromRelatedTo {
                // Owner is relatedTo: "personName is brother_of [owner]"
                // → store personName on owner, label = raw AI string
                owner = matched
                referencedName = dto.personName
                relationshipLabel = Self.formatRelationshipLabel(rawType)

            } else if let matched = ownerFromPersonName {
                // Owner is personName: "[owner] is brother_of relatedTo"
                // → store relatedTo on owner, label = raw AI string (describes relatedTo's role)
                owner = matched
                referencedName = dto.relatedTo
                relationshipLabel = Self.formatRelationshipLabel(rawType)

            } else if let fallback = linkedPeople.first {
                owner = fallback
                referencedName = dto.personName
                relationshipLabel = Self.formatRelationshipLabel(rawType)
            } else {
                continue
            }

            // Check if this family reference already exists on the owner
            let nameKey = referencedName.lowercased()
            let alreadyExists = owner.familyReferences.contains {
                $0.name.lowercased() == nameKey
            }
            guard !alreadyExists else { continue }

            // Try to match the referenced person to an existing SamPerson
            let matchedPerson = allPeople.first {
                ($0.displayNameCache ?? $0.displayName).lowercased() == nameKey
            }

            let ref = FamilyReference(
                name: referencedName,
                relationship: relationshipLabel,
                linkedPersonID: matchedPerson?.id,
                discoveredAt: .now,
                sourceNoteID: note.id
            )

            owner.familyReferences.append(ref)
            let ownerDisplay = owner.displayNameCache ?? owner.displayName
            logger.debug("Created family reference: \(referencedName) is \(relationshipLabel) of \(ownerDisplay)")

            // Create "Review in Graph" outcome
            createGraphReviewOutcome(
                personName: referencedName,
                relationship: relationshipLabel,
                owner: owner
            )

            // Also create the reciprocal reference if the referenced person exists (and is different)
            if let matched = matchedPerson, matched.id != owner.id {
                // Use the same label — it's freeform and describes the relationship
                let reciprocalRel = relationshipLabel
                let ownerName = owner.displayNameCache ?? owner.displayName
                let reciprocalExists = matched.familyReferences.contains {
                    $0.name.lowercased() == ownerName.lowercased()
                }
                if !reciprocalExists {
                    let reciprocal = FamilyReference(
                        name: ownerName,
                        relationship: reciprocalRel,
                        linkedPersonID: owner.id,
                        discoveredAt: .now,
                        sourceNoteID: note.id
                    )
                    matched.familyReferences.append(reciprocal)
                    logger.debug("Created reciprocal family reference: \(ownerName) is \(reciprocalRel) of \(matched.displayNameCache ?? matched.displayName)")
                }
            }
        }
    }

    /// Create a "Review in Graph" outcome for a discovered family relationship.
    private func createGraphReviewOutcome(personName: String, relationship: String, owner: SamPerson) {
        let outcomeRepo = OutcomeRepository.shared
        let ownerName = owner.displayNameCache ?? owner.displayName

        // Dedup: skip if a similar graph-review outcome already exists for this person
        if let hasSimilar = try? outcomeRepo.hasSimilarOutcome(kind: .followUp, personID: owner.id),
           hasSimilar {
            return
        }

        let outcome = SamOutcome(
            title: "Confirm relationship: \(personName) is \(relationship) of \(ownerName)",
            rationale: "A family relationship was discovered in a note. Open the Relationship Graph to review and confirm it.",
            outcomeKind: .followUp,
            priorityScore: 0.4,
            sourceInsightSummary: "Family relationship discovered from note analysis",
            suggestedNextStep: "Go to People → Graph and look for the dashed pink line connecting \(ownerName) and \(personName). Right-click or double-click to confirm.",
            linkedPerson: owner
        )
        outcome.actionLane = .reviewGraph

        do {
            try outcomeRepo.upsert(outcome: outcome)
            logger.debug("Created graph review outcome for \(personName) ↔ \(ownerName)")
        } catch {
            logger.debug("Failed to create graph review outcome: \(error.localizedDescription)")
        }
    }

    /// Formats a raw AI relationship_type string into a human-readable label.
    /// Strips trailing "_of", replaces underscores with hyphens for compound words
    /// (e.g. "brother_in_law") or spaces otherwise. No enumeration of specific labels needed.
    private static func formatRelationshipLabel(_ raw: String) -> String {
        var label = raw.lowercased()

        // Strip trailing "_of" or "-of"
        for suffix in ["_of", "-of"] {
            if label.hasSuffix(suffix) {
                label = String(label.dropLast(suffix.count))
            }
        }

        // Compound words with "in_law" or "step" → use hyphens
        if label.contains("_in_") || label.contains("-in-") {
            return label
                .replacingOccurrences(of: "_", with: "-")
        }

        // Everything else: underscores/hyphens → spaces
        return label
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    /// Create evidence item from analyzed note
    private func createEvidenceFromNote(_ note: SamNote) throws {
        // Pass IDs so the evidence repository can re-fetch in its own context,
        // avoiding "Illegal attempt to insert a model in to a different model context"
        let linkedPeopleIDs = note.linkedPeople.map { $0.id }
        let linkedContextIDs = note.linkedContexts.map { $0.id }

        _ = try evidenceRepository.createByIDs(
            sourceUID: "note:\(note.id.uuidString)",
            source: .note,
            occurredAt: note.createdAt,
            title: note.summary ?? String(note.content.prefix(50)),
            snippet: note.summary ?? String(note.content.prefix(200)),
            bodyText: note.content,
            linkedPeopleIDs: linkedPeopleIDs,
            linkedContextIDs: linkedContextIDs
        )
    }

    // MARK: - Status Enum

    enum AnalysisStatus: Equatable {
        case idle
        case analyzing
        case success
        case failed

        var displayText: String {
            switch self {
            case .idle: return "Ready"
            case .analyzing: return "Analyzing..."
            case .success: return "Analyzed"
            case .failed: return "Failed"
            }
        }

        var icon: String {
            switch self {
            case .idle: return "brain"
            case .analyzing: return "brain.head.profile"
            case .success: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }
}
