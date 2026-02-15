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
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SAMApp")

@main
struct SAMApp: App {
    
    // Check onboarding status immediately
    @State private var showOnboarding: Bool
    @State private var hasCheckedPermissions = false
    
    // MARK: - Lifecycle
    
    init() {
        // Initialize showOnboarding FIRST before any other operations
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        _showOnboarding = State(initialValue: !hasCompletedOnboarding)
        
        #if DEBUG
        // DEVELOPMENT ONLY: Uncomment the next line to force reset onboarding on every launch
        // UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        
        // Alternative: Use launch argument "-resetOnboarding YES" in your scheme
        if UserDefaults.standard.bool(forKey: "resetOnboarding") {
            logger.notice("Launch argument detected — resetting onboarding")
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.set(false, forKey: "sam.contacts.enabled")
            UserDefaults.standard.set(false, forKey: "calendarAutoImportEnabled")
        }
        #endif
        
        // Configure repositories with shared container
        // Must happen before any data access
        configureDataLayer()
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
                        .onDisappear {
                            // When onboarding completes, trigger imports
                            Task {
                                await triggerImportsAfterOnboarding()
                            }
                        }
                }
                .task {
                    // Check permissions ONCE on first launch
                    // This runs before user interaction, preventing the race condition
                    // where users could click on people before permissions are verified
                    guard !hasCheckedPermissions else { return }
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
                    UserDefaults.standard.set(false, forKey: "mailImportEnabled")
                    logger.notice("Onboarding reset via Debug menu — terminating")
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
        ContextsRepository.shared.configure(container: SAMModelContainer.shared)
        NotesRepository.shared.configure(container: SAMModelContainer.shared)
    }
    
    /// Check permissions and decide whether to show onboarding or proceed with imports
    /// This runs once at app launch, before user can interact with the UI
    private func checkPermissionsAndSetup() async {
        // Check if onboarding was completed
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if !hasCompletedOnboarding {
            return
        }
        
        // Onboarding is marked complete - verify permissions are still valid
        // This handles the case where app was rebuilt and macOS revoked permissions
        let shouldResetOnboarding = await checkIfPermissionsLost()
        
        if shouldResetOnboarding {
            logger.warning("Permissions lost (likely due to rebuild) — resetting onboarding")
            await MainActor.run {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                showOnboarding = true
            }
            return
        }
        
        // Onboarding is marked complete and permissions are valid - trigger imports
        await triggerImportsForEnabledSources()
    }
    
    /// Check if permissions that should be granted (based on settings) are actually missing
    /// Returns true if onboarding should be reset due to lost permissions
    private func checkIfPermissionsLost() async -> Bool {
        // Check if auto-detection is enabled
        let autoDetectEnabled = UserDefaults.standard.bool(forKey: "autoDetectPermissionLoss")
        
        // Default to true if never set (first launch)
        let shouldAutoDetect = UserDefaults.standard.object(forKey: "autoDetectPermissionLoss") == nil ? true : autoDetectEnabled
        
        if !shouldAutoDetect {
            return false
        }

        let contactsEnabled = UserDefaults.standard.bool(forKey: "sam.contacts.enabled")
        let calendarEnabled = UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled")

        // If nothing was ever enabled, don't reset (user might have skipped everything)
        if !contactsEnabled && !calendarEnabled {
            return false
        }
        
        var permissionsLost = false
        
        // Check contacts if it was enabled
        if contactsEnabled {
            let contactsAuth = await ContactsService.shared.authorizationStatus()
            if contactsAuth != .authorized {
                logger.warning("Contacts was enabled but permission is now \(contactsAuth.rawValue)")
                permissionsLost = true
            }
        }
        
        // Check calendar if it was enabled
        if calendarEnabled {
            let calendarAuth = await CalendarService.shared.authorizationStatus()
            if calendarAuth != .fullAccess {
                logger.warning("Calendar was enabled but permission is now \(calendarAuth.rawValue)")
                permissionsLost = true
            }
        }
        
        return permissionsLost
    }
    
    /// Triggers imports after onboarding completes in the same session
    private func triggerImportsAfterOnboarding() async {
        // Check if onboarding was actually completed (not just dismissed via Quit)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if hasCompletedOnboarding {
            logger.info("Onboarding completed — triggering imports")
            await triggerImportsForEnabledSources()
        }
    }
    
    /// Shared function to trigger imports based on which sources are enabled
    private func triggerImportsForEnabledSources() async {
        let contactsEnabled = UserDefaults.standard.bool(forKey: "sam.contacts.enabled")
        let calendarEnabled = UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled")
        let mailEnabled = UserDefaults.standard.bool(forKey: "mailImportEnabled")

        if contactsEnabled {
            await ContactsImportCoordinator.shared.importNow()
        }

        if calendarEnabled {
            await CalendarImportCoordinator.shared.importNow()
        }

        if mailEnabled {
            await MailImportCoordinator.shared.importNow()
        }

        if !contactsEnabled && !calendarEnabled && !mailEnabled {
            logger.info("No sources enabled — app running in limited mode")
        }
    }
}

