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
    
    // MARK: - Debug Helpers
    /// Formats a CNContact's salient fields for detailed logging
    private func debugDescription(for contact: CNContact) -> String {
        let identifier = contact.identifier
        // Names and org are commonly fetched in our KeySets, but still guard by availability
        let given: String = contact.isKeyAvailable(CNContactGivenNameKey) ? contact.givenName : "<unfetched>"
        let family: String = contact.isKeyAvailable(CNContactFamilyNameKey) ? contact.familyName : "<unfetched>"
        let org: String = contact.isKeyAvailable(CNContactOrganizationNameKey) ? contact.organizationName : "<unfetched>"

        let emails: String = {
            let key = CNContactEmailAddressesKey
            guard contact.isKeyAvailable(key) else { return "<unfetched>" }
            return contact.emailAddresses.map { labeled in
                let label = CNLabeledValue<NSString>.localizedString(forLabel: labeled.label ?? "")
                return "\(label): \(labeled.value as String)"
            }.joined(separator: ", ")
        }()

        let phones: String = {
            let key = CNContactPhoneNumbersKey
            guard contact.isKeyAvailable(key) else { return "<unfetched>" }
            return contact.phoneNumbers.map { labeled in
                let label = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: labeled.label ?? "")
                return "\(label): \(labeled.value.stringValue)"
            }.joined(separator: ", ")
        }()

        let displayName: String
        if given != "<unfetched>" || family != "<unfetched>" {
            let combined = [given == "<unfetched>" ? "" : given,
                            family == "<unfetched>" ? "" : family]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            displayName = combined.isEmpty ? org : combined
        } else {
            displayName = org
        }

        return "id=\(identifier) name=\(displayName) emails=[\(emails)] phones=[\(phones)]"
    }

    /// Formats the keys requested for fetches to verify email keys are included
    private func debugKeysDescription(_ keys: [CNKeyDescriptor]) -> String {
        // Swift 6: Avoid bridging/casting across existential CNKeyDescriptor
        // Use descriptive fallback so logs remain useful across OS versions
        return keys.map { String(describing: $0) }.joined(separator: ", ")
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
            logger.debug("fetchContact keys: \(self.debugKeysDescription(keys.keys), privacy: .public)")
            logger.debug("fetchContact contact: \(self.debugDescription(for: contact), privacy: .public)")
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
        
        logger.debug("fetchContacts keys: \(self.debugKeysDescription(keys.keys), privacy: .public)")
        
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
        
        for c in contacts {
            logger.debug("contact: \(self.debugDescription(for: c), privacy: .public)")
        }
        
        logger.info("Fetched \(contacts.count) contacts")
        let results = contacts.map { ContactDTO(from: $0) }
        #if DEBUG
        for dto in results { if dto.emailAddresses.isEmpty { logger.debug("Contact has no emails: \(dto.displayName, privacy: .public)") } }
        #endif
        return results
    }
    
    /// Fetch contacts from a specific group
    func fetchContacts(inGroupNamed groupName: String, keys: ContactDTO.KeySet) async -> [ContactDTO] {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch contacts without authorization")
            return []
        }
        
        logger.debug("fetchContacts(inGroupNamed:) keys: \(self.debugKeysDescription(keys.keys), privacy: .public)")
        
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
            
            for c in contacts {
                logger.debug("group contact: \(self.debugDescription(for: c), privacy: .public)")
            }
            
            logger.info("Fetched \(contacts.count) contacts from group '\(groupName)'")
            let results = contacts.map { ContactDTO(from: $0) }
            #if DEBUG
            for dto in results { if dto.emailAddresses.isEmpty { logger.debug("Contact has no emails: \(dto.displayName, privacy: .public)") } }
            #endif
            return results
            
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
        
        logger.debug("fetchContacts(inGroupWithIdentifier:) keys: \(self.debugKeysDescription(keys.keys), privacy: .public)")
        
        do {
            // Fetch contacts in group
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupIdentifier)
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys.keys)
            
            for c in contacts {
                logger.debug("group(id) contact: \(self.debugDescription(for: c), privacy: .public)")
            }
            
            logger.info("Fetched \(contacts.count) contacts from group ID '\(groupIdentifier)'")
            let results = contacts.map { ContactDTO(from: $0) }
            #if DEBUG
            for dto in results { if dto.emailAddresses.isEmpty { logger.debug("Contact has no emails: \(dto.displayName, privacy: .public)") } }
            #endif
            return results
            
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
    
    /// Fetch the user's "Me" contact card via CNContactStore.
    func fetchMeContact(keys: ContactDTO.KeySet) async -> ContactDTO? {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch me contact without authorization")
            return nil
        }

        do {
            let me = try store.unifiedMeContactWithKeys(toFetch: keys.keys)
            logger.info("Fetched Me contact: \(self.debugDescription(for: me), privacy: .public)")
            return ContactDTO(from: me)
        } catch {
            logger.info("No Me card configured: \(error.localizedDescription)")
            return nil
        }
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
        
        logger.debug("searchContacts keys: \(self.debugKeysDescription(keys.keys), privacy: .public)")
        
        let predicate = CNContact.predicateForContacts(matchingName: query)
        
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys.keys)
            
            for c in contacts {
                logger.debug("search contact: \(self.debugDescription(for: c), privacy: .public)")
            }
            
            logger.info("Found \(contacts.count) contacts matching '\(query)'")
            let results = contacts.map { ContactDTO(from: $0) }
            #if DEBUG
            for dto in results { if dto.emailAddresses.isEmpty { logger.debug("Contact has no emails: \(dto.displayName, privacy: .public)") } }
            #endif
            return results
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
    
    /// Create a new contact with minimal fields (name, email). Optionally include a note (stored when entitlement available).
    /// Returns the created ContactDTO on success, or nil on failure.
    func createContact(fullName: String, email: String?, note: String?) async -> ContactDTO? {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to create contact without authorization")
            return nil
        }

        do {
            let mutable = CNMutableContact()

            // Split full name into given/family heuristically (last token as family name)
            let parts = fullName.split(separator: " ")
            if parts.count >= 2 {
                mutable.givenName = parts.dropLast().joined(separator: " ")
                mutable.familyName = String(parts.last!)
            } else {
                mutable.givenName = fullName
            }

            if let email = email, !email.isEmpty {
                let labeled = CNLabeledValue(label: CNLabelWork, value: NSString(string: email))
                mutable.emailAddresses = [labeled]
            }

            // Notes field requires special entitlement; store placeholder comment in future
            // When entitlement is granted, uncomment the following line:
            // mutable.note = note ?? ""

            let save = CNSaveRequest()
            save.add(mutable, toContainerWithIdentifier: nil)
            try store.execute(save)

            logger.info("Created contact: \(fullName, privacy: .public)")

            // Fetch detail keys so the DTO includes email addresses for matching
            let keys = ContactDTO.KeySet.detail.keys
            let created = try store.unifiedContact(withIdentifier: mutable.identifier, keysToFetch: keys)
            logger.debug("created contact: \(self.debugDescription(for: created), privacy: .public)")
            return ContactDTO(from: created)
        } catch {
            logger.error("Failed to create contact: \(error.localizedDescription, privacy: .public)")
            return nil
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

