//
//  StewardshipSpawnService.swift
//  SAM
//
//  Phase 4 of the relationship-model refactor (May 2026).
//
//  When a PersonTrajectoryEntry reaches a terminal stage in a Funnel-mode
//  Trajectory (the canonical Lead → Applicant → Client closure), the same
//  person needs an Ongoing Stewardship arc opened in the same Sphere so the
//  post-close relationship has a structured home. Without it the contact
//  drops off the active Trajectory and SAM has no cadence frame for them.
//
//  This service is the single entry point for that spawn. It is:
//    1. idempotent — calling it for a person already on a Stewardship arc
//       in the same Sphere is a no-op
//    2. lazy on Trajectory creation — the "<Sphere> — Ongoing Stewardship"
//       Trajectory is created on first spawn, not at bootstrap, so we don't
//       litter empty arcs for users who never close anyone
//    3. cheap — caller can fire-and-forget on the main actor
//
//  Called from:
//    - PersonDetailView.recordPipelineTransitions when a Client badge lands
//    - StewardshipSpawnService.runBackfillIfNeeded() at first launch
//      post-Phase-4, to retro-spawn Stewardship for existing Clients
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "StewardshipSpawn")

@MainActor
enum StewardshipSpawnService {

    /// UserDefaults key gating the one-time backfill for existing Funnel-terminal
    /// persons. We do this once per install — re-running would be a no-op due to
    /// the per-spawn idempotency check, but it's wasted work on every launch.
    private static let backfillDoneKey = "sam.migration.stewardshipBackfillDone"

    /// Stage name used on the spawned Stewardship Trajectory. Single-stage —
    /// Stewardship Mode relies on cadence rhythm, not stage progression.
    private static let stewardshipActiveStageName = "Active"

    // MARK: - Spawn

    /// Ensure the given person has an active Stewardship Trajectory entry in
    /// their primary Sphere. Idempotent — no-ops when one already exists.
    ///
    /// Returns the entry that exists post-call (newly created or pre-existing),
    /// or nil if the person has no Sphere membership yet (pre-bootstrap state).
    ///
    /// On success, invalidates `PersonModeResolver`'s cache so the next mode
    /// lookup for this person sees the new Stewardship entry.
    @discardableResult
    static func spawnStewardshipIfNeeded(personID: UUID) -> PersonTrajectoryEntry? {
        do {
            let spheres = try SphereRepository.shared.spheres(forPerson: personID)
            // Prefer the bootstrap default (most users have only one Sphere
            // and this is unambiguous). For multi-Sphere users we spawn into
            // the bootstrap Sphere because that's where the closed Funnel
            // Trajectory lives by construction; cross-Sphere spawning will
            // come in Phase 5 once the multi-Sphere UI exists.
            let bootstrapDefault = try SphereRepository.shared.fetchBootstrapDefault()
            let targetSphere = bootstrapDefault ?? spheres.first
            guard let sphere = targetSphere else {
                logger.debug("Spawn skipped — no Sphere membership for person \(personID)")
                return nil
            }

            let trajectory = try findOrCreateStewardshipTrajectory(in: sphere)
            guard let stewardship = trajectory else {
                logger.error("Spawn failed — could not find/create Stewardship trajectory in '\(sphere.name)'")
                return nil
            }

            // Idempotency: bail if already on this Trajectory.
            if try PersonTrajectoryRepository.shared.hasActiveEntry(
                personID: personID,
                trajectoryID: stewardship.id
            ) {
                return try PersonTrajectoryRepository.shared
                    .activeEntries(forPerson: personID)
                    .first { $0.trajectory?.id == stewardship.id }
            }

            let activeStage = try TrajectoryRepository.shared
                .fetchStages(forTrajectory: stewardship.id)
                .first

            let entry = try PersonTrajectoryRepository.shared.enter(
                personID: personID,
                trajectoryID: stewardship.id,
                stageID: activeStage?.id,
                cadenceDaysOverride: nil
            )

            if entry != nil {
                PersonModeResolver.invalidateCache()
                logger.info("Spawned Stewardship entry for person \(personID) in '\(sphere.name)'")
            }
            return entry
        } catch {
            logger.error("Spawn error for person \(personID): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Backfill

    /// One-time backfill for users upgrading past Phase 4. Walks every active
    /// PersonTrajectoryEntry on a Funnel-mode Trajectory currently at a
    /// terminal stage and spawns the Stewardship arc. Guarded so this only
    /// runs once per install — subsequent launches return immediately.
    ///
    /// Called from the launch coordinator after `SphereBootstrapCoordinator`
    /// so the Funnel entries it needs to scan exist.
    static func runBackfillIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: backfillDoneKey) else { return }

        do {
            let activeEntries = try PersonTrajectoryRepository.shared.fetchAllActive()
            let terminalFunnel = activeEntries.filter { entry in
                entry.trajectory?.mode == .funnel
                    && (entry.currentStage?.isTerminal ?? false)
            }
            logger.info("Stewardship backfill scanning \(terminalFunnel.count) Funnel-terminal entries")

            var spawned = 0
            for (idx, entry) in terminalFunnel.enumerated() {
                guard let personID = entry.person?.id else { continue }
                if spawnStewardshipIfNeeded(personID: personID) != nil {
                    spawned += 1
                }
                // Yield occasionally so launch UI stays responsive when the
                // user has many closed-Client entries to backfill.
                if (idx + 1) % 10 == 0 { await Task.yield() }
            }

            UserDefaults.standard.set(true, forKey: backfillDoneKey)
            logger.notice("Stewardship backfill complete — spawned \(spawned)/\(terminalFunnel.count) entries")
        } catch {
            logger.error("Stewardship backfill failed: \(error.localizedDescription)")
            // Leave the flag unset so we retry next launch.
        }
    }

    // MARK: - Helpers

    /// Find the Stewardship-mode Trajectory in a Sphere, creating it lazily
    /// with a single non-terminal "Active" stage if it doesn't exist.
    private static func findOrCreateStewardshipTrajectory(in sphere: Sphere) throws -> Trajectory? {
        let existing = try TrajectoryRepository.shared.fetchAll(forSphere: sphere.id)
        if let match = existing.first(where: { $0.mode == .stewardship }) {
            return match
        }

        let name = "\(sphere.name) — Ongoing Stewardship"
        let trajectory = try TrajectoryRepository.shared.createTrajectory(
            sphereID: sphere.id,
            name: name,
            mode: .stewardship,
            notes: "Auto-spawned when a Funnel arc terminated in this Sphere."
        )
        try TrajectoryRepository.shared.addStage(
            trajectoryID: trajectory.id,
            name: stewardshipActiveStageName,
            sortOrder: 0,
            isTerminal: false
        )
        logger.info("Created Stewardship Trajectory '\(name)' in Sphere '\(sphere.name)'")
        return trajectory
    }
}
