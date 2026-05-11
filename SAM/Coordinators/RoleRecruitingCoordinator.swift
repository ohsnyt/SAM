//
//  RoleRecruitingCoordinator.swift
//  SAM
//
//  Created on March 17, 2026.
//  Role Recruiting: Orchestrates scoring, approvals, stage transitions.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RoleRecruitingCoordinator")

@MainActor
@Observable
final class RoleRecruitingCoordinator {

    // MARK: - Singleton

    static let shared = RoleRecruitingCoordinator()

    // MARK: - Observable State

    enum ScoringStatus: Sendable {
        case idle
        case preparing(String)                          // role name — pre-filter phase
        case scoring(String, current: Int, total: Int)  // scanning person N of M
        case complete
        case failed(String)
    }

    var roleDefinitions: [RoleDefinition] = []
    var candidatesByRole: [UUID: [RoleCandidate]] = [:]
    var scoringStatus: ScoringStatus = .idle
    var pendingResults: [UUID: [RoleCandidateScoringResult]] = [:]
    var lastScoredAt: [UUID: Date] = [:]

    // MARK: - Dependencies

    private var repo: RoleRecruitingRepository { RoleRecruitingRepository.shared }
    private var peopleRepo: PeopleRepository { PeopleRepository.shared }
    private var evidenceRepo: EvidenceRepository { EvidenceRepository.shared }
    private var pipelineRepo: PipelineRepository { PipelineRepository.shared }

    private init() {}

    // MARK: - Data Loading

    func loadRoles() {
        do {
            roleDefinitions = try repo.fetchActiveRoles()
            for role in roleDefinitions {
                candidatesByRole[role.id] = try repo.fetchCandidates(for: role.id)
            }
        } catch {
            logger.error("Failed to load roles: \(error)")
        }
    }

    // MARK: - Scoring

    /// Kicks off scoring as a background task. Updates `scoringStatus` with progress.
    /// Posts a system notification when complete.
    func scoreCandidates(for roleID: UUID) async {
        guard let role = try? repo.fetchRole(id: roleID) else { return }

        scoringStatus = .preparing(role.name)

        let roleName = role.name
        let roleDescription = role.roleDescription
        let idealProfile = role.idealCandidateProfile
        let criteria = role.criteria
        let refinementNotes = role.refinementNotes
        let exclusionCriteria = role.exclusionCriteria

        do {
            let allPeople = try peopleRepo.fetchAll().filter { !$0.isMe && !$0.isArchived }
            let existingCandidates = try repo.fetchCandidates(for: roleID, includeTerminal: true)
            var excludedPersonIDs = Set(existingCandidates.compactMap { $0.person?.id })

            // Guard: people who already hold this role (matching badge) cannot be candidates
            for person in allPeople where person.roleBadges.contains(roleName) {
                excludedPersonIDs.insert(person.id)
            }

            // Build profiles
            let profiles = buildProfiles(for: allPeople)

            // Pass 1: Swift pre-filter
            let filtered = await RoleCandidateAnalystService.shared.preFilter(
                allPeople: profiles,
                existingCandidatePersonIDs: excludedPersonIDs,
                criteria: criteria
            )

            guard !filtered.isEmpty else {
                scoringStatus = .complete
                pendingResults[roleID] = []
                lastScoredAt[roleID] = .now
                return
            }

            let total = filtered.count

            // Pass 2: LLM scoring with progress reporting
            let input = RoleCandidateScoringInput(
                roleName: roleName,
                roleDescription: roleDescription,
                idealProfile: idealProfile,
                criteria: criteria,
                refinementNotes: refinementNotes,
                exclusionCriteria: exclusionCriteria,
                candidates: filtered
            )

            let coordinator = self
            let results = try await RoleCandidateAnalystService.shared.scoreCandidates(input: input) { current in
                Task { @MainActor in
                    coordinator.scoringStatus = .scoring(roleName, current: current, total: total)
                }
            }

            // Filter to meaningful scores
            let meaningfulResults = results.filter { $0.matchScore >= 0.3 }

            pendingResults[roleID] = meaningfulResults
            lastScoredAt[roleID] = .now
            scoringStatus = .complete

            logger.info("Scored \(results.count) candidates for \(roleName), \(meaningfulResults.count) above threshold")

            // Post system notification so the user knows even if they navigated away
            await SystemNotificationService.shared.postRoleScanComplete(
                roleName: roleName,
                matchCount: meaningfulResults.count
            )

        } catch {
            scoringStatus = .failed(error.localizedDescription)
            logger.error("Scoring failed for \(roleName): \(error)")
        }
    }

    // MARK: - Approve / Dismiss

    func approveCandidate(result: RoleCandidateScoringResult, roleID: UUID) {
        guard let role = try? repo.fetchRole(id: roleID) else { return }

        // Re-resolve person in repo context
        guard let people = try? peopleRepo.fetchAll(),
              let person = people.first(where: { $0.id == result.personID }) else { return }

        let candidate = RoleCandidate(
            person: person,
            roleDefinition: role,
            stage: .suggested,
            matchScore: result.matchScore,
            matchRationale: result.matchRationale,
            strengthSignals: result.strengthSignals,
            gapSignals: result.gapSignals,
            isUserApproved: true
        )

        do {
            try repo.saveCandidate(candidate)

            // Record stage transition
            try pipelineRepo.recordTransition(
                personID: person.id,
                fromStage: "",
                toStage: RoleCandidateStage.suggested.rawValue,
                pipelineType: .roleRecruiting,
                notes: "Role: \(role.name)"
            )

            // Update local state
            pendingResults[roleID]?.removeAll { $0.personID == result.personID }
            candidatesByRole[roleID] = try repo.fetchCandidates(for: roleID)

        } catch {
            logger.error("Failed to approve candidate: \(error)")
        }
    }

    func dismissCandidate(result: RoleCandidateScoringResult, roleID: UUID, reason: String?) {
        if let reason, !reason.isEmpty {
            try? repo.addRefinementNote(roleID: roleID, note: reason)
        }
        pendingResults[roleID]?.removeAll { $0.personID == result.personID }
    }

    // MARK: - Stage Advancement

    func advanceStage(candidateID: UUID, to newStage: RoleCandidateStage, notes: String? = nil) {
        do {
            let allCandidates = try repo.fetchAllCandidates()
            guard let candidate = allCandidates.first(where: { $0.id == candidateID }) else { return }
            guard let person = candidate.person else { return }
            guard let role = candidate.roleDefinition else { return }

            let fromStage = candidate.stage

            candidate.stage = newStage
            candidate.stageEnteredAt = .now
            candidate.userNotes = notes ?? candidate.userNotes

            if newStage == .approached || newStage == .committed {
                candidate.lastContactedAt = .now
            }

            try repo.saveCandidate(candidate)

            // Record transition
            try pipelineRepo.recordTransition(
                personID: person.id,
                fromStage: fromStage.rawValue,
                toStage: newStage.rawValue,
                pipelineType: .roleRecruiting,
                notes: "Role: \(role.name)"
            )

            // Handoff: if committed and role maps to a known pipeline
            if newStage == .committed {
                handleCommittedHandoff(person: person, role: role)
            }

            // Refresh local state
            candidatesByRole[role.id] = try repo.fetchCandidates(for: role.id)

        } catch {
            logger.error("Failed to advance stage: \(error)")
        }
    }

    // MARK: - Handoff to WFG Pipeline

    private func handleCommittedHandoff(person: SamPerson, role: RoleDefinition) {
        let agentRoleNames: Set<String> = ["Agent", "WFG Agent"]
        guard agentRoleNames.contains(role.name) else { return }

        // Display-only: keep the visual "Agent" chip in sync. The canonical
        // recruiting-pipeline signal is the RecruitingStage record created
        // below — readers must use PersonStageResolver.isAgent(forPerson:),
        // not this badge (see phase0_audit.md §2).
        if !person.roleBadges.contains("Agent") {
            person.roleBadges.append("Agent")
        }

        // Create RecruitingStage at prospect — canonical recruiting signal.
        do {
            try pipelineRepo.upsertRecruitingStage(personID: person.id, stage: .prospect)
            logger.info("Handoff: \(person.displayNameCache ?? "unknown") → WFG recruiting pipeline at Prospect")
        } catch {
            logger.error("Handoff failed: \(error)")
        }
    }

    // MARK: - Stale Refresh

    func refreshIfStale() async {
        do {
            let roles = try repo.fetchActiveRoles()
            for role in roles {
                let lastScored = lastScoredAt[role.id]
                if lastScored == nil || Date.now.timeIntervalSince(lastScored!) > 24 * 60 * 60 {
                    await scoreCandidates(for: role.id)
                }
            }
        } catch {
            logger.error("Stale refresh failed: \(error)")
        }
    }

    // MARK: - Profile Building

    private func buildProfiles(for people: [SamPerson]) -> [PersonScoringProfile] {
        people.map { person in
            let evidence = person.linkedEvidence
            let calendarEvidence = evidence.filter { $0.source == .calendar }
            let recentSnippets = evidence
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(5)
                .map { "\($0.title) (\($0.source.rawValue))" }

            let contexts = person.participations.compactMap { $0.context }
            let lastInteraction = evidence.map(\.occurredAt).max()
            let daysSince = lastInteraction.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 }

            // Get note topics
            let noteTopics: [String] = person.linkedNotes.compactMap { note in
                guard let artifact = note.analysisArtifact,
                      let topicsJSON = artifact.topicsJSON,
                      let data = topicsJSON.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([String].self, from: data) else { return nil }
                return decoded.joined(separator: ", ")
            }

            return PersonScoringProfile(
                personID: person.id,
                displayName: person.displayNameCache ?? person.displayName,
                roleBadges: person.roleBadges,
                jobTitle: nil,        // Available via ContactDTO at score time if needed
                organization: nil,    // Available via ContactDTO at score time if needed
                department: nil,
                linkedInHeadline: nil, // LinkedIn data via social import
                relationshipSummary: person.relationshipSummary,
                keyThemes: person.relationshipKeyThemes,
                recentEvidenceSnippets: Array(recentSnippets),
                noteTopics: noteTopics,
                quantitativeSignals: QuantitativeSignals(
                    totalInteractions: evidence.count,
                    daysSinceLastInteraction: daysSince,
                    meetingCount: calendarEvidence.count,
                    sharedContextCount: contexts.count,
                    referralConnectionCount: 0,
                    socialTouchScore: nil
                )
            )
        }
    }
}
