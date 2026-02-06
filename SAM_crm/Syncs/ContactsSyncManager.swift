//
//  ContactsSyncManager.swift
//  SAM_crm
//
//  Observes changes to the system Contacts database and validates all
//  linked SamPerson records, clearing stale contactIdentifier values
//  when a contact has been deleted or removed from the SAM group.
//
//  Lifecycle:
//    • Start observing when the app launches (via AppShellView or similar)
//    • Automatically validates on CNContactStoreDidChange notifications
//    • Stop observing on deinit (or app termination)
//
//  Thread-safety:
//    • @MainActor isolated so SwiftData context access is safe
//    • CNContactStore I/O happens on background threads via Task.detached
//

import Foundation
import SwiftData
#if canImport(Contacts)
import Contacts
#endif

@MainActor
@Observable
final class ContactsSyncManager {
    
    // MARK: - Configuration
    
    /// If `true`, contacts must be in the "SAM" group to remain linked.
    /// If `false`, only existence is checked (contact hasn't been deleted).
    ///
    /// **Note:** SAM group filtering only works on macOS.  On iOS, this
    /// is ignored and only existence is validated.
    ///
    /// You can override this per-instance, or set a default in
    /// `ContactSyncConfiguration.requireSAMGroupMembership`.
    var requireSAMGroupMembership: Bool = ContactSyncConfiguration.requireSAMGroupMembership
    
    // MARK: - State
    
    /// Number of stale links cleared during the last validation pass.
    /// Exposed so the UI can show a toast or notification when links
    /// are auto-unlinked.
    private(set) var lastClearedCount: Int = 0
    
    /// Set to `true` while a validation pass is in progress.
    private(set) var isValidating: Bool = false
    
    // MARK: - Private
    
    private var observer: NSObjectProtocol?
    private weak var modelContext: ModelContext?
    
    // MARK: - Lifecycle
    
    /// Initialize the manager.  Call `startObserving(modelContext:)` to
    /// begin monitoring Contacts changes.
    init() {}
    
    /// Begin observing CNContactStoreDidChange notifications.
    ///
    /// - Parameter modelContext: The SwiftData context to use for querying
    ///   and updating SamPerson records.
    func startObserving(modelContext: ModelContext) {
        self.modelContext = modelContext
        
        #if canImport(Contacts)
        // Register for Contacts database change notifications.
        observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.validateAllLinkedContacts()
            }
        }
        
        // Run an initial validation pass ONLY if we have Contacts permission.
        // If permission hasn't been granted yet, validation would incorrectly
        // mark all contacts as invalid.
        if ContactSyncConfiguration.validateOnAppLaunch {
            Task {
                // Check permission status before validating
                let status = CNContactStore.authorizationStatus(for: .contacts)
                
                if status == .authorized {
                    // Permission already granted (possibly by another part of the app)
                    // Always deduplicate first, then validate
                    if ContactSyncConfiguration.deduplicateOnEveryLaunch {
                        if ContactSyncConfiguration.enableDebugLogging {
                            print("📱 ContactsSyncManager: Checking for duplicates on launch...")
                        }
                        
                        do {
                            let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
                            let dedupeCount = try cleaner.cleanAllDuplicates()
                            
                            if dedupeCount > 0 {
                                if ContactSyncConfiguration.enableDebugLogging {
                                    print("📱 ContactsSyncManager: Merged \(dedupeCount) duplicate people on launch")
                                }
                            } else if ContactSyncConfiguration.enableDebugLogging {
                                print("✅ ContactsSyncManager: No duplicates found")
                            }
                        } catch {
                            if ContactSyncConfiguration.enableDebugLogging {
                                print("⚠️ ContactsSyncManager: Deduplication failed: \(error)")
                            }
                        }
                    }
                    
                    // Now safe to validate
                    await validateAllLinkedContacts()
                } else if status == .notDetermined {
                    // Permission not yet requested
                    // DON'T request here — let the main app permission flow handle it
                    // This prevents duplicate permission dialogs
                    if ContactSyncConfiguration.enableDebugLogging {
                        print("📱 ContactsSyncManager: Contacts permission not granted yet. Skipping validation.")
                        print("   Note: If your app requests Contacts permission elsewhere,")
                        print("   validation will run automatically when permission is granted.")
                    }
                    
                    // NOTE: If you want ContactsSyncManager to request permission itself,
                    // uncomment this block. But if your app has a combined Calendar+Contacts
                    // permission flow elsewhere, leave this commented to avoid duplicate dialogs.
                    
                    /*
                    do {
                        let store = CNContactStore()
                        _ = try await store.requestAccess(for: .contacts)
                        
                        // Permission flow complete - first deduplicate, then validate
                        if ContactSyncConfiguration.enableDebugLogging {
                            print("📱 ContactsSyncManager: Permission granted, checking for duplicates...")
                        }
                        
                        // Clean up any duplicates that may have been created
                        // when contacts were incorrectly marked as unlinked
                        if ContactSyncConfiguration.deduplicateAfterPermissionGrant {
                            let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
                            let dedupeCount = try? cleaner.cleanAllDuplicates()
                            
                            if let count = dedupeCount, count > 0 {
                                if ContactSyncConfiguration.enableDebugLogging {
                                    print("📱 ContactsSyncManager: Merged \(count) duplicate people")
                                }
                            }
                        }
                        
                        // Now validate with correct permissions
                        await validateAllLinkedContacts()
                    } catch {
                        if ContactSyncConfiguration.enableDebugLogging {
                            print("⚠️ ContactsSyncManager: Failed to request Contacts access: \(error)")
                        }
                    }
                    */
                } else {
                    // Permission denied/restricted - don't validate
                    if ContactSyncConfiguration.enableDebugLogging {
                        print("⚠️ ContactsSyncManager: Contacts access denied, skipping validation")
                    }
                }
            }
        }
        #else
        // Contacts framework not available; nothing to observe.
        #endif
    }
    
    /// Stop observing Contacts changes.
    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
    
    @MainActor
    deinit {
        #if canImport(Contacts)
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }
    
    // MARK: - Validation
    
    /// Validate all SamPerson records that have a `contactIdentifier`.
    ///
    /// For each linked person:
    ///   1. Check if the contact still exists in Contacts.app
    ///   2. (Optionally) Check if the contact is in the "SAM" group (macOS only)
    ///   3. If invalid, clear the `contactIdentifier` so the person shows
    ///      as "Unlinked" again.
    ///
    /// This runs on a background thread for CNContactStore I/O, then hops
    /// back to the main actor to update SwiftData.
    func validateAllLinkedContacts() async {
        guard let modelContext else { return }
        
        #if canImport(Contacts)
        // CRITICAL: Don't validate if we don't have Contacts permission.
        // This prevents incorrectly marking all contacts as invalid during
        // the first launch when permission is being requested.
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else {
            if ContactSyncConfiguration.enableDebugLogging {
                print("⚠️ ContactsSyncManager: Skipping validation - Contacts permission not granted (status: \(status.rawValue))")
            }
            return
        }
        #endif
        
        isValidating = true
        defer { isValidating = false }
        
        if ContactSyncConfiguration.enableDebugLogging {
            print("📱 ContactsSyncManager: Starting validation...")
            print(ContactValidator.diagnose())
        }
        
        // Fetch all people with a contactIdentifier.
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier != nil }
        )
        
        guard let linkedPeople = try? modelContext.fetch(descriptor) else {
            if ContactSyncConfiguration.enableDebugLogging {
                print("⚠️ ContactsSyncManager: Failed to fetch linked people from SwiftData")
            }
            return
        }
        
        // If no linked people, nothing to do.
        guard !linkedPeople.isEmpty else {
            lastClearedCount = 0
            if ContactSyncConfiguration.enableDebugLogging {
                print("📱 ContactsSyncManager: No linked people found")
            }
            return
        }
        
        if ContactSyncConfiguration.enableDebugLogging {
            print("📱 ContactsSyncManager: Found \(linkedPeople.count) linked people to validate")
        }
        
        // Build a list of (personID, contactIdentifier) pairs to validate.
        // We pull these out of the @Model objects so we can do the validation
        // work off the main actor without holding SwiftData objects.
        let validationTasks: [(UUID, String)] = linkedPeople.compactMap { person in
            guard let identifier = person.contactIdentifier else { return nil }
            return (person.id, identifier)
        }
        
        // Validate each contact on a background thread (CNContactStore I/O is synchronous).
        let results: [(UUID, Bool)] = await Task.detached(priority: .userInitiated) { [requireSAMGroupMembership] in
            // Capture debug flag in a local constant to avoid main-actor cross isolation in Swift 6
            let debugLoggingEnabled = ContactSyncConfiguration.enableDebugLogging

            return await withTaskGroup(of: (UUID, Bool).self, returning: [(UUID, Bool)].self) { group in
                for (personID, identifier) in validationTasks {
                    group.addTask {
                        let isValid: Bool

                        #if os(macOS)
                        if requireSAMGroupMembership {
                            let isValidOnMain: Bool = await MainActor.run {
                                let result = ContactValidator.validate(identifier, requireSAMGroup: true)
                                if ContactSyncConfiguration.enableDebugLogging {
                                    print("  • Contact \(identifier): \(result)")
                                }
                                switch result {
                                case .valid: return true
                                default: return false
                                }
                            }
                            isValid = isValidOnMain
                        } else {
                            // Just check existence.
                            isValid = await ContactValidator.isValid(identifier)

                            if debugLoggingEnabled {
                                print("  • Contact \(identifier): \(isValid ? "✅ valid" : "❌ invalid")")
                            }
                        }
                        #else
                        // On iOS, always just check existence (groups are not fully supported).
                        isValid = ContactValidator.isValid(identifier)

                        if debugLoggingEnabled {
                            print("  • Contact \(identifier): \(isValid ? "✅ valid" : "❌ invalid")")
                        }
                        #endif

                        return (personID, isValid)
                    }
                }

                var collected: [(UUID, Bool)] = []
                for await value in group { collected.append(value) }
                return collected
            }
        }.value
        
        // Back on the main actor: clear contactIdentifier for any invalid links.
        var clearedCount = 0
        
        for (personID, isValid) in results where !isValid {
            if let person = linkedPeople.first(where: { $0.id == personID }) {
                if ContactSyncConfiguration.dryRunMode {
                    // Dry run: log what would be cleared but don't actually clear
                    if ContactSyncConfiguration.enableDebugLogging {
                        print("  🔸 DRY RUN: Would clear link for \(person.displayName) (\(person.contactIdentifier ?? "nil"))")
                    }
                    clearedCount += 1
                } else {
                    // Normal mode: actually clear the link
                    person.contactIdentifier = nil
                    clearedCount += 1
                }
            }
        }
        
        lastClearedCount = clearedCount
        
        // Persist changes if we unlinked anyone (and not in dry-run mode)
        if clearedCount > 0 {
            if ContactSyncConfiguration.dryRunMode {
                if ContactSyncConfiguration.enableDebugLogging {
                    print("🔸 DRY RUN: Would clear \(clearedCount) stale contact link(s) (not saving)")
                }
            } else {
                if ContactSyncConfiguration.enableDebugLogging {
                    print("📱 ContactsSyncManager: Cleared \(clearedCount) stale contact link(s)")
                }
                
                do {
                    try modelContext.save()
                } catch {
                    // Log or surface the error (optional).
                    print("⚠️ ContactsSyncManager: Failed to save after clearing \(clearedCount) stale links: \(error)")
                }
            }
        } else if ContactSyncConfiguration.enableDebugLogging {
            print("✅ ContactsSyncManager: All \(results.count) contact link(s) are valid")
        }
    }
    
    // MARK: - Manual Validation (Single Contact)
    
    /// Validate a single person's contact link and clear it if invalid.
    ///
    /// Returns `true` if the link was cleared, `false` if it's still valid
    /// (or the person has no link).
    ///
    /// Use this when navigating to a person detail view or performing an
    /// action that relies on the contact link being current.
    @discardableResult
    func validatePerson(_ person: SamPerson) async -> Bool {
        guard let identifier = person.contactIdentifier else {
            // No link to validate.
            return false
        }
        
        // Validate on a background thread.
        let isValid = await Task.detached(priority: .userInitiated) { [requireSAMGroupMembership] in
            #if os(macOS)
            if requireSAMGroupMembership {
                let result = ContactValidator.validate(identifier, requireSAMGroup: true)
                return result == .valid
            } else {
                return ContactValidator.isValid(identifier)
            }
            #else
            return ContactValidator.isValid(identifier)
            #endif
        }.value
        
        if !isValid {
            person.contactIdentifier = nil
            if let context = modelContext {
                try? context.save()
            }
            return true  // Link was cleared.
        }
        
        return false  // Link is still valid.
    }
    
    // MARK: - Deduplication
    
    /// Manually trigger deduplication of SamPerson records.
    ///
    /// This finds and merges duplicate people that have:
    /// - Same contactIdentifier
    /// - Same canonical name
    ///
    /// Returns the number of duplicates merged.
    ///
    /// **Use case:** Run this manually if you see duplicate people after
    /// granting Contacts permission on first launch.
    @discardableResult
    func deduplicatePeople() throws -> Int {
        guard let modelContext else { return 0 }
        
        let cleaner = DuplicatePersonCleaner(modelContext: modelContext)
        let count = try cleaner.cleanAllDuplicates()
        
        if count > 0 && ContactSyncConfiguration.enableDebugLogging {
            print("📱 ContactsSyncManager: Manually deduplicated \(count) people")
        }
        
        return count
    }
}

