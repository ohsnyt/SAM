//
//  SphereRepository.swift
//  SAM
//
//  Phase 1 of the relationship-model refactor (May 2026).
//
//  CRUD for Sphere and PersonSphereMembership. Membership lives here (not in
//  its own repo) because it's the join between a Sphere and the people in it.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SphereRepository")

@MainActor
@Observable
final class SphereRepository {

    // MARK: - Singleton

    static let shared = SphereRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Sphere: Create

    /// Create a new Sphere. Returns the inserted record.
    @discardableResult
    func createSphere(
        name: String,
        purpose: String = "",
        accentColor: SphereAccentColor = .slate,
        defaultMode: Mode = .stewardship,
        defaultCadenceDays: Int? = nil,
        isBootstrapDefault: Bool = false
    ) throws -> Sphere {
        guard let context else { throw RepositoryError.notConfigured }

        let sortOrder = try nextSortOrder()
        let sphere = Sphere(
            name: name,
            purpose: purpose,
            accentColor: accentColor,
            defaultMode: defaultMode,
            defaultCadenceDays: defaultCadenceDays,
            sortOrder: sortOrder,
            isBootstrapDefault: isBootstrapDefault
        )
        context.insert(sphere)
        try context.save()
        logger.debug("Created Sphere '\(name)' (id: \(sphere.id), order: \(sortOrder), bootstrap: \(isBootstrapDefault))")
        return sphere
    }

    // MARK: - Sphere: Fetch

    /// All non-archived Spheres, sorted by user-set order.
    func fetchAll() throws -> [Sphere] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<Sphere>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { !$0.archived }
    }

    /// All Spheres including archived, sorted by user-set order.
    func fetchAllIncludingArchived() throws -> [Sphere] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<Sphere>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func fetch(id: UUID) throws -> Sphere? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<Sphere>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    /// The bootstrap default Sphere, if one exists. Used by the migration
    /// path and by Phase 5+ "split this default into multiple Spheres" flow.
    func fetchBootstrapDefault() throws -> Sphere? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<Sphere>()
        let all = try context.fetch(descriptor)
        return all.first { $0.isBootstrapDefault }
    }

    /// True if no Sphere exists in the store. Bootstrap migration uses this gate.
    func isEmpty() throws -> Bool {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<Sphere>()
        return try context.fetch(descriptor).isEmpty
    }

    // MARK: - Sphere: Update / Archive

    /// Update display fields on a Sphere.
    func updateSphere(
        id: UUID,
        name: String? = nil,
        purpose: String? = nil,
        accentColor: SphereAccentColor? = nil,
        defaultMode: Mode? = nil,
        defaultCadenceDays: Int?? = nil,
        sortOrder: Int? = nil
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let sphere = try fetch(id: id) else { return }
        if let name { sphere.name = name }
        if let purpose { sphere.purpose = purpose }
        if let accentColor { sphere.accentColor = accentColor }
        if let defaultMode { sphere.defaultMode = defaultMode }
        if let defaultCadenceDays { sphere.defaultCadenceDays = defaultCadenceDays }
        if let sortOrder { sphere.sortOrder = sortOrder }
        try context.save()
    }

    func setArchived(id: UUID, _ archived: Bool) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let sphere = try fetch(id: id) else { return }
        sphere.archived = archived
        try context.save()
    }

    private func nextSortOrder() throws -> Int {
        let all = try fetchAllIncludingArchived()
        return (all.map { $0.sortOrder }.max() ?? -1) + 1
    }

    // MARK: - PersonSphereMembership: Mutations

    /// Add a person to a Sphere. Idempotent — returns existing membership if any.
    @discardableResult
    func addMember(personID: UUID, sphereID: UUID, notes: String? = nil) throws -> PersonSphereMembership? {
        guard let context else { throw RepositoryError.notConfigured }

        if let existing = try membership(personID: personID, sphereID: sphereID) {
            return existing
        }

        let person = try resolvePerson(id: personID)
        let sphere = try fetch(id: sphereID)
        guard person != nil, sphere != nil else { return nil }

        let membership = PersonSphereMembership(
            person: person,
            sphere: sphere,
            notes: notes
        )
        context.insert(membership)
        try context.save()
        logger.debug("Added person \(personID) to Sphere \(sphereID)")
        return membership
    }

    /// Remove a person from a Sphere. No-op if no membership exists.
    func removeMember(personID: UUID, sphereID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let membership = try membership(personID: personID, sphereID: sphereID) else { return }
        context.delete(membership)
        try context.save()
    }

    // MARK: - PersonSphereMembership: Queries

    /// All membership records for a Sphere (active people in this Sphere).
    func memberships(forSphere sphereID: UUID) throws -> [PersonSphereMembership] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonSphereMembership>(
            sortBy: [SortDescriptor(\.addedAt, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.sphere?.id == sphereID }
    }

    /// All Spheres a person belongs to (non-archived only).
    func spheres(forPerson personID: UUID) throws -> [Sphere] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonSphereMembership>()
        let all = try context.fetch(descriptor)
        let spheres = all
            .filter { $0.person?.id == personID }
            .compactMap { $0.sphere }
            .filter { !$0.archived }
        return spheres.sorted { $0.sortOrder < $1.sortOrder }
    }

    func isMember(personID: UUID, sphereID: UUID) throws -> Bool {
        try membership(personID: personID, sphereID: sphereID) != nil
    }

    /// All membership rows in the store. Used by bulk resolvers
    /// (e.g., PersonModeResolver) to avoid N per-person fetches during
    /// briefing/health refreshes. Caller filters as needed.
    func fetchAllMemberships() throws -> [PersonSphereMembership] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonSphereMembership>()
        return try context.fetch(descriptor)
    }

    private func membership(personID: UUID, sphereID: UUID) throws -> PersonSphereMembership? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonSphereMembership>()
        let all = try context.fetch(descriptor)
        return all.first { $0.person?.id == personID && $0.sphere?.id == sphereID }
    }

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
                return "SphereRepository not configured — call configure(container:) first"
            }
        }
    }
}
