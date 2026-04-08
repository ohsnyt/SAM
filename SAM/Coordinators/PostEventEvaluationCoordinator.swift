//
//  PostEventEvaluationCoordinator.swift
//  SAM
//
//  Created on April 7, 2026.
//  Orchestrates post-event evaluation: chat import, feedback import,
//  participant matching, AI analysis, and outcome generation.
//

import Foundation
import SwiftData
import os.log

@MainActor @Observable
final class PostEventEvaluationCoordinator {

    // MARK: - Singleton

    static let shared = PostEventEvaluationCoordinator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PostEventEvaluation")

    private init() {}

    // MARK: - State

    var evaluationStatus: EvaluationStatus = .pending
    var progressMessage: String = ""
    var lastError: String?

    /// Participants needing manual review after import (unmatched names).
    var pendingParticipantReviews: [ChatParticipantAnalysis] = []

    /// Whether a review sheet should be presented.
    var showParticipantReview = false

    /// Whether the feedback column mapping sheet should be presented.
    var showFeedbackColumnMapping = false

    /// Headers from the last CSV import, for column mapping UI.
    var csvHeaders: [String] = []
    var csvRows: [ParsedFeedbackRow] = []

    /// The event currently being evaluated.
    private(set) var currentEvent: SamEvent?
    private(set) var currentEvaluation: EventEvaluation?

    // MARK: - Chat Import

    /// Import a Zoom chat transcript and run analysis.
    func importChatTranscript(url: URL, for event: SamEvent) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        currentEvent = event
        evaluationStatus = .importing
        progressMessage = "Parsing chat transcript..."
        lastError = nil

        do {
            let (participants, _) = try await ZoomChatParserService.shared.parse(url: url)

            // Get or create evaluation
            let evaluation = getOrCreateEvaluation(for: event)
            currentEvaluation = evaluation

            progressMessage = "Matching participants to contacts..."
            var analyses: [ChatParticipantAnalysis] = []
            var needsReview: [ChatParticipantAnalysis] = []

            for participant in participants {
                var analysis = ChatParticipantAnalysis(
                    displayName: participant.displayName,
                    messageCount: participant.messageCount,
                    reactionCount: participant.reactionCount,
                    questionsAsked: participant.questions
                )

                // Try to match to existing person
                if let match = matchParticipant(name: participant.displayName, event: event) {
                    analysis.matchedPersonID = match.id
                    analysis.isNewPerson = false
                    analysis.needsReview = false

                    // Mark attendance on participation record
                    markAttended(personID: match.id, event: event)
                } else {
                    // Check if this is a host/co-host (skip matching)
                    let isHost = isLikelyHost(participant: participant, allParticipants: participants)
                    if isHost {
                        analysis.inferredRoleRawValue = InferredEventRole.host.rawValue
                        analysis.needsReview = false
                    } else {
                        analysis.needsReview = true
                        needsReview.append(analysis)
                    }
                }

                analyses.append(analysis)
            }

            evaluation.participantAnalyses = analyses
            evaluation.chatParticipantCount = participants.count
            evaluation.chatImportedAt = .now
            evaluation.updatedAt = .now

            saveContext()

            // Show review sheet if there are unmatched participants
            if !needsReview.isEmpty {
                pendingParticipantReviews = needsReview
                showParticipantReview = true
            }

            progressMessage = "Chat imported — \(participants.count) participants found"

            // Run AI analysis if available
            await runChatAnalysis(for: evaluation)

        } catch {
            lastError = error.localizedDescription
            evaluationStatus = .failed
            logger.error("Chat import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Feedback Import

    /// Import a feedback form CSV export. Shows column mapping sheet on first import.
    func importFeedbackCSV(url: URL, for event: SamEvent) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        currentEvent = event
        evaluationStatus = .importing
        progressMessage = "Parsing feedback form..."
        lastError = nil

        do {
            let (headers, rows) = try await FeedbackFormParserService.shared.parse(url: url)

            // Check for saved column mapping
            let mappingKey = feedbackMappingKey(for: event)
            if let savedMapping = loadFeedbackMapping(key: mappingKey) {
                // Use saved mapping directly
                await applyFeedbackMapping(mapping: savedMapping, rows: rows, for: event)
            } else {
                // Show column mapping sheet
                csvHeaders = headers
                csvRows = rows
                showFeedbackColumnMapping = true
                progressMessage = "Map CSV columns to feedback fields"
            }
        } catch {
            lastError = error.localizedDescription
            evaluationStatus = .failed
            logger.error("Feedback CSV import failed: \(error.localizedDescription)")
        }
    }

    /// Apply a column mapping to the previously parsed CSV rows.
    func applyFeedbackMapping(mapping: FeedbackColumnMapping, rows: [ParsedFeedbackRow], for event: SamEvent) async {
        progressMessage = "Mapping feedback responses..."

        let responses = await FeedbackFormParserService.shared.mapResponses(rows: rows, mapping: mapping)

        let evaluation = getOrCreateEvaluation(for: event)
        currentEvaluation = evaluation

        // Match respondents to people
        var matched: [FeedbackResponse] = []
        for var response in responses {
            if let personID = matchRespondent(name: response.respondentName, email: response.respondentEmail, event: event) {
                response.matchedPersonID = personID
            }
            matched.append(response)
        }

        evaluation.feedbackResponses = matched
        evaluation.feedbackResponseCount = matched.count
        evaluation.feedbackImportedAt = .now
        evaluation.updatedAt = .now

        // Compute average rating
        let ratings = matched.compactMap { $0.overallRating?.numericScore }
        if !ratings.isEmpty {
            evaluation.averageOverallRating = ratings.reduce(0, +) / Double(ratings.count)
        }

        // Compute conversion rate
        let total = matched.count
        let yesCount = matched.filter { $0.wouldContinue == .yes }.count
        if total > 0 {
            evaluation.conversionRate = Double(yesCount) / Double(total)
        }

        // Store column mapping as Data for reuse
        if let mappingData = try? JSONEncoder().encode(mapping) {
            evaluation.feedbackColumnMappingData = mappingData
        }

        // Save mapping for future events with same presentation
        let mappingKey = feedbackMappingKey(for: event)
        saveFeedbackMapping(mapping, key: mappingKey)

        saveContext()
        progressMessage = "Feedback imported — \(matched.count) responses"
        evaluationStatus = evaluation.chatImportedAt != nil ? .analyzing : .importing

        logger.info("Feedback imported: \(matched.count) responses, \(yesCount) warm leads")
    }

    // MARK: - Participant Review

    /// Resolve a participant match (called from review sheet).
    func resolveParticipant(analysisID: UUID, matchedPersonID: UUID?, createNew: Bool = false) {
        guard let evaluation = currentEvaluation else { return }

        var analyses = evaluation.participantAnalyses
        guard let index = analyses.firstIndex(where: { $0.id == analysisID }) else { return }

        if let personID = matchedPersonID {
            analyses[index].matchedPersonID = personID
            analyses[index].needsReview = false
            analyses[index].isNewPerson = false

            // Mark attendance
            if let event = currentEvent {
                markAttended(personID: personID, event: event)
            }
        } else if createNew {
            // Create a new SamPerson
            let name = analyses[index].displayName
            if let newPerson = createStandalonePerson(name: name) {
                analyses[index].matchedPersonID = newPerson.id
                analyses[index].isNewPerson = true
                analyses[index].needsReview = false
            }
        } else {
            // Skip — mark as reviewed but unmatched
            analyses[index].needsReview = false
        }

        evaluation.participantAnalyses = analyses
        evaluation.updatedAt = .now
        saveContext()

        // Update pending reviews
        pendingParticipantReviews.removeAll { $0.id == analysisID }
    }

    // MARK: - Full Pipeline

    /// Run the complete evaluation pipeline after all imports are done.
    func finalizeEvaluation(for event: SamEvent) async {
        guard let evaluation = getExistingEvaluation(for: event) else { return }
        currentEvent = event
        currentEvaluation = evaluation

        evaluationStatus = .analyzing
        progressMessage = "Running AI analysis..."

        // Run cross-reference analysis if we have both chat and presentation content
        if evaluation.chatImportedAt != nil {
            await runCrossReferenceAnalysis(for: evaluation, event: event)
        }

        // Generate overall summary
        await generateOverallSummary(for: evaluation, event: event)

        // Generate follow-up outcomes
        await generateOutcomes(for: evaluation, event: event)

        // Update total attendee count
        let attended = event.participations.filter { $0.attended == true }.count
        let chatCount = evaluation.chatParticipantCount
        evaluation.totalAttendeeCount = max(attended, chatCount)

        evaluation.analysisCompletedAt = .now
        evaluation.status = .complete
        evaluation.updatedAt = .now

        saveContext()
        evaluationStatus = .complete
        progressMessage = "Evaluation complete"

        logger.info("Evaluation finalized for event: \(event.title)")
    }

    // MARK: - AI Analysis (Private)

    private func runChatAnalysis(for evaluation: EventEvaluation) async {
        evaluationStatus = .analyzing
        progressMessage = "Analyzing participant engagement..."

        let analyses = evaluation.participantAnalyses
        var updated: [ChatParticipantAnalysis] = []

        for analysis in analyses {
            do {
                let enriched = try await EventEvaluationAnalysisService.shared
                    .analyzeParticipant(analysis)
                updated.append(enriched)
            } catch {
                logger.warning("Analysis failed for \(analysis.displayName): \(error.localizedDescription)")
                updated.append(analysis)
            }
        }

        // Extract top questions across all participants
        let allQuestions = updated.flatMap(\.questionsAsked)
            .filter { !$0.isEmpty }
        evaluation.topQuestions = Array(allQuestions.prefix(10))

        evaluation.participantAnalyses = updated
        evaluation.updatedAt = .now
        saveContext()

        progressMessage = "Chat analysis complete"
    }

    private func runCrossReferenceAnalysis(for evaluation: EventEvaluation, event: SamEvent) async {
        progressMessage = "Analyzing content effectiveness..."

        // Gather presentation content
        let presentationContext = event.presentation?.contentSummary ?? ""
        let talkingPoints = event.presentation?.keyTalkingPoints ?? []
        let questions = evaluation.topQuestions

        guard !questions.isEmpty else { return }

        do {
            let (gaps, effective) = try await EventEvaluationAnalysisService.shared
                .crossReferenceAnalysis(
                    questions: questions,
                    presentationSummary: presentationContext,
                    talkingPoints: talkingPoints,
                    eventTitle: event.title
                )
            evaluation.contentGapSummary = gaps
            evaluation.effectiveSectionsSummary = effective
            evaluation.updatedAt = .now
            saveContext()
        } catch {
            logger.warning("Cross-reference analysis failed: \(error.localizedDescription)")
        }
    }

    private func generateOverallSummary(for evaluation: EventEvaluation, event: SamEvent) async {
        progressMessage = "Generating event summary..."

        do {
            let summary = try await EventEvaluationAnalysisService.shared
                .generateEventSummary(
                    eventTitle: event.title,
                    participantCount: evaluation.chatParticipantCount,
                    feedbackCount: evaluation.feedbackResponseCount,
                    averageRating: evaluation.averageOverallRating,
                    conversionRate: evaluation.conversionRate,
                    topQuestions: evaluation.topQuestions,
                    contentGaps: evaluation.contentGapSummary,
                    effectiveSections: evaluation.effectiveSectionsSummary
                )
            evaluation.overallSummary = summary
            evaluation.updatedAt = .now
            saveContext()
        } catch {
            logger.warning("Summary generation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Outcome Generation

    private func generateOutcomes(for evaluation: EventEvaluation, event: SamEvent) async {
        progressMessage = "Creating follow-up actions..."

        let outcomeRepo = OutcomeRepository.shared

        // Resolve people in the outcome repository's context
        for analysis in evaluation.participantAnalyses {
            guard let personID = analysis.matchedPersonID else { continue }
            guard analysis.inferredRole == .attendee else { continue }
            guard let person = try? PeopleRepository.shared.fetch(id: personID) else { continue }

            // Check for duplicate before creating
            if (try? outcomeRepo.hasSimilarOutcome(kind: .followUp, personID: personID, withinHours: 168)) == true {
                continue
            }

            // Generate outcomes based on conversion signals
            for signal in analysis.conversionSignals {
                let outcome = SamOutcome(
                    title: "Follow up with \(analysis.displayName): \(signal)",
                    rationale: "Detected during post-event evaluation of \"\(event.title)\". \(analysis.displayName) showed interest: \(signal)",
                    outcomeKind: .followUp,
                    priorityScore: analysis.engagementLevel == .high ? 0.9 : 0.7,
                    sourceInsightSummary: "Post-event evaluation: \(event.title)",
                    linkedPerson: person
                )
                outcome.linkedEvent = event
                _ = try? outcomeRepo.upsert(outcome: outcome)
            }

            // High-engagement attendees without conversion signals still get a thank-you
            if analysis.conversionSignals.isEmpty && analysis.engagementLevel == .high {
                let outcome = SamOutcome(
                    title: "Send thank-you to \(analysis.displayName)",
                    rationale: "\(analysis.displayName) was highly engaged at \"\(event.title)\" — \(analysis.messageCount) messages, asked \(analysis.questionsAsked.count) questions",
                    outcomeKind: .outreach,
                    priorityScore: 0.6,
                    sourceInsightSummary: "Post-event evaluation: \(event.title)",
                    linkedPerson: person
                )
                outcome.linkedEvent = event
                _ = try? outcomeRepo.upsert(outcome: outcome)
            }
        }

        // Outcomes from feedback responses
        for response in evaluation.feedbackResponses {
            guard let personID = response.matchedPersonID else { continue }
            guard let person = try? PeopleRepository.shared.fetch(id: personID) else { continue }

            if response.wouldContinue == .yes {
                let name = response.respondentName ?? "Attendee"
                let outcome = SamOutcome(
                    title: "Schedule follow-up with \(name)",
                    rationale: "\(name) indicated interest in continuing the conversation after \"\(event.title)\"",
                    outcomeKind: .followUp,
                    priorityScore: 0.95,
                    sourceInsightSummary: "Post-event feedback: wants to schedule",
                    linkedPerson: person
                )
                outcome.linkedEvent = event
                _ = try? outcomeRepo.upsert(outcome: outcome)
            } else if response.wouldContinue == .maybe {
                let name = response.respondentName ?? "Attendee"
                let outcome = SamOutcome(
                    title: "Send more information to \(name)",
                    rationale: "\(name) wants more information before scheduling after \"\(event.title)\"",
                    outcomeKind: .followUp,
                    priorityScore: 0.7,
                    sourceInsightSummary: "Post-event feedback: wants more info",
                    linkedPerson: person
                )
                outcome.linkedEvent = event
                _ = try? outcomeRepo.upsert(outcome: outcome)
            }
        }

        logger.info("Post-event outcomes generated for: \(event.title)")
    }

    // MARK: - Name Matching (Private)

    /// Match a chat participant name to an existing SamPerson.
    /// Priority: event participants first, then all SAM contacts.
    private func matchParticipant(name: String, event: SamEvent) -> SamPerson? {
        let nameLower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Check existing event participations
        for participation in event.participations {
            guard let person = participation.person, !person.isDeleted else { continue }
            if matchesName(person: person, against: nameLower) {
                return person
            }
        }

        // 2. Search all SAM contacts
        guard let context = getContext() else { return nil }
        do {
            let descriptor = FetchDescriptor<SamPerson>()
            let allPeople = try context.fetch(descriptor)
            for person in allPeople where !person.isDeleted {
                if matchesName(person: person, against: nameLower) {
                    return person
                }
            }
        } catch {
            logger.warning("Failed to search contacts: \(error.localizedDescription)")
        }

        return nil
    }

    /// Match a feedback respondent by name or email.
    private func matchRespondent(name: String?, email: String?, event: SamEvent) -> UUID? {
        // Try email match first (most reliable)
        if let email = email?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            guard let context = getContext() else { return nil }
            do {
                let descriptor = FetchDescriptor<SamPerson>()
                let all = try context.fetch(descriptor)
                for person in all where !person.isDeleted {
                    if person.emailAliases.contains(where: { $0.lowercased() == email }) {
                        return person.id
                    }
                    if person.emailCache?.lowercased() == email {
                        return person.id
                    }
                }
            } catch { }
        }

        // Try name match
        if let name = name {
            if let person = matchParticipant(name: name, event: event) {
                return person.id
            }
        }

        return nil
    }

    /// Check if a person's display name matches the given lowercase name.
    private func matchesName(person: SamPerson, against nameLower: String) -> Bool {
        guard let displayName = person.displayNameCache else { return false }
        let personLower = displayName.lowercased()

        // Exact match
        if personLower == nameLower { return true }

        // First + last name match
        let personParts = personLower.split(separator: " ")
        let nameParts = nameLower.split(separator: " ")

        if personParts.count >= 2 && nameParts.count >= 2 {
            // Match first name + last name
            if personParts.first == nameParts.first && personParts.last == nameParts.last {
                return true
            }
        }

        // First name + last initial match
        if personParts.count >= 2 && nameParts.count >= 2 {
            if personParts.first == nameParts.first,
               let personLast = personParts.last, let nameLast = nameParts.last,
               (personLast.hasPrefix(String(nameLast.prefix(1))) || nameLast.hasPrefix(String(personLast.prefix(1)))) {
                // Only match if last initial is the same and one is abbreviated
                if personLast.count == 1 || nameLast.count == 1 {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Host Detection

    /// Determine if a participant is likely a host/co-host based on behavior patterns.
    private func isLikelyHost(participant: ParsedChatParticipant, allParticipants: [ParsedChatParticipant]) -> Bool {
        // Hosts typically: have the most reactions given, respond to many people, share links
        let totalReactions = allParticipants.map(\.reactionCount).reduce(0, +)
        guard totalReactions > 0 else { return false }

        let reactionShare = Double(participant.reactionCount) / Double(totalReactions)
        let hasLinks = participant.messages.contains { $0.text.contains("http") || $0.text.contains("forms.gle") }

        // If they account for >25% of reactions and share links, likely host
        return reactionShare > 0.25 && hasLinks
    }

    // MARK: - Persistence Helpers

    private func getContext() -> ModelContext? {
        let container = SAMModelContainer.shared
        return ModelContext(container)
    }

    private func getOrCreateEvaluation(for event: SamEvent) -> EventEvaluation {
        if let existing = event.evaluation, !existing.isDeleted {
            return existing
        }

        let context = ModelContext(SAMModelContainer.shared)
        let evaluation = EventEvaluation(event: event)
        context.insert(evaluation)
        try? context.save()
        return evaluation
    }

    private func getExistingEvaluation(for event: SamEvent) -> EventEvaluation? {
        event.evaluation
    }

    private func markAttended(personID: UUID, event: SamEvent) {
        for participation in event.participations {
            guard let person = participation.person, !person.isDeleted else { continue }
            if person.id == personID {
                participation.attended = true
                break
            }
        }
    }

    private func createStandalonePerson(name: String) -> SamPerson? {
        do {
            return try PeopleRepository.shared.insertStandalone(displayName: name)
        } catch {
            logger.warning("Failed to create standalone person: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveContext() {
        let context = ModelContext(SAMModelContainer.shared)
        try? context.save()
    }

    // MARK: - Feedback Mapping Persistence

    private func feedbackMappingKey(for event: SamEvent) -> String {
        let presentationID = event.presentation?.id.uuidString ?? "default"
        return "sam.feedback.columnMapping.\(presentationID)"
    }

    private func saveFeedbackMapping(_ mapping: FeedbackColumnMapping, key: String) {
        if let data = try? JSONEncoder().encode(mapping) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadFeedbackMapping(key: String) -> FeedbackColumnMapping? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FeedbackColumnMapping.self, from: data)
    }
}
