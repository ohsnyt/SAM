//
//  PersonTrajectoryRepository.swift
//  SAM
//
//  Phase 1 of the relationship-model refactor (May 2026).
//
//  CRUD for PersonTrajectoryEntry — the per-person record of being on a
//  Trajectory at a given stage. A person may have multiple active entries
//  across different Trajectories simultaneously (e.g., a Client also being
//  recruited as an Agent).
//
//  Phase 1 writes entries via the bootstrap migration (deriving from the
//  most recent StageTransition per person) but no existing system reads
//  from them yet. Phase 8 promotes them to canonical.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PersonTrajectoryRepository")

@MainActor
@Observable
final class PersonTrajectoryRepository {

    // MARK: - Singleton

    static let shared = PersonTrajectoryRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Entry: Enter

    /// Place a person onto a Trajectory at the given stage (or the first stage if nil).
    /// Returns the new entry; returns nil if person or trajectory not found.
    /// Caller is responsible for closing any prior active entry on the same Trajectory.
    @discardableResult
    func enter(
        personID: UUID,
        trajectoryID: UUID,
        stageID: UUID? = nil,
        cadenceDaysOverride: Int? = nil,
        at: Date = .now
    ) throws -> PersonTrajectoryEntry? {
        guard let context else { throw RepositoryError.notConfigured }

        guard let person = try resolvePerson(id: personID),
              let trajectory = try TrajectoryRepository.shared.fetch(id: trajectoryID) else {
            return nil
        }

        let stage: TrajectoryStage? = try {
            if let stageID { return try TrajectoryRepository.shared.fetchStage(id: stageID) }
            return try TrajectoryRepository.shared.fetchStages(forTrajectory: trajectoryID).first
        }()

        let entry = PersonTrajectoryEntry(
            person: person,
            trajectory: trajectory,
            currentStage: stage,
            cadenceDaysOverride: cadenceDaysOverride,
            enteredAt: at
        )
        context.insert(entry)
        try context.save()
        logger.debug("Entered person \(personID) on Trajectory '\(trajectory.name)' at stage '\(stage?.name ?? "(none)")'")
        return entry
    }

    // MARK: - Entry: Move stage

    /// Move an active entry to a new stage. No-op if the entry is exited or
    /// the stage does not belong to the entry's Trajectory.
    func moveStage(entryID: UUID, to stageID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let entry = try fetch(id: entryID), entry.isActive else { return }
        guard let stage = try TrajectoryRepository.shared.fetchStage(id: stageID) else { return }
        guard stage.trajectory?.id == entry.trajectory?.id else { return }

        entry.currentStage = stage
        try context.save()
    }

    // MARK: - Entry: Exit

    /// Close an active entry with a reason. No-op if already exited.
    func exit(
        entryID: UUID,
        reason: TrajectoryExitReason,
        at: Date = .now,
        notes: String? = nil
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let entry = try fetch(id: entryID), entry.isActive else { return }
        entry.exitedAt = at
        entry.exitReason = reason
        if let notes { entry.exitNotes = notes }
        try context.save()
        logger.debug("Exited entry \(entryID) — reason: \(reason.rawValue)")
    }

    // MARK: - Entry: Fetch

    func fetch(id: UUID) throws -> PersonTrajectoryEntry? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonTrajectoryEntry>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    /// All currently-active entries for a person across every Trajectory.
    func activeEntries(forPerson personID: UUID) throws -> [PersonTrajectoryEntry] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonTrajectoryEntry>(
            sortBy: [SortDescriptor(\.enteredAt, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.person?.id == personID && $0.isActive }
    }

    /// All currently-active entries on a Trajectory.
    func activeEntries(forTrajectory trajectoryID: UUID) throws -> [PersonTrajectoryEntry] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonTrajectoryEntry>(
            sortBy: [SortDescriptor(\.enteredAt, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.trajectory?.id == trajectoryID && $0.isActive }
    }

    /// All entries (active + historical) for a person, sorted by enteredAt.
    func allEntries(forPerson personID: UUID) throws -> [PersonTrajectoryEntry] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonTrajectoryEntry>(
            sortBy: [SortDescriptor(\.enteredAt, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.person?.id == personID }
    }

    /// True if a person has any active entry on the given Trajectory.
    func hasActiveEntry(personID: UUID, trajectoryID: UUID) throws -> Bool {
        let entries = try activeEntries(forPerson: personID)
        return entries.contains { $0.trajectory?.id == trajectoryID }
    }

    /// All active entries across every person and Trajectory. Used by bulk
    /// resolvers (e.g., PersonModeResolver) to avoid N per-person fetches
    /// during briefing/health refreshes.
    func fetchAllActive() throws -> [PersonTrajectoryEntry] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonTrajectoryEntry>()
        let all = try context.fetch(descriptor)
        return all.filter { $0.isActive }
    }

    // MARK: - Helpers

    private func resolvePerson(id: UUID) throws -> SamPerson? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<SamPerson>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "PersonTrajectoryRepository not configured — call configure(container:) first"
            }
        }
    }
}
