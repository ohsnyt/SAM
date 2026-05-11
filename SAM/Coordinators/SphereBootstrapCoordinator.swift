//
//  SphereBootstrapCoordinator.swift
//  SAM
//
//  Phase 1 of the relationship-model refactor (May 2026).
//
//  Idempotent first-launch migration that creates the auto-Sphere
//  ("My Practice"), the default Client Pipeline Trajectory for WFG users,
//  and seeds each existing Person with a PersonSphereMembership plus, where
//  applicable, a PersonTrajectoryEntry derived from their most recent
//  StageTransition (or roleBadges as a fallback).
//
//  Runs once per install, gated by a UserDefaults flag.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SphereBootstrap")

@MainActor
enum SphereBootstrapCoordinator {

    /// UserDefaults key for one-shot idempotency.
    private static let migrationDoneKey = "sam.migration.sphereBootstrapDone"

    /// Bootstrap default Sphere name. Used by Phase 5 split-flow to identify
    /// the legacy default.
    private static let defaultSphereName = "My Practice"

    /// Stage labels for the WFG client pipeline. Order matters.
    private static let wfgPipelineStages: [(name: String, isTerminal: Bool)] = [
        ("Lead", false),
        ("Applicant", false),
        ("Client", true),
    ]

    /// How often to yield the main actor while seeding memberships. With
    /// ~hundreds of contacts the tight loop otherwise occupies the main
    /// runloop long enough to drop the first paint and any user input.
    private static let yieldEveryNPersons = 10

    /// Run the bootstrap if it has not been completed.
    ///
    /// Safe to call on every launch — uses UserDefaults to skip after the
    /// first successful run. Also no-ops if any Sphere already exists in
    /// the store (defensive: if a user somehow created one before migration,
    /// we don't replace it).
    ///
    /// Reads the user's PracticeType to decide whether to seed a Funnel-mode
    /// Client Pipeline Trajectory with stages. General users get an empty
    /// Sphere; they'll define Trajectories in Phase 5+.
    ///
    /// Stays on the main actor (repositories require it) but yields
    /// periodically so the UI stays responsive during the per-person loop.
    static func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: migrationDoneKey) else { return }

        do {
            // Defensive: if the user already has a Sphere, mark migration
            // done and bail. We do not overwrite user-created state.
            if try !SphereRepository.shared.isEmpty() {
                UserDefaults.standard.set(true, forKey: migrationDoneKey)
                logger.info("Bootstrap skipped — Sphere already exists in store.")
                return
            }

            let profile = await BusinessProfileService.shared.profile()
            let practiceType = profile.practiceType

            logger.info("Sphere bootstrap starting — practiceType: \(practiceType.rawValue)")

            // 1. Create the auto-Sphere.
            let sphere = try SphereRepository.shared.createSphere(
                name: defaultSphereName,
                purpose: defaultPurpose(for: practiceType),
                accentColor: .slate,
                defaultMode: .stewardship,
                defaultCadenceDays: nil,
                isBootstrapDefault: true
            )
            await Task.yield()

            // 2. For WFG, create the Funnel-mode Client Pipeline Trajectory.
            //    General users start with an empty Sphere; they'll create
            //    Trajectories explicitly in Phase 5+.
            var clientPipeline: Trajectory? = nil
            var stagesByName: [String: TrajectoryStage] = [:]
            if practiceType == .wfgFinancialAdvisor {
                clientPipeline = try TrajectoryRepository.shared.createTrajectory(
                    sphereID: sphere.id,
                    name: "Client Pipeline",
                    mode: .funnel,
                    notes: "Bootstrap-created from existing Lead → Applicant → Client pipeline."
                )
                if let trajID = clientPipeline?.id {
                    for (idx, stageInfo) in wfgPipelineStages.enumerated() {
                        if let stage = try TrajectoryRepository.shared.addStage(
                            trajectoryID: trajID,
                            name: stageInfo.name,
                            sortOrder: idx,
                            isTerminal: stageInfo.isTerminal
                        ) {
                            stagesByName[stageInfo.name] = stage
                        }
                    }
                }
                await Task.yield()
            }

            // 3. Seed every existing Person with a Sphere membership and,
            //    where applicable, a PersonTrajectoryEntry on the Client Pipeline.
            let context = ModelContext(SAMModelContainer.shared)
            let people = try context.fetch(FetchDescriptor<SamPerson>())
            let totalPeople = people.count
            logger.info("Sphere bootstrap seeding \(totalPeople) persons")
            var membershipsCreated = 0
            var entriesCreated = 0

            for (idx, person) in people.enumerated() {
                try SphereRepository.shared.addMember(
                    personID: person.id,
                    sphereID: sphere.id
                )
                membershipsCreated += 1

                if let trajectory = clientPipeline,
                   let stageName = derivedPipelineStage(for: person),
                   let stage = stagesByName[stageName] {
                    try PersonTrajectoryRepository.shared.enter(
                        personID: person.id,
                        trajectoryID: trajectory.id,
                        stageID: stage.id,
                        cadenceDaysOverride: nil,
                        at: derivedEnteredAt(for: person, stageName: stageName)
                    )
                    entriesCreated += 1
                }

                // Yield to the main runloop so launch UI can paint and
                // accept input while seeding runs. Bursts of ~10 persons
                // are fast enough not to feel choppy on the first paint.
                if (idx + 1) % yieldEveryNPersons == 0 {
                    await Task.yield()
                }
            }

            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            // PersonModeResolver may have observed an empty store before
            // bootstrap ran — drop its cache so the next read sees seeded data.
            PersonModeResolver.invalidateCache()
            logger.notice("Sphere bootstrap complete — \(membershipsCreated) memberships, \(entriesCreated) trajectory entries")
        } catch {
            logger.error("Sphere bootstrap failed: \(error.localizedDescription)")
            // Do NOT set the done flag — we want a retry on next launch.
        }
    }

    // MARK: - Helpers

    /// Returns the user-facing purpose statement seeded on the auto-Sphere.
    private static func defaultPurpose(for practiceType: PracticeType) -> String {
        switch practiceType {
        case .wfgFinancialAdvisor:
            return "Your financial advisory practice — clients, applicants, leads, and the people who refer them."
        case .general:
            return "Your default context. Rename, refine, or split into more Spheres at any time."
        }
    }

    /// Derive the pipeline stage name for a person at migration time.
    ///
    /// Preference order (matching phase0_audit.md §3 guidance):
    /// 1. Most recent StageTransition.toStage in the client pipeline.
    /// 2. roleBadges containing one of "Client" / "Applicant" / "Lead".
    /// 3. nil — person is not on the pipeline and gets only a membership.
    private static func derivedPipelineStage(for person: SamPerson) -> String? {
        // Try StageTransition first — it's the canonical source.
        if let transitions = try? PipelineRepository.shared.fetchTransitions(forPerson: person.id) {
            let clientTransitions = transitions.filter { $0.pipelineType == .client }
            if let latest = clientTransitions.first {  // already sorted desc by date
                let stageName = latest.toStage
                if wfgPipelineStages.contains(where: { $0.name == stageName }) {
                    return stageName
                }
            }
        }

        // Fall back to roleBadges. This is the conflation Phase 8 will retire,
        // but for migration-time stage derivation it's the only data we have
        // for people who never went through a recorded transition.
        for stage in wfgPipelineStages.reversed() {
            if person.roleBadges.contains(stage.name) {
                return stage.name
            }
        }
        return nil
    }

    /// Best-guess entry timestamp for migrated trajectory entries.
    /// Uses the most recent StageTransition date for that stage if known,
    /// otherwise falls back to the most recent sync time (or now).
    /// SamPerson has no createdAt field; lastSyncedAt is the closest proxy
    /// for "when SAM first saw this person".
    private static func derivedEnteredAt(for person: SamPerson, stageName: String) -> Date {
        if let transitions = try? PipelineRepository.shared.fetchTransitions(forPerson: person.id) {
            if let match = transitions.first(where: { $0.toStage == stageName && $0.pipelineType == .client }) {
                return match.transitionDate
            }
        }
        return person.lastSyncedAt ?? .now
    }
}
