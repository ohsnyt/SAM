//
//  PersonStageResolver.swift
//  SAM
//
//  Phase 8 of the relationship-model refactor (May 2026).
//
//  Bulk-cached "what stage is this person at" resolver. Replaces the 18+
//  `roleBadges.contains("Lead"/"Applicant"/"Client"/"Agent")` conflated
//  reads catalogued in relationship-model/phase0_audit.md §2.
//
//  `roleBadges` was a *label collection* ("what kind of person is this")
//  used in 18+ places as a *pipeline-stage proxy*. The fix: read the
//  actual stage from `StageTransition` (most recent per person) and
//  `RecruitingStage` (current per person) — the data models that were
//  always meant for this job.
//
//  Performance: each `roleBadges.contains` site is in a hot loop (filter,
//  count, gate) that runs once per person across the full list. The
//  unbatched cost of fetching transitions per person is O(N²). One cache
//  build does two bulk fetches and indexes by personID.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PersonStageResolver")

@MainActor
enum PersonStageResolver {

    // MARK: - Caches

    /// Most-recent client-pipeline stage name per person.
    /// Values: "Lead" | "Applicant" | "Client". Absent = not in the client funnel.
    private static var clientStageCache: [UUID: String] = [:]
    /// Set of person IDs with any RecruitingStage record (the canonical
    /// "this person is an Agent in the recruiting pipeline" signal).
    private static var agentSet: Set<UUID> = []
    /// Current recruiting stage kind per person, when present.
    private static var recruitingStageCache: [UUID: RecruitingStageKind] = [:]
    private static var cacheBuilt = false

    /// Drop the caches. Call after any mutation to StageTransition or
    /// RecruitingStage. Cheap — next read rebuilds in two main-actor fetches.
    static func invalidateCache() {
        clientStageCache.removeAll(keepingCapacity: true)
        agentSet.removeAll(keepingCapacity: true)
        recruitingStageCache.removeAll(keepingCapacity: true)
        cacheBuilt = false
    }

    // MARK: - Client pipeline

    /// Most-recent client-pipeline stage name. Nil if the person isn't on
    /// the client funnel (no StageTransition records).
    static func currentClientStage(forPerson personID: UUID) -> String? {
        if !cacheBuilt { rebuildCache() }
        return clientStageCache[personID]
    }

    static func isLead(forPerson personID: UUID) -> Bool {
        currentClientStage(forPerson: personID) == "Lead"
    }

    static func isApplicant(forPerson personID: UUID) -> Bool {
        currentClientStage(forPerson: personID) == "Applicant"
    }

    static func isClient(forPerson personID: UUID) -> Bool {
        currentClientStage(forPerson: personID) == "Client"
    }

    /// Convenience for "person is anywhere on the client funnel."
    static func isOnClientFunnel(forPerson personID: UUID) -> Bool {
        currentClientStage(forPerson: personID) != nil
    }

    // MARK: - Recruiting pipeline

    /// True when the person has any RecruitingStage record. Replaces the
    /// `roleBadges.contains("Agent")` reads that gated recruiting UI/logic.
    static func isAgent(forPerson personID: UUID) -> Bool {
        if !cacheBuilt { rebuildCache() }
        return agentSet.contains(personID)
    }

    static func currentRecruitingStage(forPerson personID: UUID) -> RecruitingStageKind? {
        if !cacheBuilt { rebuildCache() }
        return recruitingStageCache[personID]
    }

    // MARK: - Cache build

    private static func rebuildCache() {
        cacheBuilt = true
        clientStageCache.removeAll(keepingCapacity: true)
        agentSet.removeAll(keepingCapacity: true)
        recruitingStageCache.removeAll(keepingCapacity: true)

        // Client funnel: fetchAllTransitions returns sorted by date DESC,
        // so the first transition we see for each person is the most recent.
        if let transitions = try? PipelineRepository.shared.fetchAllTransitions(pipelineType: .client) {
            var seen = Set<UUID>()
            for transition in transitions {
                guard let pid = transition.person?.id, !seen.contains(pid) else { continue }
                seen.insert(pid)
                clientStageCache[pid] = transition.toStage
            }
        }

        // Recruiting: RecruitingStage is 1:1 with person.
        if let stages = try? PipelineRepository.shared.fetchAllRecruitingStages() {
            for stage in stages {
                guard let pid = stage.person?.id else { continue }
                agentSet.insert(pid)
                recruitingStageCache[pid] = stage.stage
            }
        }
    }
}
