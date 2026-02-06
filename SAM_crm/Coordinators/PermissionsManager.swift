//
//  PermissionsManager.swift
//  SAM_crm
//
//  Created by David Snyder on 2/5/26.
//
//  Centralized permissions management for Calendar and Contacts access.
//  Provides a single source of truth for authorization status and ensures
//  permission requests only happen from Settings, not from background
//  coordinators.
//

import Foundation
import EventKit
import Contacts
import Combine

/// Notification posted whenever Calendar or Contacts authorization status changes.
/// Coordinators should listen for this and re-check their permissions.
extension Notification.Name {
    static let permissionsDidChange = Notification.Name("sam.permissions.didChange")
}

@MainActor
final class PermissionsManager: ObservableObject {
    
    static let shared = PermissionsManager()
    
    // MARK: - Published State
    
    /// Current Calendar authorization status.
    /// Observing this triggers UI updates in Settings.
    @Published private(set) var calendarStatus: EKAuthorizationStatus
    
    /// Current Contacts authorization status.
    /// Observing this triggers UI updates in Settings.
    @Published private(set) var contactsStatus: CNAuthorizationStatus
    
    // MARK: - Derived Properties
    
    /// Returns `true` if Calendar access is sufficient for reading events.
    /// Both `.fullAccess` and `.writeOnly` allow reading.
    var hasCalendarAccess: Bool {
        calendarStatus == .fullAccess || calendarStatus == .writeOnly
    }
    
    /// Returns `true` if Calendar access is full (read + write).
    /// Only `.fullAccess` allows reading existing events for import.
    var hasFullCalendarAccess: Bool {
        calendarStatus == .fullAccess
    }
    
    /// Returns `true` if Contacts access is granted.
    var hasContactsAccess: Bool {
        contactsStatus == .authorized
    }
    
    /// Returns `true` if both Calendar (full) and Contacts are authorized.
    /// Use this to check if the app can fully function.
    var hasAllRequiredPermissions: Bool {
        hasFullCalendarAccess && hasContactsAccess
    }
    
    // MARK: - Store References
    
    /// The shared EKEventStore. All parts of the app should use this instance.
    /// On macOS, the authorization cache is per-instance, so using a single
    /// shared instance ensures consistent state.
    let eventStore: EKEventStore
    
    /// The shared CNContactStore. All parts of the app should use this instance.
    /// CNContactStore maintains internal caches and change-history anchors;
    /// a singleton avoids registration races and stale state.
    let contactStore: CNContactStore
    
    // MARK: - Initialization
    
    private init() {
        // Initialize stores
        self.eventStore = EKEventStore()
        self.contactStore = CNContactStore()
        
        // Read initial authorization statuses
        self.calendarStatus = EKEventStore.authorizationStatus(for: .event)
        self.contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        
        // Observe system notifications for permission changes
        setupObservers()
    }
    
    // MARK: - Public API: Checking Permissions (No Dialogs)
    
    /// Refresh the current authorization statuses from the system.
    /// This does NOT trigger any permission dialogs — it only reads state.
    ///
    /// Call this after requesting permissions or when the app becomes active
    /// to ensure the cached state is current.
    func refreshStatus() {
        let oldCalendar = calendarStatus
        let oldContacts = contactsStatus
        
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        
        // Post notification if anything changed
        if oldCalendar != calendarStatus || oldContacts != contactsStatus {
            NotificationCenter.default.post(name: .permissionsDidChange, object: self)
        }
    }
    
    // MARK: - Public API: Requesting Permissions (UI-Initiated Only)
    
    /// Request full Calendar access.
    ///
    /// **Only call this from UI code** (e.g., Settings view), not from
    /// background coordinators. This will present a system permission dialog
    /// if permissions have not been determined yet.
    ///
    /// - Returns: `true` if full access was granted, `false` otherwise.
    @discardableResult
    func requestCalendarAccess() async -> Bool {
        do {
            // Request full access (includes read + write)
            let granted = try await eventStore.requestFullAccessToEvents()
            
            // Give the system a moment to commit the authorization state
            await Task.yield()
            
            // Refresh our cached status
            refreshStatus()
            
            return granted
        } catch {
            // Refresh status even on error (user may have denied)
            refreshStatus()
            return false
        }
    }
    
    /// Request Contacts access.
    ///
    /// **Only call this from UI code** (e.g., Settings view), not from
    /// background coordinators. This will present a system permission dialog
    /// if permissions have not been determined yet.
    ///
    /// - Returns: `true` if access was granted, `false` otherwise.
    @discardableResult
    func requestContactsAccess() async -> Bool {
        do {
            let granted = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                contactStore.requestAccess(for: .contacts) { granted, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: granted)
                    }
                }
            }
            
            // Give the system a moment to commit the authorization state
            await Task.yield()
            
            // Refresh our cached status
            refreshStatus()
            
            return granted
        } catch {
            // Refresh status even on error
            refreshStatus()
            return false
        }
    }
    
    /// Request both Calendar and Contacts access in sequence.
    ///
    /// **Only call this from UI code** (e.g., an onboarding flow or Settings).
    /// This will present two permission dialogs in sequence.
    ///
    /// - Returns: A tuple `(calendarGranted, contactsGranted)`.
    func requestAllPermissions() async -> (calendar: Bool, contacts: Bool) {
        let calendarGranted = await requestCalendarAccess()
        let contactsGranted = await requestContactsAccess()
        return (calendarGranted, contactsGranted)
    }
    
    // MARK: - Private: System Observers
    
    private func setupObservers() {
        // Listen for Calendar database changes (includes permission changes)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEventStoreChanged),
            name: .EKEventStoreChanged,
            object: nil
        )
        
        // Listen for Contacts database changes (includes permission changes)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContactsChanged),
            name: .CNContactStoreDidChange,
            object: nil
        )
    }
    
    @objc private func handleEventStoreChanged() {
        Task { @MainActor in
            refreshStatus()
        }
    }
    
    @objc private func handleContactsChanged() {
        Task { @MainActor in
            refreshStatus()
        }
    }
}

// MARK: - Convenience Extensions

extension PermissionsManager {
    /// A textual description of the Calendar authorization status.
    func calendarStatusText() -> String {
        switch calendarStatus {
        case .notDetermined: return "Not requested"
        case .restricted:    return "Restricted"
        case .denied:        return "Denied"
        case .fullAccess:    return "Granted (Full Access)"
        case .writeOnly:     return "Granted (Add Only)"
        @unknown default:    return "Unknown"
        }
    }
    
    /// A textual description of the Contacts authorization status.
    func contactsStatusText() -> String {
        switch contactsStatus {
        case .notDetermined: return "Not requested"
        case .restricted:    return "Restricted"
        case .denied:        return "Denied"
        case .authorized:    return "Granted"
        case .limited:       return "Limited"
        @unknown default:    return "Unknown"
        }
    }
}
