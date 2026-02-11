//
//  ContactsService.swift
//  SAM
//
//  Created on February 9, 2026.
//  Phase B: Services Layer - All CNContact operations go through here
//

import Foundation
import Contacts
import os.log

/// Actor-based service for all Contacts framework operations
/// This is the ONLY place in the codebase that creates/uses CNContactStore
///
/// Phase B: Clean architecture - Services own their external API access
actor ContactsService {
    
    // MARK: - Singleton
    
    static let shared = ContactsService()
    
    // MARK: - Properties
    
    /// Shared CNContactStore instance (singleton pattern required on macOS)
    /// This is the single source of truth for Contacts access in the app
    private let store: CNContactStore
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContactsService")
    
    // MARK: - Initialization
    
    private init() {
        self.store = CNContactStore()
        logger.info("ContactsService initialized with dedicated CNContactStore")
    }
    
    // MARK: - Authorization
    
    /// Check current authorization status
    func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }
    
    /// Request authorization if needed
    func requestAccess() async -> Bool {
        let status = authorizationStatus()
        
        switch status {
        case .authorized:
            logger.info("Contacts access already authorized")
            return true
            
        case .notDetermined:
            logger.info("Requesting contacts access...")
            do {
                let granted = try await store.requestAccess(for: .contacts)
                logger.info("Contacts access \(granted ? "granted" : "denied")")
                return granted
            } catch {
                logger.error("Failed to request contacts access: \(error.localizedDescription)")
                return false
            }
            
        case .denied, .restricted:
            logger.warning("Contacts access denied or restricted")
            return false
            
        @unknown default:
            logger.warning("Unknown contacts authorization status")
            return false
        }
    }
    
    /// Alias for requestAccess() to match CalendarService naming
    func requestAuthorization() async -> Bool {
        await requestAccess()
    }
    
    // MARK: - Fetch Operations
    
    /// Fetch a single contact by identifier
    func fetchContact(identifier: String, keys: ContactDTO.KeySet) async -> ContactDTO? {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch contact without authorization")
            return nil
        }
        
        do {
            let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys.keys)
            return ContactDTO(from: contact)
        } catch {
            logger.error("Failed to fetch contact \(identifier): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Fetch all contacts matching a predicate
    func fetchContacts(
        matching predicate: NSPredicate? = nil,
        keys: ContactDTO.KeySet
    ) async -> [ContactDTO] {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch contacts without authorization")
            return []
        }
        
        var contacts: [CNContact] = []
        let fetchRequest = CNContactFetchRequest(keysToFetch: keys.keys)
        
        if let predicate = predicate {
            // Use predicate-based fetch if available
            do {
                let containers = try store.containers(matching: predicate)
                for container in containers {
                    let containerPredicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
                    let containerContacts = try store.unifiedContacts(matching: containerPredicate, keysToFetch: keys.keys)
                    contacts.append(contentsOf: containerContacts)
                }
            } catch {
                logger.error("Failed to fetch contacts with predicate: \(error.localizedDescription)")
                return []
            }
        } else {
            // Enumerate all contacts
            do {
                try store.enumerateContacts(with: fetchRequest) { contact, stop in
                    contacts.append(contact)
                }
            } catch {
                logger.error("Failed to enumerate contacts: \(error.localizedDescription)")
                return []
            }
        }
        
        logger.info("Fetched \(contacts.count) contacts")
        return contacts.map { ContactDTO(from: $0) }
    }
    
    /// Fetch contacts from a specific group
    func fetchContacts(inGroupNamed groupName: String, keys: ContactDTO.KeySet) async -> [ContactDTO] {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch contacts without authorization")
            return []
        }
        
        do {
            // Find the group
            let groups = try store.groups(matching: nil)
            guard let targetGroup = groups.first(where: { $0.name == groupName }) else {
                logger.warning("Group '\(groupName)' not found")
                return []
            }
            
            // Fetch contacts in group
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: targetGroup.identifier)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys.keys)
            
            logger.info("Fetched \(contacts.count) contacts from group '\(groupName)'")
            return contacts.map { ContactDTO(from: $0) }
            
        } catch {
            logger.error("Failed to fetch contacts from group '\(groupName)': \(error.localizedDescription)")
            return []
        }
    }
    
    /// Fetch contacts from a specific group by identifier
    func fetchContacts(inGroupWithIdentifier groupIdentifier: String, keys: ContactDTO.KeySet) async -> [ContactDTO] {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch contacts without authorization")
            return []
        }
        
        do {
            // Fetch contacts in group
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupIdentifier)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys.keys)
            
            logger.info("Fetched \(contacts.count) contacts from group ID '\(groupIdentifier)'")
            return contacts.map { ContactDTO(from: $0) }
            
        } catch {
            logger.error("Failed to fetch contacts from group ID '\(groupIdentifier)': \(error.localizedDescription)")
            return []
        }
    }
    
    /// Fetch all available groups
    func fetchGroups() async -> [ContactGroupDTO] {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch groups without authorization")
            return []
        }
        
        do {
            let groups = try store.groups(matching: nil)
            return groups.map { group in
                ContactGroupDTO(
                    identifier: group.identifier,
                    name: group.name
                )
            }
        } catch {
            logger.error("Failed to fetch groups: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Get the "me" contact (requires MeCardManager to be configured by user)
    /// Note: macOS Contacts framework does not provide a direct "me" contact API.
    /// This method should be integrated with MeCardManager once that dependency is available.
    func fetchMeContact(keys: ContactDTO.KeySet) async -> ContactDTO? {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch me contact without authorization")
            return nil
        }
        
        // TODO: Integrate with MeCardManager.shared.meContactIdentifier when available
        // For now, this method is not functional on macOS
        logger.info("fetchMeContact called - requires MeCardManager integration")
        return nil
    }
    
    // MARK: - Search Operations
    
    /// Search contacts by name
    func searchContacts(query: String, keys: ContactDTO.KeySet) async -> [ContactDTO] {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to search contacts without authorization")
            return []
        }
        
        guard !query.isEmpty else {
            return []
        }
        
        let predicate = CNContact.predicateForContacts(matchingName: query)
        
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys.keys)
            logger.info("Found \(contacts.count) contacts matching '\(query)'")
            return contacts.map { ContactDTO(from: $0) }
        } catch {
            logger.error("Failed to search contacts: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Validation Operations
    
    /// Check if a contact identifier is still valid (contact exists and is accessible)
    /// Returns false if the contact was deleted or is no longer accessible
    func isValidContact(identifier: String) async -> Bool {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to validate contact without authorization")
            return false
        }
        
        do {
            // Try to fetch the contact with minimal keys
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
            _ = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
            return true
        } catch {
            // Contact not found or access error
            logger.debug("Contact \(identifier) validation failed: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Check if a contact is in a specific group
    func isContactInGroup(identifier: String, groupName: String) async -> Bool {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to check group membership without authorization")
            return false
        }
        
        do {
            // Find the group
            let groups = try store.groups(matching: nil)
            guard let targetGroup = groups.first(where: { $0.name == groupName }) else {
                logger.warning("Group '\(groupName)' not found")
                return false
            }
            
            // Check if contact is in group
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: targetGroup.identifier)
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            
            return contacts.contains { $0.identifier == identifier }
        } catch {
            logger.error("Failed to check group membership: \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Write Operations
    
    /// Create a new contact group
    /// Returns true if successful
    func createGroup(named name: String) async -> Bool {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to create group without authorization")
            return false
        }
        
        do {
            let newGroup = CNMutableGroup()
            newGroup.name = name
            
            let saveRequest = CNSaveRequest()
            saveRequest.add(newGroup, toContainerWithIdentifier: nil)
            
            try store.execute(saveRequest)
            
            logger.info("Successfully created group '\(name)'")
            return true
        } catch {
            logger.error("Failed to create group '\(name)': \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Supporting Types

/// Sendable wrapper for CNGroup
struct ContactGroupDTO: Sendable, Identifiable {
    let id: String
    let identifier: String
    let name: String
    
    /// nonisolated: Can be called from any actor context (including ContactsService actor)
    nonisolated init(identifier: String, name: String) {
        self.id = identifier
        self.identifier = identifier
        self.name = name
    }
}
