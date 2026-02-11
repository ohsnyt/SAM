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
    
    private init() {
        print("📦 [ContextsRepository] Initialized")
    }
    
    /// Configure the repository with the app-wide ModelContainer.
    /// Must be called once at app launch before any operations.
    func configure(container: ModelContainer) {
        self.container = container
        print("📦 [ContextsRepository] Configured with container: \(Unmanaged.passUnretained(container).toOpaque())")
    }
    
    // MARK: - CRUD Operations
    
    /// Fetch all contexts from SwiftData
    func fetchAll() throws -> [SamContext] {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<SamContext>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        
        let contexts = try context.fetch(descriptor)
        print("📦 [ContextsRepository] Fetched \(contexts.count) contexts")
        return contexts
    }
    
    /// Fetch a single context by UUID
    func fetch(id: UUID) throws -> SamContext? {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        
        // Swift 6: Fetch all and filter in memory
        let descriptor = FetchDescriptor<SamContext>()
        let allContexts = try context.fetch(descriptor)
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
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        
        let newContext = SamContext(
            id: UUID(),
            name: name,
            kind: kind,
            consentAlertCount: consentAlertCount,
            reviewAlertCount: reviewAlertCount,
            followUpAlertCount: followUpAlertCount
        )
        
        context.insert(newContext)
        try context.save()
        
        print("📦 [ContextsRepository] Created: \(name) (\(kind.rawValue))")
        return newContext
    }
    
    /// Update an existing context
    func update(
        context: SamContext,
        name: String? = nil,
        kind: ContextKind? = nil
    ) throws {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        if let name = name {
            context.name = name
        }
        
        if let kind = kind {
            context.kind = kind
        }
        
        let modelContext = ModelContext(container)
        try modelContext.save()
        
        print("📦 [ContextsRepository] Updated: \(context.name)")
    }
    
    /// Delete a context
    func delete(context: SamContext) throws {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let modelContext = ModelContext(container)
        modelContext.delete(context)
        try modelContext.save()
        
        print("📦 [ContextsRepository] Deleted: \(context.name)")
    }
    
    /// Search contexts by name
    func search(query: String) throws -> [SamContext] {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        guard !query.isEmpty else {
            return try fetchAll()
        }
        
        let context = ModelContext(container)
        
        // Fetch all and filter in memory
        let descriptor = FetchDescriptor<SamContext>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        
        let allContexts = try context.fetch(descriptor)
        let lowercaseQuery = query.lowercased()
        
        return allContexts.filter { ctx in
            ctx.name.lowercased().contains(lowercaseQuery)
        }
    }
    
    /// Filter contexts by kind
    func filter(by kind: ContextKind) throws -> [SamContext] {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        
        // Fetch all and filter in memory
        let descriptor = FetchDescriptor<SamContext>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        
        let allContexts = try context.fetch(descriptor)
        return allContexts.filter { $0.kind == kind }
    }
    
    /// Add a person to a context with a role
    func addParticipant(
        person: SamPerson,
        to context: SamContext,
        roleBadges: [String] = [],
        isPrimary: Bool = false,
        note: String? = nil
    ) throws {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        // Check if participation already exists
        let existingParticipation = context.participations.first { participation in
            participation.person?.id == person.id
        }
        
        if let existing = existingParticipation {
            // Update existing participation
            existing.roleBadges = roleBadges
            existing.isPrimary = isPrimary
            existing.note = note
            print("📦 [ContextsRepository] Updated participation: \(person.displayName) in \(context.name)")
        } else {
            // Create new participation
            let participation = ContextParticipation(
                id: UUID(),
                person: person,
                context: context,
                roleBadges: roleBadges,
                isPrimary: isPrimary,
                note: note
            )
            
            context.participations.append(participation)
            print("📦 [ContextsRepository] Added participant: \(person.displayName) to \(context.name)")
        }
        
        let modelContext = ModelContext(container)
        try modelContext.save()
    }
    
    /// Remove a person from a context
    func removeParticipant(person: SamPerson, from context: SamContext) throws {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        // Find and remove the participation
        if let participation = context.participations.first(where: { $0.person?.id == person.id }) {
            let modelContext = ModelContext(container)
            modelContext.delete(participation)
            try modelContext.save()
            
            print("📦 [ContextsRepository] Removed participant: \(person.displayName) from \(context.name)")
        }
    }
    
    /// Get count of all contexts
    func count() throws -> Int {
        guard let container = container else {
            throw RepositoryError.notConfigured
        }
        
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<SamContext>()
        return try context.fetchCount(descriptor)
    }
}
