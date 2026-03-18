//
//  RoleRecruitingRepository.swift
//  SAM
//
//  Created on March 17, 2026.
//  Role Recruiting: CRUD for RoleDefinition + RoleCandidate.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RoleRecruitingRepository")

@MainActor
@Observable
final class RoleRecruitingRepository {

    // MARK: - Singleton

    static let shared = RoleRecruitingRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - RoleDefinition: Fetch

    func fetchActiveRoles() throws -> [RoleDefinition] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<RoleDefinition>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).filter { $0.isActive }
    }

    func fetchAllRoles() throws -> [RoleDefinition] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<RoleDefinition>(
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    func fetchRole(id: UUID) throws -> RoleDefinition? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<RoleDefinition>()
        return try context.fetch(descriptor).first { $0.id == id }
    }

    // MARK: - RoleDefinition: Save / Delete

    func saveRoleDefinition(_ role: RoleDefinition) throws {
        guard let context else { throw RepositoryError.notConfigured }
        // Check if it already exists
        let existing = try fetchRole(id: role.id)
        if existing == nil {
            context.insert(role)
        }
        role.updatedAt = .now
        try context.save()
        logger.debug("Saved role definition: \(role.name)")
    }

    func deleteRoleDefinition(_ role: RoleDefinition) throws {
        guard let context else { throw RepositoryError.notConfigured }
        context.delete(role)
        try context.save()
        logger.debug("Deleted role definition: \(role.name)")
    }

    // MARK: - RoleCandidate: Fetch

    func fetchCandidates(for roleID: UUID, includeTerminal: Bool = false) throws -> [RoleCandidate] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<RoleCandidate>()
        let all = try context.fetch(descriptor)
        return all.filter { candidate in
            candidate.roleDefinition?.id == roleID
            && (includeTerminal || !candidate.stage.isTerminal)
        }
    }

    func fetchCandidate(personID: UUID, roleID: UUID) throws -> RoleCandidate? {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<RoleCandidate>()
        let all = try context.fetch(descriptor)
        return all.first { $0.person?.id == personID && $0.roleDefinition?.id == roleID }
    }

    func fetchAllCandidates() throws -> [RoleCandidate] {
        guard let context else { throw RepositoryError.notConfigured }
        let descriptor = FetchDescriptor<RoleCandidate>()
        return try context.fetch(descriptor)
    }

    // MARK: - RoleCandidate: Save / Delete

    func saveCandidate(_ candidate: RoleCandidate) throws {
        guard let context else { throw RepositoryError.notConfigured }
        // Only insert if not already tracked by this context
        let existing = try? context.fetch(FetchDescriptor<RoleCandidate>()).first { $0.id == candidate.id }
        if existing == nil {
            context.insert(candidate)
        }
        try context.save()
        logger.debug("Saved candidate: \(candidate.person?.displayNameCache ?? "unknown") for \(candidate.roleDefinition?.name ?? "unknown")")
    }

    func deleteCandidate(_ candidate: RoleCandidate) throws {
        guard let context else { throw RepositoryError.notConfigured }
        context.delete(candidate)
        try context.save()
    }

    // MARK: - Refinement Notes

    func addRefinementNote(roleID: UUID, note: String) throws {
        guard let role = try fetchRole(id: roleID) else { return }
        var notes = role.refinementNotes
        notes.append(note)
        role.refinementNotes = notes
        role.updatedAt = .now
        try context?.save()
        logger.debug("Added refinement note to \(role.name): \(note)")
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "RoleRecruitingRepository not configured — call configure(container:) first"
            }
        }
    }
}
