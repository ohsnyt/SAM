//
//
//  ContactSyncService.swift
//  SAM_crm
//
//  Manages synchronization between Apple Contacts and SAM's identity layer.
//  Apple Contacts is the system of record for identity data (names, family,
//  contact info). SAM stores only CNContact.identifier as anchor plus cached
//  display fields for list performance.
//
//  NOTES ENTITLEMENT STATUS:
//  ========================
//  Currently DISABLED - waiting for Apple to grant Notes access entitlement.
//
//  To enable Notes access once entitlement is granted:
//  1. Set `hasNotesEntitlement = true` (line ~28)
//  2. Uncomment `CNContactNoteKey` in `allContactKeys` array (line ~61)
//  3. Set `hasNotesEntitlement = true` in PersonDetailSections.swift (line ~442)
//  4. Add to your .entitlements file:
//     <key>com.apple.security.personal-information.contacts</key>
//     <true/>
//
//  Until then, all note operations will LOG to console instead of writing.
//

import Foundation
import SwiftData
import Contacts

public final class ContactSyncService: Observable {
    
    // MARK: - Singleton
    
    public static let shared = ContactSyncService()
    
    // Make store nonisolated since CNContactStore is thread-safe
    private let store: CNContactStore
    private var modelContext: ModelContext?
    
    /// Feature flag: Set to true once you have the Notes entitlement from Apple
    /// When false, note operations will be logged instead of executed
    private let hasNotesEntitlement = false
    
    private init() {
        self.store = ContactsImportCoordinator.contactStore
    }
    
    /// Configure with model context (call from App initialization)
    @MainActor
    public func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Fetch Contact Data
    
    /// All keys needed for rich person detail view
    /// Note: CNContactNoteKey removed until app receives Notes entitlement from Apple
    private static let allContactKeys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactNamePrefixKey as CNKeyDescriptor,
        CNContactNameSuffixKey as CNKeyDescriptor,
        CNContactPhoneticGivenNameKey as CNKeyDescriptor,
        CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactDatesKey as CNKeyDescriptor,
        CNContactRelationsKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactSocialProfilesKey as CNKeyDescriptor,
        CNContactInstantMessageAddressesKey as CNKeyDescriptor,
        // CNContactNoteKey as CNKeyDescriptor, // TODO: Uncomment when Notes entitlement is granted
        CNContactImageDataKey as CNKeyDescriptor,
        CNContactThumbnailImageDataKey as CNKeyDescriptor
    ]
    
    /// Returns the full CNContact for a SamPerson
    /// Returns nil if Contacts authorization not granted or contact not found
    public func contact(for person: SamPerson) throws -> CNContact? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return nil
        }
        
        guard let identifier = person.contactIdentifier, !identifier.isEmpty else {
            return nil
        }
        
        return try store.unifiedContact(
            withIdentifier: identifier,
            keysToFetch: Self.allContactKeys
        )
    }
    
    /// Fetch contact by identifier (for creating SamPerson from CNContact)
    public func contact(withIdentifier identifier: String) throws -> CNContact? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return nil
        }
        
        return try store.unifiedContact(
            withIdentifier: identifier,
            keysToFetch: Self.allContactKeys
        )
    }
    
    // MARK: - Write Contact Data
    
    /// Adds a relationship to the contact with the specified label
    /// Example: addRelationship(name: "William", label: CNLabelContactRelationSon, to: harveyPerson)
    /// Example: addRelationship(name: "Jane Doe", label: CNLabelContactRelationSpouse, to: harveyPerson)
    @MainActor
    public func addRelationship(name: String, label: String, to person: SamPerson) throws {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactSyncError.authorizationDenied
        }
        
        guard let contact = try contact(for: person) else {
            throw ContactSyncError.contactNotFound
        }
        
        let mutableContact = contact.mutableCopy() as! CNMutableContact
        
        let relation = CNLabeledValue(
            label: label,
            value: CNContactRelation(name: name)
        )
        
        var relations = mutableContact.contactRelations
        relations.append(relation)
        mutableContact.contactRelations = relations
        
        let saveRequest = CNSaveRequest()
        saveRequest.update(mutableContact)
        try store.execute(saveRequest)
        
        print("✅ [ContactSyncService] Added \(name) (\(label)) to \(person.displayNameCache ?? "contact")")
        
        // Refresh cache
        try refreshCache(for: person)
    }
    
    /// Adds a child relationship to the contact (convenience method)
    /// Example: addChild(name: "William", relationship: "son", to: harveyPerson)
    public func addChild(name: String, relationship: String? = nil, to person: SamPerson) throws {
        // Determine label based on relationship
        let label: String
        if let rel = relationship?.lowercased() {
            if rel.contains("son") && !rel.contains("step") {
                label = CNLabelContactRelationSon
            } else if rel.contains("daughter") && !rel.contains("step") {
                label = CNLabelContactRelationDaughter
            } else if rel.contains("step-son") || rel.contains("stepson") {
                label = "step-son"
            } else if rel.contains("step-daughter") || rel.contains("stepdaughter") {
                label = "step-daughter"
            } else {
                label = CNLabelContactRelationChild
            }
        } else {
            label = CNLabelContactRelationChild
        }
        
        try addRelationship(name: name, label: label, to: person)
    }
    
    /// Updates the summary note in Contacts (AI-suggested, user-approved)
    /// Appends to existing notes with separator
    /// NOTE: Currently logs only - requires Notes entitlement from Apple
    @MainActor
    public func updateSummaryNote(_ text: String, for person: SamPerson) throws {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactSyncError.authorizationDenied
        }
        
        guard let contact = try contact(for: person) else {
            throw ContactSyncError.contactNotFound
        }
        
        if hasNotesEntitlement {
            // TODO: Enable when Notes entitlement is granted
            let mutableContact = contact.mutableCopy() as! CNMutableContact
            
            // Append to existing notes (don't overwrite)
            let separator = contact.note.isEmpty ? "" : "\n\n---\n\n"
            mutableContact.note = contact.note + separator + text
            
            let saveRequest = CNSaveRequest()
            saveRequest.update(mutableContact)
            try store.execute(saveRequest)
            
            print("✅ [ContactSyncService] Updated summary note for \(person.displayNameCache ?? "contact")")
        } else {
            // Log what would be written (for development)
            print("📝 [ContactSyncService] WOULD UPDATE NOTE for \(person.displayNameCache ?? "contact"):")
            print("   Note content to add:")
            print("   ─────────────────────")
            print(text)
            print("   ─────────────────────")
            print("   ⚠️  Skipped: Notes entitlement not yet granted by Apple")
        }
    }
    
    /// Creates a new CNContact and returns its identifier
    /// Used when extracting people with contact information
    @MainActor
    public func createContact(
        givenName: String,
        familyName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        relationship: String? = nil,
        notes: String? = nil
    ) throws -> String {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactSyncError.authorizationDenied
        }
        
        let contact = CNMutableContact()
        contact.givenName = givenName
        if let familyName {
            contact.familyName = familyName
        }
        
        if let email {
            let emailValue = CNLabeledValue(
                label: CNLabelHome,
                value: email as NSString
            )
            contact.emailAddresses = [emailValue]
        }
        
        if let phone {
            let phoneValue = CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: phone)
            )
            contact.phoneNumbers = [phoneValue]
        }
        
        if let notes {
            if hasNotesEntitlement {
                // TODO: Enable when Notes entitlement is granted
                contact.note = notes
            } else {
                // Log what would be written
                print("📝 [ContactSyncService] WOULD SET NOTE for new contact: \(givenName) \(familyName ?? "")")
                print("   Note content:")
                print("   ─────────────────────")
                print(notes)
                print("   ─────────────────────")
                print("   ⚠️  Skipped: Notes entitlement not yet granted by Apple")
            }
        }
        
        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)
        try store.execute(saveRequest)
        
        print("✅ [ContactSyncService] Created contact: \(givenName) \(familyName ?? "")")
        
        return contact.identifier
    }
    
    // MARK: - Cache Management
    
    /// Refreshes cached display data from Contacts
    /// Call after any CNContact write operation
    @MainActor
    public func refreshCache(for person: SamPerson) throws {
        guard let contact = try contact(for: person) else {
            // Contact not found - mark as potentially deleted
            person.isArchived = false // Don't auto-archive, let user decide
            return
        }
        
        person.displayNameCache = CNContactFormatter.string(
            from: contact,
            style: .fullName
        ) ?? contact.givenName
        
        person.emailCache = contact.emailAddresses.first?.value as String?
        person.photoThumbnailCache = contact.thumbnailImageData
        person.lastSyncedAt = Date()
        
        try modelContext?.save()
        
        print("🔄 [ContactSyncService] Refreshed cache for \(person.displayNameCache ?? "contact")")
    }
    
    /// Bulk refresh for all people (run on app launch or Contacts change)
    @MainActor
    public func refreshAllCaches() async throws {
        guard let context = modelContext else { return }
        
        let people = try context.fetch(FetchDescriptor<SamPerson>())
        
        print("🔄 [ContactSyncService] Refreshing cache for \(people.count) people...")
        
        for person in people {
            try? refreshCache(for: person)
        }
        
        print("✅ [ContactSyncService] Cache refresh complete")
    }
    
    /// Check if a contact still exists (for orphaned contact detection)
    public func contactExists(identifier: String) -> Bool {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return false
        }
        
        do {
            _ = try store.unifiedContact(
                withIdentifier: identifier,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Errors

public enum ContactSyncError: LocalizedError {
    case authorizationDenied
    case contactNotFound
    case invalidData
    
    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Contacts access not authorized. Grant access in Settings."
        case .contactNotFound:
            return "Contact not found in Contacts.app."
        case .invalidData:
            return "Invalid contact data provided."
        }
    }
}

