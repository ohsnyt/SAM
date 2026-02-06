//
//  ContactsImporter.swift
//  SAM_crm
//
//  Imports contacts from the SAM group (or all contacts) into SwiftData,
//  with deduplication to prevent creating duplicate SamPerson records.
//
//  Strategy:
//    1. Fetch contacts from Contacts.app
//    2. For each contact, check if a SamPerson already exists
//    3. If exists, update the contactIdentifier
//    4. If not exists, create new SamPerson
//    5. Return count of imported/updated contacts
//

import Foundation
import SwiftData
#if canImport(Contacts)
import Contacts
#endif

@MainActor
struct ContactsImporter {
    
    let modelContext: ModelContext
    
    // MARK: - Import from SAM Group
    
    /// Import contacts from the "SAM" group in Contacts.app.
    ///
    /// Returns a tuple of (imported, updated) counts.
    /// - imported: New SamPerson records created
    /// - updated: Existing SamPerson records that had their contactIdentifier set
    func importFromSAMGroup() async throws -> (imported: Int, updated: Int) {
        #if canImport(Contacts) && os(macOS)
        let store = CNContactStore()
        
        // 1. Find the SAM group
        let allGroups = try store.groups(matching: nil)
        guard let samGroup = allGroups.first(where: { $0.name == "SAM" }) else {
            throw ImportError.samGroupNotFound
        }
        
        // 2. Fetch all contacts in the SAM group
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: samGroup.identifier)
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        
        // 3. Upsert each contact
        return try await upsertContacts(contacts)
        #else
        throw ImportError.notSupported
        #endif
    }
    
    // MARK: - Import All Contacts
    
    /// Import all contacts from Contacts.app (not just SAM group).
    ///
    /// Returns a tuple of (imported, updated) counts.
    func importAllContacts() async throws -> (imported: Int, updated: Int) {
        #if canImport(Contacts)
        let store = CNContactStore()
        
        // Fetch all contacts
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var contacts: [CNContact] = []
        
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        
        // Upsert each contact
        return try await upsertContacts(contacts)
        #else
        throw ImportError.notSupported
        #endif
    }
    
    // MARK: - Upsert Logic
    
    /// Upsert contacts into SwiftData with deduplication.
    ///
    /// For each CNContact:
    ///   1. Check if SamPerson with same contactIdentifier exists → update it
    ///   2. Check if SamPerson with same canonical name exists → link it
    ///   3. Otherwise, create new SamPerson
    private func upsertContacts(_ contacts: [CNContact]) async throws -> (imported: Int, updated: Int) {
        var importedCount = 0
        var updatedCount = 0
        
        // Fetch all existing people for deduplication
        let existingPeople = try modelContext.fetch(FetchDescriptor<SamPerson>())
        
        for contact in contacts {
            let contactID = contact.identifier
            let fullName = formatName(contact)
            let email = contact.emailAddresses.first?.value as String?
            
            // 1. Check if person with this contactIdentifier already exists
            if existingPeople.contains(where: { $0.contactIdentifier == contactID }) {
                // Already linked - nothing to do
                continue
            }
            
            // 2. Check if person with this canonical name exists (but unlinked)
            let canonical = canonicalName(fullName)
            if let existing = existingPeople.first(where: {
                $0.contactIdentifier == nil && canonicalName($0.displayName) == canonical
            }) {
                // Found an unlinked person with matching name - link it
                existing.contactIdentifier = contactID
                if existing.email == nil, let email = email {
                    existing.email = email
                }
                updatedCount += 1
                continue
            }
            
            // 3. Check if person with this email exists (but unlinked)
            if let email = email,
               let existing = existingPeople.first(where: {
                   $0.contactIdentifier == nil && $0.email?.lowercased() == email.lowercased()
               }) {
                // Found an unlinked person with matching email - link it
                existing.contactIdentifier = contactID
                updatedCount += 1
                continue
            }
            
            // 4. No match found - create new person
            let newPerson = SamPerson(
                id: UUID(),
                displayName: fullName,
                roleBadges: [],
                contactIdentifier: contactID,
                email: email,
                consentAlertsCount: 0,
                reviewAlertsCount: 0
            )
            modelContext.insert(newPerson)
            importedCount += 1
        }
        
        // Save all changes
        if importedCount > 0 || updatedCount > 0 {
            try modelContext.save()
        }
        
        return (importedCount, updatedCount)
    }
    
    // MARK: - Helpers
    
    private func formatName(_ contact: CNContact) -> String {
        let parts = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
        
        return parts.isEmpty ? "Unknown" : parts.joined(separator: " ")
    }
    
    private func canonicalName(_ name: String) -> String {
        var result = name.lowercased()
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove punctuation
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        result = result.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce("") { $0 + String($1) }
        
        // Collapse multiple spaces
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return result
    }
    
    // MARK: - Errors
    
    enum ImportError: Error, LocalizedError {
        case samGroupNotFound
        case notSupported
        case permissionDenied
        
        var errorDescription: String? {
            switch self {
            case .samGroupNotFound:
                return "The 'SAM' group was not found in Contacts.app. Please create it first."
            case .notSupported:
                return "Contact import is not supported on this platform."
            case .permissionDenied:
                return "Contacts permission was denied. Please grant permission in System Settings."
            }
        }
    }
}

