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

    private(set) var importStatus: ImportStatus = .idle
    private(set) var lastImportedAt: Date?
    private(set) var lastImportCount: Int = 0
    private(set) var lastError: String?

    /// Global flag for other coordinators to check if contacts import is running
    static var isImportingContacts: Bool {
        ContactsImportCoordinator.shared.importStatus == .importing
    }

    enum ImportStatus: Equatable {
        case idle, importing, success, failed
        var displayText: String {
            switch self {
            case .idle: "Ready"
            case .importing: "Importing..."
            case .success: "Synced"
            case .failed: "Failed"
            }
        }
    }
    
    // MARK: - Debouncing
    
    private var debounceTask: Task<Void, Never>?
    private let minimumIntervalNormal: TimeInterval = 300      // 5 minutes for periodic triggers
    private let minimumIntervalChanged: TimeInterval = 10      // 10 seconds for change notifications
    
    // MARK: - Initialization
    
    private init() {
        logger.info("ContactsImportCoordinator initialized")
        setupObservers()
        
        // Attempt an immediate import if conditions are already satisfied at init
        Task { [weak self] in
            await self?.importIfConditionsMet(reason: "coordinator init")
        }
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
    
    /// Attempt import when both permission is granted and a group is selected
    func attemptImportAfterConfigChange(reason: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            // small debounce to coalesce rapid changes
            try? await Task.sleep(for: .milliseconds(400))
            await importIfConditionsMet(reason: reason)
        }
    }
    
    // MARK: - Private Implementation
    
    /// Import immediately if user has granted permission and selected a group
    private func importIfConditionsMet(reason: String) async {
        guard importEnabled else { return }
        guard !selectedGroupIdentifier.isEmpty else { return }
        guard await contactsService.authorizationStatus() == .authorized else { return }
        await performImport()
    }
    
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
        guard importStatus != .importing else {
            logger.warning("Import already in progress")
            return
        }

        importStatus = .importing
        lastError = nil

        let startTime = Date()
        logger.info("Starting import from group ID '\(self.selectedGroupIdentifier)'")

        do {
            // Fetch contacts from ContactsService
            let contacts = await contactsService.fetchContacts(
                inGroupWithIdentifier: self.selectedGroupIdentifier,
                keys: .detail  // includes emailAddresses
            )

            guard !contacts.isEmpty else {
                logger.warning("No contacts found in group ID '\(self.selectedGroupIdentifier)'")
                importStatus = .success
                lastImportedAt = Date()
                lastImportCount = 0
                return
            }

            logger.info("Fetched \(contacts.count) contacts from ContactsService")

            // Upsert into PeopleRepository
            let (created, updated) = try peopleRepo.bulkUpsert(contacts: contacts)

            // Import the Me contact (even if not in the SAM group)
            if let meContact = await contactsService.fetchMeContact(keys: .detail) {
                try peopleRepo.upsertMe(contact: meContact)
            }

            // Detect and clear stale contactIdentifiers (deleted Apple Contacts)
            let allPeopleWithContacts = try peopleRepo.fetchAll().compactMap { $0.contactIdentifier }
            if !allPeopleWithContacts.isEmpty {
                let validIDs = await contactsService.validateIdentifiers(allPeopleWithContacts)
                let cleared = try peopleRepo.clearStaleContactIdentifiers(validIdentifiers: validIDs)
                if cleared > 0 {
                    logger.info("Cleared \(cleared) stale contact identifier(s)")
                }
            }

            // Update last run timestamp
            lastRunAt = Date().timeIntervalSince1970

            importStatus = .success
            lastImportedAt = Date()
            lastImportCount = created + updated

            // After importing contacts, re-run participant resolution on existing evidence
            do {
                try EvidenceRepository.shared.reresolveParticipantsForUnlinkedEvidence()
            } catch {
                logger.error("Failed to re-resolve participants after contacts import: \(error.localizedDescription)")
            }

            let duration = Date().timeIntervalSince(startTime)
            logger.info("Import complete: \(created) created, \(updated) updated in \(String(format: "%.2f", duration))s")

            // Trigger insight generation (Phase H)
            Task {
                // await InsightGenerator.shared.generateInsights()
                logger.debug("TODO: Trigger insight generation")
            }

        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            importStatus = .failed
            lastError = error.localizedDescription
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
    
    // MARK: - Settings Change Hooks

    /// Call when the selected contact group changes (e.g., from Settings/Onboarding)
    func selectedGroupDidChange() {
        attemptImportAfterConfigChange(reason: "group selected")
    }

    /// Call when contacts permission has just been granted
    func permissionGranted() {
        attemptImportAfterConfigChange(reason: "permission granted")
    }
}


