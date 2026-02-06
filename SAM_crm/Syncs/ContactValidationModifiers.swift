//
//  ContactValidationModifiers.swift
//  SAM_crm
//
//  SwiftUI view modifiers for easily adding contact validation to any view.
//  These are convenience helpers that wrap ContactsSyncManager functionality.
//

import SwiftUI
import SwiftData

// MARK: - View Extension

extension View {
    
    /// Automatically validate a person's contact link when this view appears.
    ///
    /// If the contact is invalid (deleted or removed from SAM group), the
    /// `contactIdentifier` is cleared and the view is refreshed.
    ///
    /// **Example:**
    /// ```swift
    /// PersonDetailView(person: person)
    ///     .validateContactOnAppear(person: person, modelContext: modelContext)
    /// ```
    ///
    /// - Parameters:
    ///   - person: The SamPerson to validate
    ///   - modelContext: SwiftData context for saving changes
    /// - Returns: The modified view
    func validateContactOnAppear(person: SamPerson, modelContext: ModelContext) -> some View {
        self.modifier(ValidateContactOnAppearModifier(person: person, modelContext: modelContext))
    }
    
    /// Monitor Contacts changes and show a banner when stale links are cleared.
    ///
    /// This is typically applied to the root People list or main app shell.
    ///
    /// **Example:**
    /// ```swift
    /// PeopleListView()
    ///     .monitorContactChanges(modelContext: modelContext)
    /// ```
    ///
    /// - Parameter modelContext: SwiftData context for saving changes
    /// - Returns: The modified view with contact monitoring enabled
    func monitorContactChanges(modelContext: ModelContext) -> some View {
        self.modifier(MonitorContactChangesModifier(modelContext: modelContext))
    }
}

// MARK: - Modifiers

/// Validates a single person's contact link when the view appears.
private struct ValidateContactOnAppearModifier: ViewModifier {
    let person: SamPerson
    let modelContext: ModelContext
    
    @State private var syncManager = ContactsSyncManager()
    
    func body(content: Content) -> some View {
        content
            .task(id: person.id) {
                // Temporarily connect the sync manager to the context.
                syncManager.startObserving(modelContext: modelContext)
                
                // Validate this specific person.
                let wasCleared = await syncManager.validatePerson(person)
                
                if wasCleared && ContactSyncConfiguration.enableDebugLogging {
                    print("📱 Contact validation: Cleared stale link for \(person.displayName)")
                }
                
                // Stop observing (we only care about this one person in this context).
                syncManager.stopObserving()
            }
    }
}

/// Monitors Contacts changes and shows a banner when links are cleared.
private struct MonitorContactChangesModifier: ViewModifier {
    let modelContext: ModelContext
    
    @State private var syncManager = ContactsSyncManager()
    @State private var showBanner = false
    
    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            
            if showBanner && syncManager.lastClearedCount > 0 {
                ContactSyncStatusView(
                    clearedCount: syncManager.lastClearedCount,
                    onDismiss: { showBanner = false }
                )
                .padding(.top, 8)
                .zIndex(100)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: showBanner)
        .task {
            syncManager.startObserving(modelContext: modelContext)
        }
        .onChange(of: syncManager.lastClearedCount) { oldValue, newValue in
            if newValue > 0 && oldValue != newValue {
                showBanner = true
                
                Task {
                    try? await Task.sleep(for: .seconds(ContactSyncConfiguration.bannerAutoDismissDelay))
                    showBanner = false
                }
            }
        }
        .onDisappear {
            syncManager.stopObserving()
        }
    }
}

// MARK: - Standalone Helper Functions

extension ContactsSyncManager {
    
    /// Convenience initializer that immediately starts observing with the given context.
    ///
    /// **Example:**
    /// ```swift
    /// @State private var syncManager: ContactsSyncManager?
    ///
    /// .onAppear {
    ///     syncManager = ContactsSyncManager.start(modelContext: modelContext)
    /// }
    /// ```
    @MainActor
    static func start(modelContext: ModelContext) -> ContactsSyncManager {
        let manager = ContactsSyncManager()
        manager.startObserving(modelContext: modelContext)
        return manager
    }
}
