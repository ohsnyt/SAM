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
            logger.debug("fetchContact contact: \(self.debugDescription(for: contact), privacy: .private)")
            return ContactDTO(from: contact)
        } catch {
            logger.error("Failed to fetch contact \(identifier, privacy: .private): \(error.localizedDescription)")
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
            logger.debug("contact: \(self.debugDescription(for: c), privacy: .private)")
        }
        
        logger.info("Fetched \(contacts.count) contacts")
        let results = contacts.map { ContactDTO(from: $0) }
        #if DEBUG
        for dto in results { if dto.emailAddresses.isEmpty { let name = dto.displayName; logger.debug("Contact has no emails: \(name, privacy: .private)") } }
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
                logger.debug("group contact: \(self.debugDescription(for: c), privacy: .private)")
            }
            
            logger.info("Fetched \(contacts.count) contacts from group '\(groupName)'")
            let results = contacts.map { ContactDTO(from: $0) }
            #if DEBUG
            for dto in results { if dto.emailAddresses.isEmpty { let name = dto.displayName; logger.debug("Contact has no emails: \(name, privacy: .private)") } }
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
                logger.debug("group(id) contact: \(self.debugDescription(for: c), privacy: .private)")
            }
            
            logger.info("Fetched \(contacts.count) contacts from group ID '\(groupIdentifier)'")
            let results = contacts.map { ContactDTO(from: $0) }
            #if DEBUG
            for dto in results { if dto.emailAddresses.isEmpty { let name = dto.displayName; logger.debug("Contact has no emails: \(name, privacy: .private)") } }
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
            logger.info("Fetched Me contact: \(self.debugDescription(for: me), privacy: .private)")
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
                logger.debug("search contact: \(self.debugDescription(for: c), privacy: .private)")
            }
            
            logger.info("Found \(contacts.count) contacts matching '\(query, privacy: .private)'")
            let results = contacts.map { ContactDTO(from: $0) }
            #if DEBUG
            for dto in results { if dto.emailAddresses.isEmpty { let name = dto.displayName; logger.debug("Contact has no emails: \(name, privacy: .private)") } }
            #endif
            return results
        } catch {
            logger.error("Failed to search contacts: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Search contacts by phone number.
    /// Uses CNContact.predicateForContacts(matching:) with a CNPhoneNumber.
    func searchContactsByPhone(phoneNumber: String, keys: ContactDTO.KeySet) async -> [ContactDTO] {
        guard authorizationStatus() == .authorized else { return [] }
        guard !phoneNumber.isEmpty else { return [] }

        let debugTrace = phoneNumber.contains("816")

        let cnPhone = CNPhoneNumber(stringValue: phoneNumber)
        let predicate = CNContact.predicateForContacts(matching: cnPhone)

        if debugTrace {
            logger.notice("[PhoneSearch] Searching for '\(phoneNumber, privacy: .public)' → CNPhoneNumber.stringValue='\(cnPhone.stringValue, privacy: .public)'")
        }

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys.keys)
            if debugTrace {
                for c in contacts {
                    let phones = c.phoneNumbers.map { "\($0.label ?? "?"): \($0.value.stringValue)" }
                    logger.notice("[PhoneSearch] Matched: '\(c.givenName, privacy: .public) \(c.familyName, privacy: .public)' id=\(c.identifier, privacy: .public) phones=\(phones, privacy: .public)")
                }
                if contacts.isEmpty {
                    logger.notice("[PhoneSearch] No matches for '\(phoneNumber, privacy: .public)' in any container")
                }
            }
            logger.info("Found \(contacts.count) contacts matching phone '\(phoneNumber, privacy: .private)'")
            return contacts.map { ContactDTO(from: $0) }
        } catch {
            logger.error("Failed to search contacts by phone '\(phoneNumber, privacy: .public)': \(error.localizedDescription)")
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
            logger.debug("Contact \(identifier, privacy: .private) validation failed: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Validate a batch of contact identifiers, returning the set that still exist in Apple Contacts.
    /// More efficient than calling isValidContact() one at a time.
    func validateIdentifiers(_ identifiers: [String]) async -> Set<String> {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to validate contacts without authorization")
            return []
        }

        var validSet = Set<String>()
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]

        for identifier in identifiers {
            do {
                _ = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
                validSet.insert(identifier)
            } catch {
                // Contact no longer exists
            }
        }

        return validSet
    }

    /// Returns the set of contact identifiers belonging to a specific group.
    /// Uses the group identifier (not name) for an efficient single fetch.
    /// Returns an empty set on error or if no contacts are in the group.
    func identifiersInGroup(withIdentifier groupIdentifier: String) async -> Set<String> {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to fetch group identifiers without authorization")
            return []
        }

        do {
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupIdentifier)
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            let ids = Set(contacts.map { $0.identifier })
            logger.info("Group '\(groupIdentifier)' contains \(ids.count) contact identifier(s)")
            return ids
        } catch {
            logger.error("Failed to fetch identifiers for group '\(groupIdentifier)': \(error.localizedDescription)")
            return []
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
    
    // MARK: - Container Discovery

    /// Returns the identifier of the iCloud container, or nil if none exists.
    /// iCloud containers use the `.cardDAV` type.
    func iCloudContainerIdentifier() -> String? {
        do {
            let containers = try store.containers(matching: nil)
            // iCloud containers are .cardDAV type. If multiple exist, prefer one
            // whose name contains "iCloud" or "Card" (Apple's default naming).
            let cardDAV = containers.filter { $0.type == .cardDAV }
            if let icloud = cardDAV.first {
                logger.debug("Found iCloud container: \(icloud.identifier, privacy: .private) (name: \(icloud.name, privacy: .public))")
                return icloud.identifier
            }
            logger.debug("No iCloud (CardDAV) container found among \(containers.count) containers")
            return nil
        } catch {
            logger.error("Failed to fetch containers: \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the container identifier where the current SAM group lives, or nil.
    func samGroupContainerIdentifier() -> String? {
        let groupID = UserDefaults.standard.string(forKey: "selectedContactGroupIdentifier") ?? ""
        guard !groupID.isEmpty else { return nil }
        let predicate = CNContainer.predicateForContainerOfGroup(withIdentifier: groupID)
        return try? store.containers(matching: predicate).first?.identifier
    }

    /// Whether the SAM group is in the iCloud container.
    func isSAMGroupInICloud() -> Bool {
        guard let groupContainer = samGroupContainerIdentifier(),
              let icloudContainer = iCloudContainerIdentifier() else { return false }
        return groupContainer == icloudContainer
    }

    /// Migrate the SAM group to iCloud: creates a new group in the iCloud container,
    /// moves all members, updates the stored group identifier, and deletes the old group.
    /// Returns the new group identifier on success, or nil on failure.
    func migrateSAMGroupToICloud() async -> String? {
        guard authorizationStatus() == .authorized else { return nil }

        let oldGroupID = UserDefaults.standard.string(forKey: "selectedContactGroupIdentifier") ?? ""
        guard !oldGroupID.isEmpty else {
            logger.warning("No SAM group configured, nothing to migrate")
            return nil
        }

        guard let icloudContainerID = iCloudContainerIdentifier() else {
            logger.warning("No iCloud container available for migration")
            return nil
        }

        // Check if already in iCloud
        if let currentContainer = samGroupContainerIdentifier(), currentContainer == icloudContainerID {
            logger.info("SAM group already in iCloud, no migration needed")
            return oldGroupID
        }

        do {
            // Fetch the old group to get its name
            let groups = try store.groups(matching: nil)
            guard let oldGroup = groups.first(where: { $0.identifier == oldGroupID }) else {
                logger.warning("Old SAM group not found")
                return nil
            }
            let groupName = oldGroup.name

            // Fetch current members of the old group with name keys for re-matching
            let memberKeys: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor
            ]
            let memberPredicate = CNContact.predicateForContactsInGroup(withIdentifier: oldGroupID)
            let members = try store.unifiedContacts(
                matching: memberPredicate,
                keysToFetch: memberKeys
            )

            // Create new group in iCloud container
            let newGroup = CNMutableGroup()
            newGroup.name = groupName

            let createRequest = CNSaveRequest()
            createRequest.add(newGroup, toContainerWithIdentifier: icloudContainerID)
            try store.execute(createRequest)

            let newGroupID = newGroup.identifier
            logger.info("Created new SAM group '\(groupName)' in iCloud container: \(newGroupID, privacy: .private)")

            // Pre-fetch all contacts in the iCloud container for matching
            let icloudPredicate = CNContact.predicateForContactsInContainer(withIdentifier: icloudContainerID)
            let icloudContacts = try store.unifiedContacts(
                matching: icloudPredicate,
                keysToFetch: memberKeys
            )
            // Build lookup by full name for fallback matching
            let icloudByName = Dictionary(
                icloudContacts.map { contact in
                    let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces).lowercased()
                    return (name, contact)
                },
                uniquingKeysWith: { first, _ in first }
            )
            let icloudIDs = Set(icloudContacts.map(\.identifier))

            // Add members to the new iCloud group
            var migratedCount = 0
            var skippedCount = 0
            for member in members {
                // Check if this unified contact is in the iCloud container
                let contactInICloud = icloudIDs.contains(member.identifier)

                let contactToAdd: CNContact
                if contactInICloud {
                    contactToAdd = member
                } else {
                    // Try to find the iCloud counterpart by name
                    let name = "\(member.givenName) \(member.familyName)".trimmingCharacters(in: .whitespaces).lowercased()
                    if let icloudMatch = icloudByName[name] {
                        contactToAdd = icloudMatch
                        logger.debug("Matched local contact '\(name, privacy: .private)' to iCloud counterpart")
                    } else {
                        logger.debug("Skipping member '\(name, privacy: .private)' — no iCloud counterpart found")
                        skippedCount += 1
                        continue
                    }
                }

                do {
                    let addRequest = CNSaveRequest()
                    addRequest.addMember(contactToAdd, to: newGroup)
                    try store.execute(addRequest)
                    migratedCount += 1
                } catch {
                    logger.debug("Failed to add member \(contactToAdd.identifier, privacy: .private) to new group: \(error.localizedDescription)")
                    skippedCount += 1
                }
            }

            // Only delete the old group if we migrated at least some members
            // (or it was empty to begin with)
            if migratedCount > 0 || members.isEmpty {
                let mutableOld = oldGroup.mutableCopy() as! CNMutableGroup
                let deleteRequest = CNSaveRequest()
                deleteRequest.delete(mutableOld)
                try store.execute(deleteRequest)
                logger.info("Deleted old SAM group")
            } else if skippedCount > 0 {
                logger.warning("Kept old SAM group — no members could be migrated to iCloud")
            }

            // Update the stored group identifier
            UserDefaults.standard.set(newGroupID, forKey: "selectedContactGroupIdentifier")

            logger.info("SAM group migration complete: \(migratedCount) migrated, \(skippedCount) skipped")
            return newGroupID

        } catch {
            logger.error("SAM group migration failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Cross-Container Contact Operations

    /// Copy a contact's data into a new contact in the iCloud container.
    /// Returns the new contact's DTO, or nil on failure.
    /// If `deleteOriginal` is true, the source contact is removed after copy (move).
    func copyContactToICloud(identifier: String, deleteOriginal: Bool) async -> ContactDTO? {
        guard authorizationStatus() == .authorized else { return nil }

        guard let icloudContainerID = iCloudContainerIdentifier() else {
            logger.warning("No iCloud container available for contact copy")
            return nil
        }

        do {
            // Fetch with all copyable keys (superset of ContactDTO.KeySet.detail)
            let copyKeys: [CNKeyDescriptor] = [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey,
                CNContactNamePrefixKey, CNContactNameSuffixKey, CNContactNicknameKey,
                CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
                CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
                CNContactBirthdayKey, CNContactDatesKey, CNContactImageDataKey,
                CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey,
                CNContactUrlAddressesKey, CNContactRelationsKey,
                CNContactIdentifierKey, CNContactThumbnailImageDataKey
            ] as [CNKeyDescriptor]
            let source = try store.unifiedContact(withIdentifier: identifier, keysToFetch: copyKeys)

            // Build a new mutable contact with all the same fields
            let copy = CNMutableContact()
            copy.namePrefix = source.namePrefix
            copy.givenName = source.givenName
            copy.middleName = source.middleName
            copy.familyName = source.familyName
            copy.nameSuffix = source.nameSuffix
            copy.nickname = source.nickname
            copy.organizationName = source.organizationName
            copy.departmentName = source.departmentName
            copy.jobTitle = source.jobTitle
            copy.phoneNumbers = source.phoneNumbers.map { CNLabeledValue(label: $0.label, value: $0.value) }
            copy.emailAddresses = source.emailAddresses.map { CNLabeledValue(label: $0.label, value: $0.value) }
            copy.postalAddresses = source.postalAddresses.map { CNLabeledValue(label: $0.label, value: $0.value) }
            copy.birthday = source.birthday
            copy.dates = source.dates.map { CNLabeledValue(label: $0.label, value: $0.value) }
            copy.socialProfiles = source.socialProfiles.map { CNLabeledValue(label: $0.label, value: $0.value) }
            copy.instantMessageAddresses = source.instantMessageAddresses.map { CNLabeledValue(label: $0.label, value: $0.value) }
            copy.urlAddresses = source.urlAddresses.map { CNLabeledValue(label: $0.label, value: $0.value) }
            copy.contactRelations = source.contactRelations.map { CNLabeledValue(label: $0.label, value: $0.value) }
            if let imageData = source.imageData {
                copy.imageData = imageData
            }

            // Save to iCloud container
            let saveRequest = CNSaveRequest()
            saveRequest.add(copy, toContainerWithIdentifier: icloudContainerID)
            try store.execute(saveRequest)

            logger.info("Copied contact to iCloud: \(source.givenName, privacy: .private) \(source.familyName, privacy: .private) (deleteOriginal: \(deleteOriginal))")

            // Add to SAM group
            addContactToSAMGroup(identifier: copy.identifier)

            // Delete original if requested (move)
            if deleteOriginal {
                // Re-fetch as mutable for deletion
                let originalKeys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
                let original = try store.unifiedContact(withIdentifier: identifier, keysToFetch: originalKeys)
                let mutableOriginal = original.mutableCopy() as! CNMutableContact
                let deleteRequest = CNSaveRequest()
                deleteRequest.delete(mutableOriginal)
                try store.execute(deleteRequest)
                logger.info("Deleted original contact after move: \(identifier, privacy: .private)")
            }

            // Return DTO for the new contact (use detail keys for the DTO)
            let dtoKeys = ContactDTO.KeySet.detail.keys
            let created = try store.unifiedContact(withIdentifier: copy.identifier, keysToFetch: dtoKeys)
            return ContactDTO(from: created)

        } catch {
            logger.error("Failed to copy contact to iCloud: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Write Operations

    /// Create a new contact group in the iCloud container (preferred) or default container.
    /// Returns true if successful.
    func createGroup(named name: String) async -> Bool {
        guard authorizationStatus() == .authorized else {
            logger.warning("Attempted to create group without authorization")
            return false
        }

        do {
            let newGroup = CNMutableGroup()
            newGroup.name = name

            // Prefer iCloud container so the group syncs across devices
            let containerID = iCloudContainerIdentifier()
            if containerID != nil {
                logger.info("Creating group '\(name)' in iCloud container")
            } else {
                logger.warning("No iCloud container found — creating group '\(name)' in default container")
            }

            let saveRequest = CNSaveRequest()
            saveRequest.add(newGroup, toContainerWithIdentifier: containerID)

            try store.execute(saveRequest)

            logger.info("Successfully created group '\(name)' (id: \(newGroup.identifier, privacy: .private))")
            return true
        } catch {
            logger.error("Failed to create group '\(name)': \(error.localizedDescription)")
            return false
        }
    }
    
    /// Create a new contact with minimal fields (name, email/phone, optional LinkedIn URL).
    /// The LinkedIn URL is stored as a social profile on the contact (visible in Contacts.app).
    /// Returns the created ContactDTO on success, or nil on failure.
    func createContact(fullName: String, email: String?, phone: String? = nil, note: String?, linkedInProfileURL: String? = nil, facebookProfileURL: String? = nil) async -> ContactDTO? {
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

            if let phone = phone, !phone.isEmpty {
                let labeled = CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))
                mutable.phoneNumbers = [labeled]
            }

            var socialProfiles: [CNLabeledValue<CNSocialProfile>] = []

            if let linkedInURL = linkedInProfileURL, !linkedInURL.isEmpty {
                let profile = CNSocialProfile(
                    urlString: linkedInURL.hasPrefix("http") ? linkedInURL : "https://\(linkedInURL)",
                    username: nil,
                    userIdentifier: nil,
                    service: CNSocialProfileServiceLinkedIn
                )
                socialProfiles.append(CNLabeledValue(label: CNLabelWork, value: profile))
            }

            if let facebookURL = facebookProfileURL, !facebookURL.isEmpty {
                let profile = CNSocialProfile(
                    urlString: facebookURL.hasPrefix("http") ? facebookURL : "https://\(facebookURL)",
                    username: nil,
                    userIdentifier: nil,
                    service: CNSocialProfileServiceFacebook
                )
                socialProfiles.append(CNLabeledValue(label: CNLabelHome, value: profile))
            }

            if !socialProfiles.isEmpty {
                mutable.socialProfiles = socialProfiles
            }

            // Notes field requires special entitlement; store placeholder comment in future
            // When entitlement is granted, uncomment the following line:
            // mutable.note = note ?? ""

            // Resolve the SAM group's container so the new contact is created in the same
            // container — required for addMember to succeed (contacts and groups must share a container).
            let groupID = UserDefaults.standard.string(forKey: "selectedContactGroupIdentifier") ?? ""
            let samContainerID: String? = groupID.isEmpty ? nil : {
                let predicate = CNContainer.predicateForContainerOfGroup(withIdentifier: groupID)
                return try? store.containers(matching: predicate).first?.identifier
            }()

            let save = CNSaveRequest()
            save.add(mutable, toContainerWithIdentifier: samContainerID)
            try store.execute(save)

            logger.info("Created contact: \(fullName, privacy: .private) in container: \(samContainerID ?? "default", privacy: .public)")

            // Auto-add to SAM group if configured
            addContactToSAMGroup(identifier: mutable.identifier)

            // Fetch detail keys so the DTO includes email addresses for matching
            let keys = ContactDTO.KeySet.detail.keys
            let created = try store.unifiedContact(withIdentifier: mutable.identifier, keysToFetch: keys)
            logger.debug("created contact: \(self.debugDescription(for: created), privacy: .private)")
            return ContactDTO(from: created)
        } catch {
            logger.error("Failed to create contact: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Contact Update (Enrichment Write-Back)

    /// Update an existing Apple Contact with approved enrichment fields.
    ///
    /// Field mapping:
    /// - `.company`    → organizationName
    /// - `.jobTitle`   → jobTitle
    /// - `.email`      → appended to emailAddresses (if not already present)
    /// - `.phone`      → appended to phoneNumbers (if not already present)
    /// - `.linkedInURL` → upsert CNSocialProfile for LinkedIn
    ///
    /// The SAM-managed note block (below `--- SAM ---`) is updated if `samNoteBlock` is provided
    /// and the Contacts Notes entitlement has been granted. All content above the delimiter is preserved.
    ///
    /// Returns true on success.
    func updateContact(
        identifier: String,
        updates: [EnrichmentField: String],
        samNoteBlock: String?
    ) async -> Bool {
        guard authorizationStatus() == .authorized else {
            logger.warning("updateContact: not authorized")
            return false
        }

        do {
            // Try with note key first (requires com.apple.developer.contacts.notes entitlement).
            // Fall back to without note key if the entitlement is not available.
            let baseKeys: [CNKeyDescriptor] = [
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactJobTitleKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactSocialProfilesKey as CNKeyDescriptor,
                CNContactInstantMessageAddressesKey as CNKeyDescriptor,
                CNContactRelationsKey as CNKeyDescriptor,
                CNContactDatesKey as CNKeyDescriptor,
            ]
            let keysWithNote: [CNKeyDescriptor] = baseKeys + [CNContactNoteKey as CNKeyDescriptor]

            let contact: CNContact
            let fetchedWithNote: Bool
            do {
                let fetched = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysWithNote)
                // The fetch can succeed even without the notes entitlement —
                // CNPropertyNotFetchedException (ObjC) is thrown at property
                // access time, not caught by Swift do/catch. Use isKeyAvailable
                // to verify the note is actually readable.
                if fetched.isKeyAvailable(CNContactNoteKey) {
                    contact = fetched
                    fetchedWithNote = true
                } else {
                    contact = fetched
                    fetchedWithNote = false
                    logger.warning("updateContact: note key fetched but not available (missing entitlement?)")
                }
            } catch {
                // Note entitlement may not be granted — fall back to base keys
                contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: baseKeys)
                fetchedWithNote = false
                logger.warning("updateContact: note key unavailable, skipping note update: \(error.localizedDescription)")
            }
            let mutable = contact.mutableCopy() as! CNMutableContact

            // Apply field updates
            for (field, value) in updates {
                switch field {
                case .company:
                    mutable.organizationName = value

                case .jobTitle:
                    mutable.jobTitle = value

                case .email:
                    let existing = mutable.emailAddresses.map { ($0.value as String).lowercased() }
                    if !existing.contains(value.lowercased()) {
                        let labeled = CNLabeledValue(label: CNLabelWork, value: NSString(string: value))
                        mutable.emailAddresses.append(labeled)
                    }

                case .phone:
                    let normalizedNew = value.filter(\.isNumber)
                    let existingNormalized = mutable.phoneNumbers.map {
                        $0.value.stringValue.filter(\.isNumber)
                    }
                    if !existingNormalized.contains(normalizedNew) {
                        let phone = CNPhoneNumber(stringValue: value)
                        let labeled = CNLabeledValue(label: CNLabelPhoneNumberMobile, value: phone)
                        mutable.phoneNumbers.append(labeled)
                    }

                case .linkedInURL:
                    let fullURL = value.hasPrefix("http") ? value : "https://\(value)"
                    // Remove existing LinkedIn social profiles, then add the updated one
                    mutable.socialProfiles = mutable.socialProfiles.filter {
                        $0.value.service != CNSocialProfileServiceLinkedIn
                    }
                    let profile = CNSocialProfile(
                        urlString: fullURL,
                        username: nil,
                        userIdentifier: nil,
                        service: CNSocialProfileServiceLinkedIn
                    )
                    mutable.socialProfiles.append(CNLabeledValue(label: CNLabelWork, value: profile))

                case .facebookURL:
                    let fullURL = value.hasPrefix("http") ? value : "https://\(value)"
                    // Remove existing Facebook social profiles, then add the updated one
                    mutable.socialProfiles = mutable.socialProfiles.filter {
                        $0.value.service != CNSocialProfileServiceFacebook
                    }
                    let fbProfile = CNSocialProfile(
                        urlString: fullURL,
                        username: nil,
                        userIdentifier: nil,
                        service: CNSocialProfileServiceFacebook
                    )
                    mutable.socialProfiles.append(CNLabeledValue(label: CNLabelHome, value: fbProfile))

                case .whatsApp:
                    let normalizedNew = value.filter(\.isNumber)
                    let existingNormalized = mutable.instantMessageAddresses.compactMap { labeled -> String? in
                        guard labeled.value.service == "WhatsApp" else { return nil }
                        return labeled.value.username.filter(\.isNumber)
                    }
                    if !existingNormalized.contains(normalizedNew) {
                        let im = CNInstantMessageAddress(username: value, service: "WhatsApp")
                        let labeled = CNLabeledValue(label: nil, value: im)
                        mutable.instantMessageAddresses.append(labeled)
                    }

                case .contactRelation:
                    let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { break }
                    let existingNames = mutable.contactRelations.map { $0.value.name.lowercased() }
                    guard !existingNames.contains(parts[1].lowercased()) else { break }
                    let cnLabel = Self.mapToCNRelationLabel(parts[0])
                    mutable.contactRelations.append(
                        CNLabeledValue(label: cnLabel, value: CNContactRelation(name: parts[1]))
                    )

                case .anniversary:
                    // Parse "YYYY-MM-DD" or "MM-DD" date string
                    let components = value.split(separator: "-").compactMap { Int($0) }
                    guard components.count >= 2 else { break }
                    var dc = DateComponents()
                    if components.count == 3 {
                        dc.year = components[0]
                        dc.month = components[1]
                        dc.day = components[2]
                    } else {
                        dc.month = components[0]
                        dc.day = components[1]
                    }
                    // Skip if an anniversary date already exists
                    let hasAnniversary = mutable.dates.contains { labeled in
                        labeled.label == CNLabelDateAnniversary
                    }
                    guard !hasAnniversary else { break }
                    let labeled = CNLabeledValue(label: CNLabelDateAnniversary, value: dc as NSDateComponents)
                    mutable.dates.append(labeled)
                }
            }

            // Update SAM note block if note key was fetched and block content provided
            if fetchedWithNote, let block = samNoteBlock {
                updateSAMNoteBlock(on: mutable, samBlock: block)
            }

            let saveRequest = CNSaveRequest()
            saveRequest.update(mutable)
            try store.execute(saveRequest)

            logger.info("Updated contact \(identifier, privacy: .private): \(updates.keys.map(\.rawValue).joined(separator: ", "), privacy: .public)")
            return true

        } catch {
            logger.error("updateContact failed for \(identifier, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - CN Relation Label Mapping

    /// Maps a human-readable relation label to the appropriate CNLabel constant.
    static func mapToCNRelationLabel(_ label: String) -> String {
        switch label.lowercased() {
        case "wife", "husband", "spouse", "partner":
            return CNLabelContactRelationSpouse
        case "mother", "mom":
            return CNLabelContactRelationMother
        case "father", "dad":
            return CNLabelContactRelationFather
        case "parent":
            return CNLabelContactRelationParent
        case "son":
            return CNLabelContactRelationSon
        case "daughter":
            return CNLabelContactRelationDaughter
        case "child":
            return CNLabelContactRelationChild
        case "brother":
            return CNLabelContactRelationBrother
        case "sister":
            return CNLabelContactRelationSister
        case "sibling":
            return "sibling"  // No built-in CNLabel for sibling
        default:
            return label  // Custom label
        }
    }

    // MARK: - SAM Note Block

    /// The delimiter that marks the start of SAM's managed section in a contact's note.
    /// Everything before this delimiter is the user's own content (preserved verbatim).
    /// Everything after is owned by SAM and regenerated on each write-back.
    static let samNoteDelimiter = "--- SAM ---"

    /// Updates the SAM-managed block in a mutable contact's note field.
    /// User content above the delimiter is never modified.
    private func updateSAMNoteBlock(on contact: CNMutableContact, samBlock: String) {
        let existing = contact.note
        let parts = existing.components(separatedBy: Self.samNoteDelimiter)
        let userNotes = (parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var combined = userNotes
        if !combined.isEmpty { combined += "\n\n" }
        combined += Self.samNoteDelimiter + "\n" + samBlock
        contact.note = combined
    }

    /// Check whether a contact is a member of the configured SAM group.
    /// Returns false if no SAM group is configured or on error.
    func isContactInSAMGroup(identifier: String) -> Bool {
        let groupID = UserDefaults.standard.string(forKey: "selectedContactGroupIdentifier") ?? ""
        guard !groupID.isEmpty else { return false }

        do {
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: groupID)
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
            let members = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            return members.contains { $0.identifier == identifier }
        } catch {
            logger.error("isContactInSAMGroup failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Result of attempting to add a contact to the SAM group.
    enum AddToGroupResult: Sendable {
        case added
        case alreadyMember
        case noGroupConfigured
        case containerMismatch
        case failed(String)
    }

    /// Add a contact to the configured SAM group in Apple Contacts.
    /// Called automatically when SAM creates a contact so it appears in future imports.
    @discardableResult
    func addContactToSAMGroup(identifier: String) -> AddToGroupResult {
        let groupID = UserDefaults.standard.string(forKey: "selectedContactGroupIdentifier") ?? ""
        guard !groupID.isEmpty else {
            logger.debug("No SAM group configured, skipping group assignment")
            return .noGroupConfigured
        }

        // Check if already a member first
        if isContactInSAMGroup(identifier: identifier) {
            logger.debug("Contact \(identifier, privacy: .private) already in SAM group")
            return .alreadyMember
        }

        do {
            // Fetch the group
            let groups = try store.groups(matching: nil)
            guard let samGroup = groups.first(where: { $0.identifier == groupID }) else {
                logger.warning("SAM group not found for identifier: \(groupID, privacy: .public)")
                return .failed("SAM group not found")
            }

            // Resolve the container the SAM group lives in
            let groupContainerPredicate = CNContainer.predicateForContainerOfGroup(withIdentifier: groupID)
            let groupContainer = try store.containers(matching: groupContainerPredicate).first

            // Fetch the contact
            let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
            let contacts = try store.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )
            guard let contact = contacts.first else {
                logger.warning("Contact not found for identifier: \(identifier, privacy: .private)")
                return .failed("Contact not found")
            }

            // Check if the contact is in the same container as the SAM group.
            // addMember requires contact and group share a container.
            if let groupContainerID = groupContainer?.identifier {
                let contactContainerPredicate = CNContainer.predicateForContainerOfContact(withIdentifier: identifier)
                let contactContainers = try store.containers(matching: contactContainerPredicate)
                let sameContainer = contactContainers.contains { $0.identifier == groupContainerID }
                if !sameContainer {
                    logger.warning("Contact is in a different container than SAM group — cannot add to group")
                    return .containerMismatch
                }
            }

            // Add to group
            let saveRequest = CNSaveRequest()
            saveRequest.addMember(contact, to: samGroup)
            try store.execute(saveRequest)

            logger.info("Added contact \(identifier, privacy: .private) to SAM group")
            return .added
        } catch {
            logger.warning("Failed to add contact to SAM group: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
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

