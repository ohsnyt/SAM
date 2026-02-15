//
//  ContextsRepository.swift
//  SAM_crm
//
//  Created by Assistant on 2/11/26.
//  Phase G: Contexts
//
//  SwiftData CRUD operations for SamContext.
//  Manages households, businesses, and other relationship environments.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class ContextsRepository {
    
    // MARK: - Singleton
    
    static let shared = ContextsRepository()
    
    // MARK: - Container

    private var container: ModelContainer?
    private var modelContext: ModelContext?

    private init() {}

    /// Configure the repository with the app-wide ModelContainer.
    /// Must be called once at app launch before any operations.
    func configure(container: ModelContainer) {
        self.container = container
        self.modelContext = ModelContext(container)
    }
    
    // MARK: - CRUD Operations
    
    /// Fetch all contexts from SwiftData
    func fetchAll() throws -> [SamContext] {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamContext>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )

        return try modelContext.fetch(descriptor)
    }
    
    /// Fetch a single context by UUID
    func fetch(id: UUID) throws -> SamContext? {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Swift 6: Fetch all and filter in memory
        let descriptor = FetchDescriptor<SamContext>()
        let allContexts = try modelContext.fetch(descriptor)
        return allContexts.first { $0.id == id }
    }
    
    /// Create a new context
    func create(
        name: String,
        kind: ContextKind,
        consentAlertCount: Int = 0,
        reviewAlertCount: Int = 0,
        followUpAlertCount: Int = 0
    ) throws -> SamContext {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let newContext = SamContext(
            id: UUID(),
            name: name,
            kind: kind,
            consentAlertCount: consentAlertCount,
            reviewAlertCount: reviewAlertCount,
            followUpAlertCount: followUpAlertCount
        )

        modelContext.insert(newContext)
        try modelContext.save()

        return newContext
    }
    
    /// Update an existing context
    func update(
        context samContext: SamContext,
        name: String? = nil,
        kind: ContextKind? = nil
    ) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        if let name = name {
            samContext.name = name
        }

        if let kind = kind {
            samContext.kind = kind
        }

        try modelContext.save()
    }
    
    /// Delete a context
    func delete(context samContext: SamContext) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        modelContext.delete(samContext)
        try modelContext.save()
    }
    
    /// Search contexts by name
    func search(query: String) throws -> [SamContext] {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        guard !query.isEmpty else {
            return try fetchAll()
        }

        // Fetch all and filter in memory
        let descriptor = FetchDescriptor<SamContext>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )

        let allContexts = try modelContext.fetch(descriptor)
        let lowercaseQuery = query.lowercased()

        return allContexts.filter { ctx in
            ctx.name.lowercased().contains(lowercaseQuery)
        }
    }
    
    /// Filter contexts by kind
    func filter(by kind: ContextKind) throws -> [SamContext] {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Fetch all and filter in memory
        let descriptor = FetchDescriptor<SamContext>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )

        let allContexts = try modelContext.fetch(descriptor)
        return allContexts.filter { $0.kind == kind }
    }
    
    /// Add a person to a context with a role
    func addParticipant(
        person: SamPerson,
        to samContext: SamContext,
        roleBadges: [String] = [],
        isPrimary: Bool = false,
        note: String? = nil
    ) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Check if participation already exists
        let existingParticipation = samContext.participations.first { participation in
            participation.person?.id == person.id
        }

        if let existing = existingParticipation {
            // Update existing participation
            existing.roleBadges = roleBadges
            existing.isPrimary = isPrimary
            existing.note = note
        } else {
            // Create new participation
            let participation = ContextParticipation(
                id: UUID(),
                person: person,
                context: samContext,
                roleBadges: roleBadges,
                isPrimary: isPrimary,
                note: note
            )

            samContext.participations.append(participation)
        }

        try modelContext.save()
    }
    
    /// Remove a person from a context
    func removeParticipant(person: SamPerson, from samContext: SamContext) throws {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        // Find and remove the participation
        if let participation = samContext.participations.first(where: { $0.person?.id == person.id }) {
            modelContext.delete(participation)
            try modelContext.save()
        }
    }
    
    /// Get count of all contexts
    func count() throws -> Int {
        guard let modelContext = modelContext else {
            throw RepositoryError.notConfigured
        }

        let descriptor = FetchDescriptor<SamContext>()
        return try modelContext.fetchCount(descriptor)
    }
}
