//
//  SphereClassificationCoordinator.swift
//  SAM
//
//  Phase C3 of the multi-sphere classification work (May 2026).
//
//  Bridges SwiftData (mainContext) with the background
//  `SphereClassificationService` actor. Owns:
//    1. Snapshot building — resolves SamPerson + spheres + evidence on
//       the main actor so the background service stays pure-value.
//    2. Auto-apply — when classifier confidence ≥ 0.75, write the chosen
//       sphere back to `evidence.contextSphere`.
//    3. Skip rules — never run when the person has <2 active spheres
//       (nothing to choose between) or when the evidence already has an
//       explicit `contextSphere` (the user/classifier already decided).
//
//  Called from the evidence ingestion path (EvidenceRepository.create).
//  Runs the classifier as a detached `.background` task so the import
//  path returns immediately and the LLM call doesn't block the UI.
//

import Foundation
import SwiftData
import os.log

@MainActor
final class SphereClassificationCoordinator {

    static let shared = SphereClassificationCoordinator()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SphereClassificationCoordinator")

    private init() {}

    // MARK: - Entry points

    /// Kick off classification for one evidence item if it qualifies.
    /// Non-blocking — the heavy work runs on a detached background task.
    func classifyInBackground(evidenceID: UUID) {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.classifyAndApply(evidenceID: evidenceID)
        }
    }

    /// Kick off classification for a batch of evidence items (typically
    /// the set just created by a single import). Each item runs
    /// sequentially in the background to avoid hammering the inference
    /// queue — AIService already serializes, but we yield between items
    /// to let foreground work in.
    func classifyInBackground(evidenceIDs: [UUID]) {
        guard !evidenceIDs.isEmpty else { return }
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            for id in evidenceIDs {
                await self.classifyAndApply(evidenceID: id)
                await Task.yield()
            }
        }
    }

    // MARK: - Core flow

    /// Resolve the evidence, decide if it needs classification, call the
    /// service, and write back the result on auto-apply.
    func classifyAndApply(evidenceID: UUID) async {
        guard let snapshot = buildSnapshot(evidenceID: evidenceID) else {
            return
        }

        let result = await SphereClassificationService.shared.classify(snapshot.input)

        if result.shouldAutoApply, let sphereID = result.sphereID {
            applyAutoClassification(
                evidenceID: evidenceID,
                sphereID: sphereID,
                confidence: result.confidence
            )
            return
        }

        if result.shouldQueueForReview, let sphereID = result.sphereID {
            recordProposal(
                evidenceID: evidenceID,
                sphereID: sphereID,
                confidence: result.confidence,
                reason: result.reason
            )
        }
    }

    // MARK: - Snapshot building (main actor)

    private struct ClassificationSnapshot {
        let input: SphereClassificationInput
    }

    private func buildSnapshot(evidenceID: UUID) -> ClassificationSnapshot? {
        guard !BackupCoordinator.isRestoring else { return nil }

        // Resolve evidence and gate on the trivial-skip conditions.
        guard let evidence = fetchEvidence(id: evidenceID), !evidence.isDeleted else {
            return nil
        }
        // Already classified — never override an explicit pick.
        guard evidence.contextSphere == nil else { return nil }

        // Pick the linked person to classify against. The interaction
        // belongs to one sphere; when there are multiple linkedPeople
        // (e.g., group meeting), classify against the first — the
        // single-person spheres of co-participants will be picked up via
        // their own per-person briefing paths.
        guard let person = evidence.linkedPeople.first else { return nil }

        // Look up the person's active spheres + each sphere's confirmed
        // example count (= existing evidence rows with that contextSphere).
        let spheres: [Sphere]
        do {
            spheres = try SphereRepository.shared.spheres(forPerson: person.id)
        } catch {
            logger.warning("Failed to fetch spheres for \(person.id): \(error.localizedDescription)")
            return nil
        }
        // 0 spheres → nothing to do. 1 sphere → fallback already handles it.
        guard spheres.count >= 2 else { return nil }

        let candidates = spheres.map { sphere in
            // Pool examples sorted newest-first so the classifier sees
            // the most recent corrections first; cap at maxExamples to
            // stay inside the prompt budget.
            let examples = sphere.examples
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(Sphere.maxExamples)
                .map(\.snippet)
            return SphereClassificationCandidate(
                sphereID: sphere.id,
                name: sphere.name,
                purpose: sphere.purpose,
                classificationProfile: sphere.classificationProfile,
                keywordHints: sphere.keywordHints,
                confirmedExamples: examples
            )
        }

        let bodyExcerpt: String? = {
            guard let body = evidence.bodyText, !body.isEmpty else { return nil }
            return String(body.prefix(800))
        }()

        let evidenceSnapshot = SphereClassificationEvidenceSnapshot(
            id: evidence.id,
            title: evidence.title,
            snippet: evidence.snippet,
            bodyExcerpt: bodyExcerpt,
            sourceLabel: evidence.source.rawValue,
            directionLabel: evidence.direction.map { $0.rawValue },
            occurredAt: evidence.occurredAt
        )

        let input = SphereClassificationInput(
            evidence: evidenceSnapshot,
            personDisplayName: person.displayName,
            personRoleBadges: person.roleBadges,
            candidates: candidates
        )

        return ClassificationSnapshot(input: input)
    }

    // MARK: - Write-back (main actor)

    private func applyAutoClassification(evidenceID: UUID, sphereID: UUID, confidence: Double) {
        guard !BackupCoordinator.isRestoring else { return }
        guard let evidence = fetchEvidence(id: evidenceID), !evidence.isDeleted else { return }
        // Re-check: user or another path may have set the sphere in the
        // window between snapshot and write-back. Never overwrite.
        guard evidence.contextSphere == nil else { return }

        guard let sphere = try? SphereRepository.shared.fetch(id: sphereID), !sphere.archived else {
            return
        }

        evidence.contextSphere = sphere
        do {
            try evidence.modelContext?.save()
            logger.debug(
                "Auto-classified evidence \(evidenceID, privacy: .public) → sphere \(sphere.name, privacy: .public) at \(confidence)"
            )
        } catch {
            logger.warning("Failed to persist sphere classification: \(error.localizedDescription)")
        }
    }

    // MARK: - Review batch (Phase C4)

    /// Persist a mid-confidence pick to the evidence row so the EOD
    /// review batch can surface it later. Never overrides an existing
    /// `contextSphere` (already-decided rows are off-limits).
    private func recordProposal(
        evidenceID: UUID,
        sphereID: UUID,
        confidence: Double,
        reason: String?
    ) {
        guard !BackupCoordinator.isRestoring else { return }
        guard let evidence = fetchEvidence(id: evidenceID), !evidence.isDeleted else { return }
        guard evidence.contextSphere == nil else { return }

        evidence.proposedSphereID = sphereID
        evidence.proposedSphereConfidence = confidence
        evidence.proposedSphereReason = reason
        evidence.proposedSphereAt = Date()

        do {
            try evidence.modelContext?.save()
            logger.debug(
                "Recorded review proposal for evidence \(evidenceID, privacy: .public) at \(confidence)"
            )
        } catch {
            logger.warning("Failed to persist sphere proposal: \(error.localizedDescription)")
        }
    }

    /// Fetch all evidence rows that have a pending classifier proposal —
    /// what the EOD review UI walks. Sorted newest-first so the most
    /// recent imports are reviewed before older ones.
    func pendingReviewItems() -> [SamEvidenceItem] {
        let context = SAMModelContainer.shared.mainContext
        var descriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        descriptor.predicate = #Predicate { evidence in
            evidence.proposedSphereID != nil && evidence.contextSphere == nil
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    /// User accepted the proposal — promote it to a real
    /// `contextSphere`, append the snippet to the sphere's example pool,
    /// and clear the proposal fields. Bumps the per-sphere accept counter
    /// for drift telemetry.
    func acceptProposal(evidenceID: UUID) {
        guard let evidence = fetchEvidence(id: evidenceID), !evidence.isDeleted else { return }
        guard let sphereID = evidence.proposedSphereID,
              let sphere = try? SphereRepository.shared.fetch(id: sphereID),
              !sphere.archived else {
            clearProposal(on: evidence)
            return
        }
        evidence.contextSphere = sphere
        try? SphereRepository.shared.recordExample(
            sphereID: sphere.id,
            evidenceID: evidence.id,
            snippet: evidence.snippet,
            wasOverride: false
        )
        SphereClassifierTelemetry.shared.recordAccept(sphereID: sphere.id)
        clearProposal(on: evidence)
        try? evidence.modelContext?.save()
    }

    /// User rejected the proposal — just clear the proposal fields.
    /// `contextSphere` remains nil, so the lens fallback continues to
    /// route this evidence to the person's default sphere. Also bumps a
    /// per-sphere dismiss counter (drift telemetry, surfaced in
    /// Settings → "What SAM Has Learned").
    func dismissProposal(evidenceID: UUID) {
        guard let evidence = fetchEvidence(id: evidenceID), !evidence.isDeleted else { return }
        if let proposedID = evidence.proposedSphereID {
            SphereClassifierTelemetry.shared.recordDismiss(sphereID: proposedID)
        }
        clearProposal(on: evidence)
        try? evidence.modelContext?.save()
    }

    /// User picked a different sphere than the classifier suggested.
    /// Treated as the strongest possible signal: set as `contextSphere`,
    /// append the snippet to the chosen sphere's example pool with
    /// `wasOverride: true` so rotation preserves it preferentially, then
    /// clear the proposal fields. Records an *override-out* on the
    /// originally-proposed sphere so drift telemetry can show "this sphere
    /// keeps grabbing things it shouldn't."
    func overrideProposal(evidenceID: UUID, with sphereID: UUID) {
        guard let evidence = fetchEvidence(id: evidenceID), !evidence.isDeleted else { return }
        guard let sphere = try? SphereRepository.shared.fetch(id: sphereID), !sphere.archived else {
            return
        }
        if let proposedID = evidence.proposedSphereID, proposedID != sphere.id {
            SphereClassifierTelemetry.shared.recordOverride(sphereID: proposedID)
        }
        evidence.contextSphere = sphere
        try? SphereRepository.shared.recordExample(
            sphereID: sphere.id,
            evidenceID: evidence.id,
            snippet: evidence.snippet,
            wasOverride: true
        )
        clearProposal(on: evidence)
        try? evidence.modelContext?.save()
    }

    private func clearProposal(on evidence: SamEvidenceItem) {
        evidence.proposedSphereID = nil
        evidence.proposedSphereConfidence = 0.0
        evidence.proposedSphereReason = nil
        evidence.proposedSphereAt = nil
    }

    // MARK: - Fetches

    private func fetchEvidence(id: UUID) -> SamEvidenceItem? {
        let context = SAMModelContainer.shared.mainContext
        let descriptor = FetchDescriptor<SamEvidenceItem>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

}
