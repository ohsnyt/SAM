//
//  PeopleRepository.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//
//  SwiftData CRUD operations for SamPerson.
//  No direct CNContact access - receives DTOs from ContactsService.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class PeopleRepository {
    
    // MARK: - Singleton
    
    static let shared = PeopleRepository()
    
    // MARK: - Container
    
    private var container: ModelContainer?
    
    private init() {
        print("📦 [PeopleRepository] Initialized")
    }
    
    /// Configure the repository with the app-wide ModelContainer.
    /// Must be called once at app launch before any operations.
    func configure(container: ModelContainer) {
        self.container = container
        print("📦 [PeopleRepository] Configured with container: \(Unmanaged.passUnretained(container).toOpaque())")
    }
    
    // MARK: - CRUD Operations
    
    // TODO Phase C: Implement CRUD methods
    // - fetchAll() -> [SamPerson]
    // - fetch(id: UUID) -> SamPerson?
    // - upsert(contact: ContactDTO)
    // - delete(person: SamPerson)
    // - search(query: String) -> [SamPerson]
}
