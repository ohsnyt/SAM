import SwiftUI
import Foundation
import Contacts

/// A simple app-storage backed settings object for managing the strategist's own email addresses.
/// Intended to be driven from the Settings UI.
public final class SelfIdentitySettings: ObservableObject {
    @AppStorage("sam.selfEmails") private var storedEmailsRaw: String = ""
    
    @Published public private(set) var selfEmails: [String] = []
    
    public init() {
        self.selfEmails = storedEmailsRaw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    /// Updates the stored self emails with normalization.
    /// - Parameter emails: The emails to store.
    public func updateSelfEmails(_ emails: [String]) {
        let normalizedEmails = MeIdentityManager.normalizeEmails(emails)
        selfEmails = normalizedEmails
        storedEmailsRaw = normalizedEmails.joined(separator: "\n")
    }
    
    /// Returns whether the given email is contained in the stored self emails.
    /// - Parameter email: The email to check.
    /// - Returns: True if the normalized email is in the stored list.
    public func contains(email: String) -> Bool {
        let normalized = MeIdentityManager.normalizeEmails([email])
        guard let normalizedEmail = normalized.first else { return false }
        return selfEmails.contains(normalizedEmail)
    }
    
    /// Refreshes self emails by fetching the "me" contact from the contact store.
    /// - Parameter store: The CNContactStore to use.
    /// - Throws: Throws any errors encountered while fetching contacts.
    public func refreshFromContacts(using store: CNContactStore) throws {
        let manager = MeIdentityManager(store: store)
        let fetchedEmails = try manager.fetchMeContact()
        updateSelfEmails(fetchedEmails)
    }
}

/// A helper managing normalization and fetching of "me" contact emails.
private struct MeIdentityManager {
    let store: CNContactStore?
    
    init(store: CNContactStore? = nil) {
        self.store = store
    }
    
    /// Normalizes emails by trimming whitespace and lowercasing.
    /// - Parameter emails: The emails to normalize.
    /// - Returns: Normalized emails.
    static func normalizeEmails(_ emails: [String]) -> [String] {
        emails.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
    }
    
    /// Fetches emails from the "me" contact in the contact store.
    /// - Throws: Throws if store is nil or fetching fails.
    /// - Returns: Emails found for the "me" contact.
    func fetchMeContact() throws -> [String] {
        guard let store = store else {
            throw NSError(domain: "MeIdentityManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "CNContactStore not provided"])
        }
        let keysToFetch = [CNContactEmailAddressesKey as CNKeyDescriptor]
        let mePredicate = CNContact.predicateForContactsMatchingName("me")
        let meContact = try store.unifiedContacts(matching: mePredicate, keysToFetch: keysToFetch).first
        
        if let contact = meContact {
            return contact.emailAddresses.map { $0.value as String }
        } else {
            return []
        }
    }
}
