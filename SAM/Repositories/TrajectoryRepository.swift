//
//  TrajectoryRepository.swift
//  SAM
//
//  Phase 1 of the relationship-model refactor (May 2026).
//
//  CRUD for Trajectory and TrajectoryStage. Person-entry CRUD lives in
//  PersonTrajectoryRepository (kept separate so caller intent stays clear:
//  "I am defining the arc" vs "I am placing a person on the arc").
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TrajectoryRepository")

@MainActor
@Observable
final class TrajectoryRepository {

    // MARK: - Singleton

    static let shared = TrajectoryRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Trajectory: Create

    /// Create a Trajectory inside (or outside) a Sphere. Returns the inserted record.
    @discardableResult
    func createTrajectory(
        sphereID: UUID?,
        name: String,
        mode: Mode,
        notes: String? = nil
    ) throws -> Trajectory {
        guard let context else { throw RepositoryError.notConfigured }

        let sphere: Sphere? = try {
            guard let sphereID else { return nil }
            return try SphereRepository.shared.fetch(id: sphereID)
        }()

        let trajectory = Trajectory(
            sphere: sphere,
            name: name,
            mode: mode,
            notes: notes
        )
        context.insert(trajectory)
        try context.save()
        logger.debug("Created Trajectory '\(name)' (mode: \(mode.rawValue), sphere: \(sphereID?.uuidString ?? "(none)"))")
        return trajectory
    }

    // MARK: - Trajectory: Fetch

    /// All non-archived Trajectories in a given Sphere, sorted by createdAt.
    func fetchAll(forSphere sphereID: UUID) throws -> [Trajectory] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<Trajectory>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.sphere?.id == sphereID && !$0.archived }
    }

    /// All non-archived Trajectories across all Spheres.
    func fetchAll() throws -> [Trajectory] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<Trajectory>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { !$0.archived }
    }

    func fetch(id: UUID) throws -> Trajectory? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<Trajectory>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    // MARK: - Trajectory: Update / Archive / Close

    func updateTrajectory(
        id: UUID,
        name: String? = nil,
        mode: Mode? = nil,
        notes: String?? = nil
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let trajectory = try fetch(id: id) else { return }
        if let name { trajectory.name = name }
        if let mode { trajectory.mode = mode }
        if let notes { trajectory.notes = notes }
        try context.save()
    }

    func setArchived(id: UUID, _ archived: Bool) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let trajectory = try fetch(id: id) else { return }
        trajectory.archived = archived
        try context.save()
    }

    /// Close the Trajectory itself (Campaign goal reached, replaced by successor).
    /// Cascades `TrajectoryExitReason.trajectoryClosed` to any still-active
    /// PersonTrajectoryEntry on this Trajectory.
    func close(id: UUID, at: Date = .now) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let trajectory = try fetch(id: id) else { return }
        trajectory.completedAt = at

        let active = trajectory.entries.filter { $0.isActive }
        for entry in active {
            entry.exitedAt = at
            entry.exitReason = .trajectoryClosed
        }
        try context.save()
        logger.info("Closed Trajectory '\(trajectory.name)' — cascaded close to \(active.count) active entries")
    }

    // MARK: - TrajectoryStage: Create / Fetch / Update

    @discardableResult
    func addStage(
        trajectoryID: UUID,
        name: String,
        sortOrder: Int? = nil,
        isTerminal: Bool = false,
        cadenceDaysOverride: Int? = nil
    ) throws -> TrajectoryStage? {
        guard let context else { throw RepositoryError.notConfigured }
        guard let trajectory = try fetch(id: trajectoryID) else { return nil }

        let order = sortOrder ?? ((trajectory.stages.map { $0.sortOrder }.max() ?? -1) + 1)
        let stage = TrajectoryStage(
            trajectory: trajectory,
            name: name,
            sortOrder: order,
            isTerminal: isTerminal,
            stageCadenceDaysOverride: cadenceDaysOverride
        )
        context.insert(stage)
        try context.save()
        return stage
    }

    /// Stages on a Trajectory, sorted by sortOrder.
    func fetchStages(forTrajectory trajectoryID: UUID) throws -> [TrajectoryStage] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<TrajectoryStage>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.trajectory?.id == trajectoryID }
    }

    func fetchStage(id: UUID) throws -> TrajectoryStage? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<TrajectoryStage>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    func updateStage(
        id: UUID,
        name: String? = nil,
        sortOrder: Int? = nil,
        isTerminal: Bool? = nil,
        cadenceDaysOverride: Int?? = nil
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let stage = try fetchStage(id: id) else { return }
        if let name { stage.name = name }
        if let sortOrder { stage.sortOrder = sortOrder }
        if let isTerminal { stage.isTerminal = isTerminal }
        if let cadenceDaysOverride { stage.stageCadenceDaysOverride = cadenceDaysOverride }
        try context.save()
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "TrajectoryRepository not configured — call configure(container:) first"
            }
        }
    }
}
