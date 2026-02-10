import SwiftUI
import Foundation
import Contacts
import Combine

/// A simple app-storage backed settings object for managing the strategist's own email addresses.
/// Intended to be driven from the Settings UI.
public final class F: ObservableObject {
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
        let meInfo = try manager.fetchMeContact()
        updateSelfEmails(meInfo.emails)
    }
}

