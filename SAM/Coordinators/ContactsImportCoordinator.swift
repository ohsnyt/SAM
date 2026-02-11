//
//  ContactsImportCoordinator.swift
//  SAM_crm
//
//  Created on February 9, 2026.
//  Phase C: Data Layer - Clean rebuild
//
//  Orchestrates contact import from Apple Contacts into SwiftData.
//  Uses ContactsService for API access, PeopleRepository for storage.
//  This is the ONLY place that coordinates contact import.
//

import Foundation
import SwiftUI
import Contacts
import os.log

/// Coordinates importing contacts from Apple Contacts into SwiftData
/// 
/// Architecture:
/// - Reads from ContactsService (never creates CNContactStore)
/// - Writes to PeopleRepository (never touches SwiftData directly)
/// - Debounces import triggers to avoid redundant work
@MainActor
@Observable
final class ContactsImportCoordinator {
    
    // MARK: - Singleton
    
    static let shared = ContactsImportCoordinator()
    
    // MARK: - Dependencies
    
    private let contactsService = ContactsService.shared
    private let peopleRepo = PeopleRepository.shared
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContactsImportCoordinator")
    
    // MARK: - Settings (User-Configurable, persisted to UserDefaults)
    
    @ObservationIgnored
    var importEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "sam.contacts.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.contacts.enabled") }
    }
    
    @ObservationIgnored
    var selectedGroupIdentifier: String {
        get { UserDefaults.standard.string(forKey: "selectedContactGroupIdentifier") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedContactGroupIdentifier") }
    }
    
    @ObservationIgnored
    private var lastRunAt: Double {
        get { UserDefaults.standard.double(forKey: "sam.contacts.import.lastRunAt") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.contacts.import.lastRunAt") }
    }
    
    // MARK: - State
    
    private(set) var isImporting = false
    private(set) var lastImportResult: ImportResult?
    
    // MARK: - Debouncing
    
    private var debounceTask: Task<Void, Never>?
    private let minimumIntervalNormal: TimeInterval = 300      // 5 minutes for periodic triggers
    private let minimumIntervalChanged: TimeInterval = 10      // 10 seconds for change notifications
    
    // MARK: - Initialization
    
    private init() {
        logger.info("ContactsImportCoordinator initialized")
        setupObservers()
    }
    
    // MARK: - Public API
    
    /// Trigger an import if conditions are met (debounced)
    /// Call this from app lifecycle events or notification handlers
    func kick(reason: String) {
        logger.debug("Import kicked: \(reason)")
        
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            await importIfNeeded(reason: reason)
        }
    }
    
    /// Force an immediate import (bypasses throttling)
    /// Use this for user-initiated actions like tapping "Import Now" button
    func importNow() async {
        logger.info("Manual import triggered")
        await performImport()
    }
    
    /// Fetch available contact groups for selection UI
    func fetchAvailableGroups() async -> [ContactGroupDTO] {
        logger.debug("Fetching available groups")
        return await contactsService.fetchGroups()
    }
    
    // MARK: - Private Implementation
    
    /// Check conditions and import if needed
    private func importIfNeeded(reason: String) async {
        // Check if import is enabled
        guard importEnabled else {
            logger.debug("Import disabled by user setting")
            return
        }
        
        // Check if group is selected
        guard !selectedGroupIdentifier.isEmpty else {
            logger.debug("No group selected for import")
            return
        }
        
        // Check authorization
        guard await contactsService.authorizationStatus() == .authorized else {
            logger.warning("No contacts access - cannot import")
            return
        }
        
        // Check throttling
        let now = Date().timeIntervalSince1970
        let isPeriodicTrigger = reason == "app launch" || reason == "app became active"
        let minInterval = isPeriodicTrigger ? minimumIntervalNormal : minimumIntervalChanged
        let elapsed = now - lastRunAt
        
        guard elapsed > minInterval else {
            logger.debug("Import throttled: \(Int(elapsed))s elapsed, need \(Int(minInterval))s")
            return
        }
        
        // All conditions met - perform import
        await performImport()
    }
    
    /// Perform the actual import operation
    private func performImport() async {
        guard !isImporting else {
            logger.warning("Import already in progress")
            return
        }
        
        isImporting = true
        defer { isImporting = false }
        
        let startTime = Date()
        logger.info("Starting import from group ID '\(self.selectedGroupIdentifier)'")
        
        do {
            // Fetch contacts from ContactsService
            let contacts = await contactsService.fetchContacts(
                inGroupWithIdentifier: self.selectedGroupIdentifier,
                keys: .minimal  // Just need identifier, name, email, thumbnail
            )
            
            guard !contacts.isEmpty else {
                logger.warning("No contacts found in group ID '\(self.selectedGroupIdentifier)'")
                lastImportResult = ImportResult(
                    success: true,
                    created: 0,
                    updated: 0,
                    errors: 0,
                    duration: Date().timeIntervalSince(startTime)
                )
                return
            }
            
            logger.info("Fetched \(contacts.count) contacts from ContactsService")
            
            // Upsert into PeopleRepository
            let (created, updated) = try peopleRepo.bulkUpsert(contacts: contacts)
            
            // Update last run timestamp
            lastRunAt = Date().timeIntervalSince1970
            
            // Store result
            let duration = Date().timeIntervalSince(startTime)
            lastImportResult = ImportResult(
                success: true,
                created: created,
                updated: updated,
                errors: 0,
                duration: duration
            )
            
            logger.info("Import complete: \(created) created, \(updated) updated in \(String(format: "%.2f", duration))s")
            
            // Trigger insight generation (Phase H)
            Task {
                // await InsightGenerator.shared.generateInsights()
                logger.debug("TODO: Trigger insight generation")
            }
            
        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            
            lastImportResult = ImportResult(
                success: false,
                created: 0,
                updated: 0,
                errors: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }
    }
    
    // MARK: - Observers
    
    private func setupObservers() {
        // Observe contacts store changes
        Task {
            for await _ in NotificationCenter.default.notifications(named: .CNContactStoreDidChange) {
                logger.debug("Contacts store changed notification received")
                kick(reason: "contacts changed")
            }
        }
    }
    
    /// Kick import on app startup (for convenience)
    static func kickOnStartup() {
        Task { @MainActor in
            shared.kick(reason: "app launch")
        }
    }
}

// MARK: - Supporting Types

/// Result of an import operation
struct ImportResult: Sendable {
    let success: Bool
    let created: Int
    let updated: Int
    let errors: Int
    let duration: TimeInterval
    
    var totalProcessed: Int {
        created + updated
    }
    
    var summary: String {
        if success {
            return "\(created) created, \(updated) updated in \(String(format: "%.1f", duration))s"
        } else {
            return "Failed with \(errors) error(s)"
        }
    }
}
