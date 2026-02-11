//
//  EvidenceRepository.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Phase E: Calendar & Evidence (Completed February 10, 2026)
//
//  SwiftData CRUD operations for SamEvidenceItem.
//  No direct EKEvent access - receives DTOs from CalendarService.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class EvidenceRepository {
    
    // MARK: - Singleton
    
    static let shared = EvidenceRepository()
    
    // MARK: - Container
    
    private var container: ModelContainer?
    
    private var context: ModelContext? {
        guard let container = container else { return nil }
        return ModelContext(container)
    }
    
    private init() {
        print("📦 [EvidenceRepository] Initialized")
    }
    
    /// Configure the repository with the app-wide ModelContainer.
    /// Must be called once at app launch before any operations.
    func configure(container: ModelContainer) {
        self.container = container
        print("📦 [EvidenceRepository] Configured with container: \(Unmanaged.passUnretained(container).toOpaque())")
    }
    
    // MARK: - Fetch Operations
    
    /// Fetch all evidence items that need review.
    func fetchNeedsReview() throws -> [SamEvidenceItem] {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        let descriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        
        let allItems = try context.fetch(descriptor)
        return allItems.filter { $0.state == .needsReview }
    }
    
    /// Fetch all reviewed/done evidence items.
    func fetchDone() throws -> [SamEvidenceItem] {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        let descriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        
        let allItems = try context.fetch(descriptor)
        return allItems.filter { $0.state == .done }
    }
    
    /// Fetch all evidence items (all states).
    func fetchAll() throws -> [SamEvidenceItem] {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        let descriptor = FetchDescriptor<SamEvidenceItem>(
            sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
        )
        
        return try context.fetch(descriptor)
    }
    
    /// Fetch a single evidence item by ID.
    func fetch(id: UUID) throws -> SamEvidenceItem? {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        let descriptor = FetchDescriptor<SamEvidenceItem>()
        let allItems = try context.fetch(descriptor)
        return allItems.first { $0.id == id }
    }
    
    /// Fetch evidence item by sourceUID (for idempotent upsert).
    func fetch(sourceUID: String) throws -> SamEvidenceItem? {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        let descriptor = FetchDescriptor<SamEvidenceItem>()
        let allItems = try context.fetch(descriptor)
        return allItems.first { $0.sourceUID == sourceUID }
    }
    
    // MARK: - Create Operations

    /// Create or update an evidence item from any source (notes, manual, etc.).
    /// Uses sourceUID for idempotent upsert — if an item with the same sourceUID
    /// exists, it is updated; otherwise a new item is created.
    @discardableResult
    func create(
        sourceUID: String,
        source: EvidenceSource,
        occurredAt: Date,
        title: String,
        snippet: String,
        bodyText: String? = nil,
        linkedPeople: [SamPerson] = [],
        linkedContexts: [SamContext] = []
    ) throws -> SamEvidenceItem {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }

        // Idempotent: update if sourceUID already exists
        if let existing = try fetch(sourceUID: sourceUID) {
            existing.title = title
            existing.snippet = snippet
            existing.bodyText = bodyText
            existing.occurredAt = occurredAt
            existing.linkedPeople = linkedPeople
            existing.linkedContexts = linkedContexts
            try context.save()
            print("📦 [EvidenceRepository] Updated evidence: \(title)")
            return existing
        }

        let evidence = SamEvidenceItem(
            id: UUID(),
            state: .needsReview,
            sourceUID: sourceUID,
            source: source,
            occurredAt: occurredAt,
            title: title,
            snippet: snippet,
            bodyText: bodyText
        )
        evidence.linkedPeople = linkedPeople
        evidence.linkedContexts = linkedContexts

        context.insert(evidence)
        try context.save()

        print("📦 [EvidenceRepository] Created evidence: \(title)")
        return evidence
    }

    // MARK: - Upsert Operations

    /// Upsert evidence item from calendar event.
    /// Creates new item if sourceUID doesn't exist, updates if it does.
    func upsert(event: EventDTO) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        let sourceUID = event.sourceUID
        
        // Check if evidence already exists
        if let existing = try fetch(sourceUID: sourceUID) {
            // Update existing evidence
            existing.title = event.title
            existing.snippet = event.snippet
            existing.bodyText = event.notes
            existing.occurredAt = event.startDate
            
            print("📦 [EvidenceRepository] Updated evidence: \(event.title)")
        } else {
            // Create new evidence
            let evidence = SamEvidenceItem(
                id: UUID(),
                state: .needsReview,
                sourceUID: sourceUID,
                source: .calendar,
                occurredAt: event.startDate,
                title: event.title,
                snippet: event.snippet,
                bodyText: event.notes
            )
            
            context.insert(evidence)
            
            print("📦 [EvidenceRepository] Created evidence: \(event.title)")
        }
        
        try context.save()
    }
    
    /// Bulk upsert multiple events (more efficient than individual upserts).
    func bulkUpsert(events: [EventDTO]) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        var created = 0
        var updated = 0
        
        for event in events {
            let sourceUID = event.sourceUID
            
            if let existing = try fetch(sourceUID: sourceUID) {
                // Update existing
                existing.title = event.title
                existing.snippet = event.snippet
                existing.bodyText = event.notes
                existing.occurredAt = event.startDate
                updated += 1
            } else {
                // Create new
                let evidence = SamEvidenceItem(
                    id: UUID(),
                    state: .needsReview,
                    sourceUID: sourceUID,
                    source: .calendar,
                    occurredAt: event.startDate,
                    title: event.title,
                    snippet: event.snippet,
                    bodyText: event.notes
                )
                
                context.insert(evidence)
                created += 1
            }
        }
        
        try context.save()
        
        print("📦 [EvidenceRepository] Bulk upsert complete: \(created) created, \(updated) updated")
    }
    
    // MARK: - Update Operations
    
    /// Mark evidence item as reviewed/done.
    func markAsReviewed(item: SamEvidenceItem) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        item.state = .done
        
        try context.save()
        
        print("📦 [EvidenceRepository] Marked as reviewed: \(item.title)")
    }
    
    /// Mark evidence item as needs review.
    func markAsNeedsReview(item: SamEvidenceItem) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        item.state = .needsReview
        
        try context.save()
        
        print("📦 [EvidenceRepository] Marked as needs review: \(item.title)")
    }
    
    // MARK: - Delete Operations
    
    /// Delete a single evidence item.
    func delete(item: SamEvidenceItem) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        context.delete(item)
        
        try context.save()
        
        print("📦 [EvidenceRepository] Deleted evidence: \(item.title)")
    }
    
    /// Delete all evidence items (use with caution).
    func deleteAll() throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        let allItems = try fetchAll()
        
        for item in allItems {
            context.delete(item)
        }
        
        try context.save()
        
        print("📦 [EvidenceRepository] Deleted all evidence items: \(allItems.count)")
    }
    
    // MARK: - Pruning Operations
    
    /// Prune evidence items that no longer exist in calendar.
    /// Compares current evidence with provided sourceUIDs and deletes orphans.
    func pruneOrphans(validSourceUIDs: Set<String>) throws {
        guard let context = context else {
            throw RepositoryError.notConfigured
        }
        
        let allItems = try fetchAll()
        var deleted = 0
        
        for item in allItems {
            // Only prune calendar evidence (not user notes, etc.)
            guard item.source == .calendar else { continue }
            
            // If sourceUID doesn't exist in valid set, delete it
            if let sourceUID = item.sourceUID, !validSourceUIDs.contains(sourceUID) {
                context.delete(item)
                deleted += 1
            }
        }
        
        try context.save()
        
        print("📦 [EvidenceRepository] Pruned \(deleted) orphaned evidence items")
    }
    
    // MARK: - Error Types
    
    enum RepositoryError: Error, LocalizedError {
        case notConfigured
        
        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "EvidenceRepository not configured. Call configure(container:) first."
            }
        }
    }
}
