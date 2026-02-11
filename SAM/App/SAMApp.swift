//
//  SAMApp.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//

import SwiftUI
import SwiftData
import Contacts
import EventKit

@main
struct SAMApp: App {
    
    // Check onboarding status immediately
    // Note: We need to use the full expression here, not just the boolean value
    // because @State needs to capture the initial value correctly
    @State private var showOnboarding: Bool
    @State private var hasCheckedPermissions = false
    
    // MARK: - Lifecycle
    
    init() {
        #if DEBUG
        // DEVELOPMENT ONLY: Uncomment the next line to force reset onboarding on every launch
        // UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        
        // Alternative: Use launch argument "-resetOnboarding YES" in your scheme
        if UserDefaults.standard.bool(forKey: "resetOnboarding") {
            print("🔄 [SAMApp] Launch argument detected - resetting onboarding")
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.set(false, forKey: "sam.contacts.enabled")
            UserDefaults.standard.set(false, forKey: "calendarAutoImportEnabled")
        }
        #endif
        
        // Initialize showOnboarding based on whether onboarding was completed
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        _showOnboarding = State(initialValue: !hasCompletedOnboarding)
        
        print("🚀 [SAMApp] Initializing...")
        print("🔍 [SAMApp] hasCompletedOnboarding = \(hasCompletedOnboarding)")
        print("🔍 [SAMApp] showOnboarding = \(!hasCompletedOnboarding)")
        
        // Configure repositories with shared container
        // Must happen before any data access
        configureDataLayer()
        
        print("✅ [SAMApp] Ready")
    }
    
    // MARK: - Scene
    
    var body: some Scene {
        WindowGroup {
            AppShellView()
                .modelContainer(SAMModelContainer.shared)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                        .interactiveDismissDisabled() // Prevent accidental dismissal
                        // Users can use "Skip" buttons for each step or "Quit" to exit entirely
                        // This ensures intentional choices rather than accidental dismissal
                        .onAppear {
                            print("✅ [SAMApp] Onboarding sheet appeared")
                        }
                        .onDisappear {
                            print("⚠️ [SAMApp] Onboarding sheet disappeared")
                            // When onboarding completes, trigger imports
                            Task {
                                await triggerImportsAfterOnboarding()
                            }
                        }
                }
                .onChange(of: showOnboarding) { oldValue, newValue in
                    print("🔄 [SAMApp] showOnboarding changed from \(oldValue) to \(newValue)")
                }
                .task {
                    // Check permissions ONCE on first launch
                    // This runs before user interaction, preventing the race condition
                    // where users could click on people before permissions are verified
                    guard !hasCheckedPermissions else { return }
                    print("🔧 [SAMApp] Running checkPermissionsAndSetup task...")
                    await checkPermissionsAndSetup()
                    hasCheckedPermissions = true
                }
        }
        .commands {
            CommandMenu("Debug") {
                Button("Reset Onboarding") {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    UserDefaults.standard.set(false, forKey: "sam.contacts.enabled")
                    UserDefaults.standard.set(false, forKey: "calendarAutoImportEnabled")
                    print("🔄 [Debug] Onboarding reset - restart the app to see onboarding")
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        
        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(SAMModelContainer.shared)
        }
        #endif
    }
    
    // MARK: - Configuration
    
    private func configureDataLayer() {
        // Wire repositories to the shared container
        // This ensures all SwiftData operations hit the same store
        PeopleRepository.shared.configure(container: SAMModelContainer.shared)
        EvidenceRepository.shared.configure(container: SAMModelContainer.shared)
        
        print("📊 [SAMApp] Data layer configured with container: \(Unmanaged.passUnretained(SAMModelContainer.shared).toOpaque())")
    }
    
    /// Check permissions and decide whether to show onboarding or proceed with imports
    /// This runs once at app launch, before user can interact with the UI
    private func checkPermissionsAndSetup() async {
        print("🔧 [SAMApp] Checking permissions and setup...")
        
        // Check if onboarding was completed
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        
        if !hasCompletedOnboarding {
            print("🔧 [SAMApp] Onboarding not complete - will show onboarding sheet")
            return
        }
        
        // Onboarding is marked complete - trigger imports
        await triggerImportsForEnabledSources()
    }
    
    /// Triggers imports after onboarding completes in the same session
    private func triggerImportsAfterOnboarding() async {
        print("🔧 [SAMApp] Onboarding dismissed - checking if we should trigger imports...")
        
        // Check if onboarding was actually completed (not just dismissed via Quit)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        
        if hasCompletedOnboarding {
            print("🔧 [SAMApp] Onboarding completed - triggering imports")
            await triggerImportsForEnabledSources()
        } else {
            print("🔧 [SAMApp] Onboarding dismissed without completion (user quit)")
        }
    }
    
    /// Shared function to trigger imports based on which sources are enabled
    private func triggerImportsForEnabledSources() async {
        print("🔧 [SAMApp] Checking which sources are enabled...")
        
        let contactsEnabled = UserDefaults.standard.bool(forKey: "sam.contacts.enabled")
        let calendarEnabled = UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled")
        
        print("🔧 [SAMApp] Contacts enabled: \(contactsEnabled), Calendar enabled: \(calendarEnabled)")
        
        // Kick import coordinators for enabled sources
        // This allows the app to work with partial permissions
        await MainActor.run {
            if contactsEnabled {
                print("🔧 [SAMApp] Triggering contacts import...")
                ContactsImportCoordinator.shared.kick(reason: "app launch")
            }
            
            if calendarEnabled {
                print("🔧 [SAMApp] Triggering calendar import...")
                CalendarImportCoordinator.shared.startAutoImport()
            }
            
            if !contactsEnabled && !calendarEnabled {
                print("ℹ️ [SAMApp] No sources enabled - app running in limited mode")
            }
        }
        
        print("✅ [SAMApp] Initial setup complete")
    }
}
