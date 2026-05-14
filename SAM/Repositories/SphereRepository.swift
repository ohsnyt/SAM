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

    /// Uses `container.mainContext` rather than a private `ModelContext` so
    /// memberships created from PersonDetailView (which reads via `@Query`
    /// on the mainContext) don't strand SamPerson references in a sibling
    /// context. Cross-context relationships fault the next SwiftUI render
    /// with "backing data was detached from a context without resolving
    /// attribute faults" on properties like `roleBadges` or `familyReferences`.
    func configure(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
    }

    // MARK: - Sphere: Create

    /// Create a new Sphere. Returns the inserted record.
    @discardableResult
    func createSphere(
        name: String,
        purpose: String = "",
        classificationProfile: String = "",
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
            classificationProfile: classificationProfile,
            accentColor: accentColor,
            defaultMode: defaultMode,
            defaultCadenceDays: defaultCadenceDays,
            sortOrder: sortOrder,
            isBootstrapDefault: isBootstrapDefault
        )
        context.insert(sphere)
        try context.save()
        logger.debug("Created Sphere '\(name)' (id: \(sphere.id), order: \(sortOrder), bootstrap: \(isBootstrapDefault))")
        NotificationCenter.default.post(name: .samSphereDidChange, object: nil)
        return sphere
    }

    /// Create a Sphere from a shipped `LifeSphereTemplate`. Used by the
    /// first-run sphere-selection flow and the "Add sphere" UI. Carries
    /// the template's `classificationProfile` so the classifier has real
    /// context from day one.
    @discardableResult
    func createSphere(from template: LifeSphereTemplate) throws -> Sphere {
        try createSphere(
            name: template.name,
            purpose: template.purpose,
            classificationProfile: template.classificationProfile,
            accentColor: template.accentColor,
            defaultMode: template.defaultMode
        )
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
        classificationProfile: String? = nil,
        keywordHints: [String]? = nil,
        accentColor: SphereAccentColor? = nil,
        defaultMode: Mode? = nil,
        defaultCadenceDays: Int?? = nil,
        sortOrder: Int? = nil
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let sphere = try fetch(id: id) else { return }
        if let name { sphere.name = name }
        if let purpose { sphere.purpose = purpose }
        if let classificationProfile { sphere.classificationProfile = classificationProfile }
        if let keywordHints { sphere.keywordHints = keywordHints }
        if let accentColor { sphere.accentColor = accentColor }
        if let defaultMode { sphere.defaultMode = defaultMode }
        if let defaultCadenceDays { sphere.defaultCadenceDays = defaultCadenceDays }
        if let sortOrder { sphere.sortOrder = sortOrder }
        try context.save()
        NotificationCenter.default.post(name: .samSphereDidChange, object: nil)
    }

    func setArchived(id: UUID, _ archived: Bool) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let sphere = try fetch(id: id) else { return }
        sphere.archived = archived
        try context.save()
        NotificationCenter.default.post(name: .samSphereDidChange, object: nil)
    }

    // MARK: - Sphere: Example pool

    /// Append a user-confirmed example to a sphere's classification pool.
    /// Idempotent on `evidenceID` — re-confirming the same row does not
    /// duplicate; an override later in the row's life *upgrades* the
    /// existing entry's `wasOverride` flag instead of inserting a second.
    /// When the pool exceeds `Sphere.maxExamples`, evicts the oldest
    /// non-override first; if all entries are overrides, evicts the
    /// oldest. Returns the inserted/updated example, or nil if the
    /// sphere wasn't found.
    @discardableResult
    func recordExample(
        sphereID: UUID,
        evidenceID: UUID,
        snippet: String,
        wasOverride: Bool
    ) throws -> SphereExample? {
        guard let context else { throw RepositoryError.notConfigured }
        guard let sphere = try fetch(id: sphereID) else { return nil }

        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Idempotent on evidenceID — upgrade flag if needed.
        if let existing = sphere.examples.first(where: { $0.evidenceID == evidenceID }) {
            if wasOverride && !existing.wasOverride {
                existing.wasOverride = true
                existing.addedAt = .now
                try context.save()
            }
            return existing
        }

        let example = SphereExample(
            evidenceID: evidenceID,
            snippet: trimmed,
            wasOverride: wasOverride,
            sphere: sphere
        )
        context.insert(example)
        sphere.examples.append(example)

        // Rotation: keep ≤ maxExamples. Prefer evicting non-overrides; if
        // every entry is an override, drop the oldest.
        if sphere.examples.count > Sphere.maxExamples {
            let sorted = sphere.examples.sorted { $0.addedAt < $1.addedAt }
            let oldestNonOverride = sorted.first { !$0.wasOverride }
            let victim = oldestNonOverride ?? sorted.first
            if let victim {
                sphere.examples.removeAll { $0.id == victim.id }
                context.delete(victim)
            }
        }

        try context.save()
        return example
    }

    /// Spheres the user added at least 30 days ago that still have fewer
    /// than three confirmed examples. Surfaced in the EOD review batch as
    /// "Merge or remove?" prompts — proliferation friction for spheres
    /// that turned out not to have a real signal behind them.
    func staleEmptySpheres(
        olderThanDays days: Int = 30,
        minExamples: Int = 3
    ) throws -> [Sphere] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        return try fetchAll().filter { sphere in
            !sphere.isBootstrapDefault
                && sphere.createdAt <= cutoff
                && sphere.examples.count < minExamples
        }
    }

    /// Remove an example from a sphere's pool by ID. Used by management
    /// UI when the user wants to forget a specific snippet.
    func removeExample(exampleID: UUID, fromSphere sphereID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let sphere = try fetch(id: sphereID) else { return }
        guard let target = sphere.examples.first(where: { $0.id == exampleID }) else { return }
        sphere.examples.removeAll { $0.id == exampleID }
        context.delete(target)
        try context.save()
    }

    private func nextSortOrder() throws -> Int {
        let all = try fetchAllIncludingArchived()
        return (all.map { $0.sortOrder }.max() ?? -1) + 1
    }

    // MARK: - PersonSphereMembership: Mutations

    /// Add a person to a Sphere. Idempotent — returns existing membership if any.
    /// The new membership's `order` is seeded from `Sphere.sortOrder` (the
    /// user's global sphere ordering), so a new person added to several
    /// spheres in one onboarding pass takes the globally-preferred sphere
    /// as their default. Users can then reorder per-person via the chevrons
    /// on PersonDetail without disturbing global order.
    @discardableResult
    func addMember(personID: UUID, sphereID: UUID, notes: String? = nil) throws -> PersonSphereMembership? {
        guard let context else { throw RepositoryError.notConfigured }

        if let existing = try membership(personID: personID, sphereID: sphereID) {
            return existing
        }

        let person = try resolvePerson(id: personID)
        guard let sphere = try fetch(id: sphereID) else { return nil }
        guard person != nil else { return nil }

        let order = sphere.sortOrder
        let membership = PersonSphereMembership(
            person: person,
            sphere: sphere,
            notes: notes,
            order: order
        )
        context.insert(membership)
        try context.save()
        logger.debug("Added person \(personID) to Sphere \(sphereID) at order \(order)")
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

    /// All Spheres a person belongs to (non-archived only). Sorted by
    /// each membership's `order` so the **first element is the person's
    /// default sphere** — the one used when evidence has no explicit
    /// `contextSphere` and when no lens is active.
    func spheres(forPerson personID: UUID) throws -> [Sphere] {
        let memberships = try memberships(forPerson: personID)
        return memberships.compactMap { $0.sphere }.filter { !$0.archived }
    }

    /// Active memberships for a person, ordered. First element drives the
    /// default sphere; later elements are minority spheres that require
    /// explicit classification or keyword override on evidence.
    func memberships(forPerson personID: UUID) throws -> [PersonSphereMembership] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<PersonSphereMembership>()
        let all = try context.fetch(descriptor)
        return all
            .filter { $0.person?.id == personID && ($0.sphere?.archived == false) }
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.addedAt < rhs.addedAt
            }
    }

    /// Convenience: the person's default Sphere (lowest-order, non-archived
    /// membership). Nil if the person has no active memberships — caller
    /// decides whether to fall through to a global default or skip.
    func defaultSphere(forPerson personID: UUID) throws -> Sphere? {
        try memberships(forPerson: personID).first?.sphere
    }

    /// Rewrite the `order` field for the given person's memberships to
    /// match the supplied sphere order. Spheres not present in the list
    /// keep their relative ordering but sort after the explicit ones.
    /// Drag-to-reorder in the person detail view calls this.
    func reorderMemberships(forPerson personID: UUID, sphereOrder: [UUID]) throws {
        guard let context else { throw RepositoryError.notConfigured }
        let existing = try memberships(forPerson: personID)
        let rank = Dictionary(uniqueKeysWithValues: sphereOrder.enumerated().map { ($1, $0) })
        let trailingBase = sphereOrder.count
        for membership in existing {
            guard let sphereID = membership.sphere?.id else { continue }
            if let r = rank[sphereID] {
                membership.order = r
            } else {
                membership.order = trailingBase + Int(membership.addedAt.timeIntervalSince1970)
            }
        }
        try context.save()
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
