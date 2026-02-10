//
//  MeCardManager.swift
//  SAM_crm
//
//  Created by Assistant on 2/8/26.
//  Phase 1.3: Me Card identification and badge
//

import Foundation
import Observation
import Contacts

extension CNContactStore {
    func unifiedMeContact(withKeysToFetch keys: [CNKeyDescriptor]) throws -> CNContact? {
        try self.unifiedMeContactWithKeys(toFetch: keys)
    }
}
/// Manages the "Me" card - the user's own contact record.
///
/// The me card is the contact representing the SAM user (financial advisor).
/// It's distinguished with a special badge in the UI and may have special
/// treatment (e.g., suppressing "Last Contact" since the user is always in contact with themselves).
@MainActor
@Observable
final class MeCardManager {
    
    /// Singleton instance
    static let shared = MeCardManager()
    
    /// The contact identifier for the me card
    private(set) var meCardIdentifier: String?
    
    /// User defaults key for storing the me card identifier
    private let userDefaultsKey = "sam.meCard.contactIdentifier"
    
    private init() {
        // Load from UserDefaults
        self.meCardIdentifier = UserDefaults.standard.string(forKey: userDefaultsKey)
    }
    
    /// Checks if a given contact identifier is the me card
    func isMeCard(contactIdentifier: String?) -> Bool {
        guard let contactIdentifier = contactIdentifier,
              let meCardIdentifier = meCardIdentifier else {
            return false
        }
        return contactIdentifier == meCardIdentifier
    }
    
    /// Sets the me card identifier
    func setMeCard(contactIdentifier: String) {
        self.meCardIdentifier = contactIdentifier
        UserDefaults.standard.set(contactIdentifier, forKey: userDefaultsKey)
    }
    
    /// Clears the me card identifier
    func clearMeCard() {
        self.meCardIdentifier = nil
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
    
    /// Auto-detects the me card from Contacts.app (if available)
    func autoDetectMeCard() async {
        // Only auto-detect if not already set
        guard meCardIdentifier == nil else { 
            print("[MeCardManager] Me card already set, skipping auto-detection")
            return 
        }
        
        // Check authorization
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else {
            print("[MeCardManager] Contacts authorization not granted (\(status)), cannot auto-detect me card")
            return
        }
        
        // Use Contacts API to fetch the "me" card without escaping closures to avoid data races
        let store = CNContactStore()
        do {
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
            #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)
            // Prefer the dedicated API when available
            if store.responds(to: Selector(("unifiedMeContactWithKeysToFetch:"))) {
                // Call the Swift overlay when present
                let me = try store.unifiedMeContact(withKeysToFetch: keys)
                // unifiedMeContact may return nil if no Me card is set
                guard let me else {
                    print("[MeCardManager] No Me card found in Contacts")
                    return
                }
                let identifier = me.identifier
                print("[MeCardManager] ✅ Auto-detected me card: \(identifier)")
                self.setMeCard(contactIdentifier: identifier)
                return
            }
            #endif
            // Fallback: try to find a unified contact marked as Me via predicate (best-effort)
            // Note: There is no public predicate for Me specifically; if the above path isn't available,
            // we simply log and exit gracefully.
            print("[MeCardManager] No unifiedMeContact API available on this platform/runtime")
        } catch {
            print("[MeCardManager] Could not fetch me card: \(error)")
            print("[MeCardManager] Make sure 'My Card' is set in Contacts.app (Card → Make This My Card)")
        }
    }
}

// MARK: - SwiftUI Helpers

import SwiftUI

/// View modifier to badge a person as "Me"
struct MeCardBadge: View {
    var body: some View {
        Text("Me")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.15))
            .foregroundStyle(.blue)
            .cornerRadius(4)
    }
}

/// Extension to easily check if a person is the me card
extension SamPerson {
    nonisolated var isMeCard: Bool {
        guard let contactIdentifier = self.contactIdentifier,
              let meCardIdentifier = MainActor.assumeIsolated({ MeCardManager.shared.meCardIdentifier }) else {
            return false
        }
        return contactIdentifier == meCardIdentifier
    }
}

// MARK: - Preview

#Preview("Me Card Badge") {
    MeCardBadge()
        .padding()
}

