//
//  ContactValidator.swift
//  SAM_crm
//
//  Utilities for validating that CNContact identifiers still point to
//  valid, accessible contacts in the system Contacts database.
//
//  Used to detect when a contact has been deleted or removed from the
//  SAM group, so the app can clear stale contactIdentifier values and
//  show the "Unlinked" badge again.
//

import Foundation
#if canImport(Contacts)
import Contacts
#endif

/// Stateless utility for checking contact validity and group membership.
enum ContactValidator {
    
    // MARK: - Debugging
    
    /// Returns detailed information about the Contacts authorization status
    /// and basic store access. Use this for debugging when validation isn't
    /// working as expected.
    static func diagnose() -> String {
        #if canImport(Contacts)
        let status = CNContactStore.authorizationStatus(for: .contacts)
        var output = "Contacts Authorization Status: "
        
        switch status {
        case .authorized:
            output += "✅ Authorized"
        case .denied:
            output += "❌ Denied"
        case .restricted:
            output += "⚠️ Restricted"
        case .notDetermined:
            output += "❓ Not Determined"
        @unknown default:
            output += "❔ Unknown (\(status.rawValue))"
        }
        
        // Try a basic store operation to confirm access works
        let store = CNContactStore()
        do {
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: "test"),
                keysToFetch: []
            )
            output += "\n✅ CNContactStore access works (test query returned \(contacts.count) results)"
        } catch {
            output += "\n❌ CNContactStore access failed: \(error.localizedDescription)"
        }
        
        return output
        #else
        return "❌ Contacts framework not available"
        #endif
    }
    
    // MARK: - Contact Existence
    
    /// Returns `true` if the contact identifier still points to a valid,
    /// accessible contact in the Contacts database.
    ///
    /// Returns `false` if:
    ///   • The contact has been deleted
    ///   • Contacts access has not been granted
    ///   • The identifier is malformed
    ///
    /// This is a synchronous CNContactStore lookup, so call it from a
    /// background task when checking multiple contacts.
    static func isValid(_ identifier: String) -> Bool {
        #if canImport(Contacts)
        // Note: On macOS, authorization status checking is less strict than iOS.
        // We'll attempt the lookup and let CNContactStore handle authorization
        // internally. If access is denied, the fetch will throw.
        let store = CNContactStore()
        do {
            // Provide a minimal valid keys array to reduce internal work and avoid issues with empty keys.
            // This also helps reduce the time a high-QoS caller might block on lower-QoS internal work.
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
            _ = try store.unifiedContact(
                withIdentifier: identifier,
                keysToFetch: keys
            )
            return true
        } catch let error as NSError {
            // Log the error in debug mode to help diagnose issues
            if ContactSyncConfiguration.enableDebugLogging {
                print("⚠️ ContactValidator.isValid(\(identifier)): \(error.localizedDescription)")
            }
            // Contact doesn't exist, was deleted, or can't be accessed.
            return false
        }
        #else
        return false
        #endif
    }
    
    /// Async convenience that validates on a background priority to avoid
    /// blocking User-initiated threads and potential QoS inversion.
    @discardableResult
    static func isValidAsync(_ identifier: String) async -> Bool {
        #if canImport(Contacts)
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "ContactValidator.Validation", qos: .utility)
            queue.async {
                let result = isValid(identifier)
                continuation.resume(returning: result)
            }
        }
        #else
        return false
        #endif
    }
    
    // MARK: - Group Membership
    
    /// Returns `true` if the contact is a member of the "SAM" group.
    ///
    /// Returns `false` if:
    ///   • The contact is not in the SAM group
    ///   • The SAM group doesn't exist
    ///   • The contact itself doesn't exist
    ///   • Contacts access has not been granted
    ///
    /// **Note:** Group membership checking is currently only supported on macOS.
    /// On iOS, groups are read-only and this will always return `false`.
    static func isInSAMGroup(_ identifier: String) -> Bool {
        #if canImport(Contacts) && os(macOS)
        // Remove the authorization guard - let CNContactStore handle it
        let store = CNContactStore()
        
        do {
            // 1. Find the SAM group by name.
            let allGroups = try store.groups(matching: nil)
            guard let samGroup = allGroups.first(where: { $0.name == "SAM" }) else {
                // No SAM group exists.
                if ContactSyncConfiguration.enableDebugLogging {
                    print("⚠️ ContactValidator.isInSAMGroup: SAM group not found")
                }
                return false
            }
            
            // 2. Fetch all contacts in the SAM group.
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: samGroup.identifier)
            let contactsInGroup = try store.unifiedContacts(
                matching: predicate,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
            )
            
            // 3. Check if our identifier is in the group.
            return contactsInGroup.contains { $0.identifier == identifier }
            
        } catch let error as NSError {
            if ContactSyncConfiguration.enableDebugLogging {
                print("⚠️ ContactValidator.isInSAMGroup(\(identifier)): \(error.localizedDescription)")
            }
            return false
        }
        #else
        // Groups are not fully supported on iOS; always return false.
        return false
        #endif
    }
    
    // MARK: - Combined Validation
    
    /// Validation result with granular failure reasons.
    enum ValidationResult {
        case valid
        case contactDeleted
        case notInSAMGroup
        case accessDenied
    }
    
    /// Perform a comprehensive validation of a contact identifier.
    ///
    /// Checks both existence and (on macOS) SAM group membership.
    /// Use this when you need to know *why* a link is invalid.
    static func validate(_ identifier: String, requireSAMGroup: Bool = false) -> ValidationResult {
        #if canImport(Contacts)
        // 1. Check existence first.
        guard isValid(identifier) else {
            return .contactDeleted
        }
        
        // 2. Optionally check group membership (macOS only).
        #if os(macOS)
        if requireSAMGroup && !isInSAMGroup(identifier) {
            return .notInSAMGroup
        }
        #endif
        
        return .valid
        #else
        return .accessDenied
        #endif
    }
}

