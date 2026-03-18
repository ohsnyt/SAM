//
//  RoleCandidateAnalystService.swift
//  SAM
//
//  Created on March 17, 2026.
//  Role Recruiting: LLM-powered candidate scoring service.
//
//  Two-pass scoring: Swift pre-filter → LLM qualitative scoring in batches.
//

import Foundation
import os.log

// MARK: - Input DTOs

struct RoleCandidateScoringInput: Sendable {
    let roleName: String
    let roleDescription: String
    let idealProfile: String
    let criteria: [String]
    let refinementNotes: [String]
    let exclusionCriteria: [String]
    let candidates: [PersonScoringProfile]
}

struct PersonScoringProfile: Sendable {
    let personID: UUID
    let displayName: String
    let roleBadges: [String]
    let jobTitle: String?
    let organization: String?
    let department: String?
    let linkedInHeadline: String?
    let relationshipSummary: String?
    let keyThemes: [String]
    let recentEvidenceSnippets: [String]
    let noteTopics: [String]
    let quantitativeSignals: QuantitativeSignals
}

struct QuantitativeSignals: Sendable {
    let totalInteractions: Int
    let daysSinceLastInteraction: Int?
    let meetingCount: Int
    let sharedContextCount: Int
    let referralConnectionCount: Int
    let socialTouchScore: Int?
}

// MARK: - Output DTO

struct RoleCandidateScoringResult: Sendable, Codable {
    let personID: UUID
    let matchScore: Double
    let matchRationale: String
    let strengthSignals: [String]
    let gapSignals: [String]
}

// MARK: - LLM Response DTO

private struct LLMCandidateScore: Codable {
    let index: Int?
    let match_score: Double?
    let match_rationale: String?
    let strength_signals: [String]?
    let gap_signals: [String]?
}

// MARK: - Service

actor RoleCandidateAnalystService {

    static let shared = RoleCandidateAnalystService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RoleCandidateAnalystService")

    private init() {}

    // MARK: - Pre-Filter (Pass 1)

    /// Deterministic Swift pre-filter: excludes ineligible, ranks by relevance, takes top 25.
    func preFilter(
        allPeople: [PersonScoringProfile],
        existingCandidatePersonIDs: Set<UUID>,
        criteria: [String]
    ) -> [PersonScoringProfile] {
        let criteriaKeywords = Set(criteria.joined(separator: " ")
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 3 })

        let scored: [(PersonScoringProfile, Int)] = allPeople
            .filter { !existingCandidatePersonIDs.contains($0.personID) }
            .map { person in
                var score = 0
                if person.relationshipSummary != nil { score += 3 }
                if !person.recentEvidenceSnippets.isEmpty { score += 2 }
                if !person.noteTopics.isEmpty { score += 2 }
                if person.quantitativeSignals.socialTouchScore != nil { score += 1 }

                // Job title keyword matching
                if let title = person.jobTitle?.lowercased() {
                    let titleWords = Set(title.split(separator: " ").map(String.init))
                    if !titleWords.isDisjoint(with: criteriaKeywords) { score += 3 }
                }

                // Theme matching
                let themes = Set(person.keyThemes.map { $0.lowercased() })
                if !themes.isDisjoint(with: criteriaKeywords) { score += 2 }

                return (person, score)
            }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(25)
            .map(\.0)
    }

    // MARK: - LLM Scoring (Pass 2)

    /// Score candidates one at a time using the LLM.
    /// - Parameter onProgress: Called before each candidate with the 1-based index being scored.
    func scoreCandidates(
        input: RoleCandidateScoringInput,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [RoleCandidateScoringResult] {
        // Guard: no criteria means no scoring
        guard !input.criteria.isEmpty || !input.idealProfile.isEmpty else {
            logger.debug("Skipping scoring — no criteria or ideal profile defined")
            return []
        }

        guard case .available = await AIService.shared.checkAvailability() else {
            throw ScoringError.modelUnavailable
        }

        var allResults: [RoleCandidateScoringResult] = []

        for (index, person) in input.candidates.enumerated() {
            onProgress?(index + 1)

            if let result = try await scoreOne(
                person: person,
                roleName: input.roleName,
                roleDescription: input.roleDescription,
                idealProfile: input.idealProfile,
                criteria: input.criteria,
                refinementNotes: input.refinementNotes,
                exclusionCriteria: input.exclusionCriteria
            ) {
                allResults.append(result)
            }

            // Yield to avoid starving foreground work
            await Task.yield()
        }

        return allResults.sorted { $0.matchScore > $1.matchScore }
    }

    private func scoreOne(
        person: PersonScoringProfile,
        roleName: String,
        roleDescription: String,
        idealProfile: String,
        criteria: [String],
        refinementNotes: [String],
        exclusionCriteria: [String]
    ) async throws -> RoleCandidateScoringResult? {
        var lines: [String] = []
        lines.append("Name: \(person.displayName)")
        if !person.roleBadges.isEmpty { lines.append("Roles: \(person.roleBadges.joined(separator: ", "))") }
        if let title = person.jobTitle { lines.append("Job: \(title)") }
        if let org = person.organization { lines.append("Org: \(org)") }
        if let dept = person.department { lines.append("Dept: \(dept)") }
        if let headline = person.linkedInHeadline { lines.append("LinkedIn: \(headline)") }
        if let summary = person.relationshipSummary { lines.append("Relationship: \(summary)") }
        if !person.keyThemes.isEmpty { lines.append("Themes: \(person.keyThemes.joined(separator: ", "))") }
        if !person.recentEvidenceSnippets.isEmpty { lines.append("Recent: \(person.recentEvidenceSnippets.joined(separator: "; "))") }
        lines.append("Interactions: \(person.quantitativeSignals.totalInteractions), Meetings: \(person.quantitativeSignals.meetingCount)")
        let profileText = lines.joined(separator: "\n")

        let refinementBlock = refinementNotes.isEmpty ? "" :
            "\n\nPrevious feedback on people who were not a good match: \(refinementNotes.joined(separator: "; "))."

        let exclusionBlock = exclusionCriteria.isEmpty ? "" :
            "\n\nDISQUALIFYING CONDITIONS — if this person matches any of the following, respond with a match_score of 0.0:\n\(exclusionCriteria.map { "- \($0)" }.joined(separator: "\n"))"

        // Journal learnings for roleFilling goals linked to this role
        let journalBlock = await buildJournalBlock(roleName: roleName)

        let systemInstruction = """
            Networking assistant: match contacts to opportunities. Respond ONLY with valid JSON, no markdown.

            Opportunity: "\(roleName)" — \(roleDescription)
            Good fit: \(idealProfile)
            Qualities: \(criteria.joined(separator: "; "))\(exclusionBlock)\(refinementBlock)\(journalBlock)

            {"match_score": 0.0-1.0, "match_rationale": "2-3 sentences", "strength_signals": ["..."], "gap_signals": ["..."]}
            """

        let prompt = "Assess this person for the \(roleName) opportunity:\n\n\(profileText)"

        let responseText: String
        do {
            // Use generateNarrative to prefer MLX/Qwen — Apple FoundationModels
            // guardrails can trigger on people-evaluation prompts.
            responseText = try await AIService.shared.generateNarrative(
                prompt: prompt,
                systemInstruction: systemInstruction,
                maxTokens: 512
            )
        } catch {
            logger.warning("Scoring failed for \(person.displayName): \(error.localizedDescription)")
            return nil
        }

        return parseSingleResponse(responseText, personID: person.personID)
    }

    private func parseSingleResponse(_ jsonString: String, personID: UUID) -> RoleCandidateScoringResult? {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)
        guard let data = cleaned.data(using: .utf8) else { return nil }

        if let score = try? JSONDecoder().decode(LLMCandidateScore.self, from: data) {
            return RoleCandidateScoringResult(
                personID: personID,
                matchScore: min(1.0, max(0.0, score.match_score ?? 0)),
                matchRationale: score.match_rationale ?? "",
                strengthSignals: score.strength_signals ?? [],
                gapSignals: score.gap_signals ?? []
            )
        }

        logger.warning("Failed to parse scoring response for \(personID)")
        return nil
    }

    // MARK: - Journal Context

    /// Build a journal context block from roleFilling goal journal entries.
    @MainActor
    private func buildJournalBlock(roleName: String) -> String {
        guard let goals = try? GoalRepository.shared.fetchActive() else { return "" }

        // Find roleFilling goals that might relate to this role
        let roleGoals = goals.filter { $0.goalType == .roleFilling }
        guard !roleGoals.isEmpty else { return "" }

        var entries: [GoalJournalEntry] = []
        for goal in roleGoals {
            if let goalEntries = try? GoalJournalRepository.shared.fetchEntries(for: goal.id) {
                entries.append(contentsOf: goalEntries.prefix(3))
            }
        }
        guard !entries.isEmpty else { return "" }

        var lines: [String] = ["\n\nLEARNINGS FROM ROLE RECRUITING CHECK-INS:"]
        for entry in entries.prefix(5) {
            if !entry.whatsWorking.isEmpty {
                lines.append("Working: \(entry.whatsWorking.joined(separator: ", "))")
            }
            if !entry.whatsNotWorking.isEmpty {
                lines.append("Not working: \(entry.whatsNotWorking.joined(separator: ", "))")
            }
            if let insight = entry.keyInsight, !insight.isEmpty {
                lines.append("Insight: \(insight)")
            }
        }

        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    // MARK: - Errors

    enum ScoringError: Error, LocalizedError {
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "On-device AI model is not available for candidate scoring"
            }
        }
    }
}
