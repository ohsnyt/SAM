//
//  SAM_crmApp.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import EventKit
import SwiftData
import Contacts
import AppKit

@main
struct SAM_crmApp: App {

    #if DEBUG
    private static func confirmResetAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Reset SAM Data?"
        alert.informativeText = "This will delete all local SAM data and reseed fixtures. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
    #endif

    static func resetStoreIfRequested() -> Bool {
        #if DEBUG
        let userDefaultsRequest = UserDefaults.standard.bool(forKey: "sam.debug.resetOnNextLaunch")
        if userDefaultsRequest {
            UserDefaults.standard.set(false, forKey: "sam.debug.resetOnNextLaunch")
            performDestructiveReset()
            return true
        }
        
        if NSEvent.modifierFlags.contains(.option) {
            if confirmResetAlert() {
                performDestructiveReset()
                return true
            } else {
                return false
            }
        }
        #endif
        return false
    }
    
    private static func performDestructiveReset() {
        // Swap the shared container so both UI and repositories see the same store after reset.
        #if DEBUG
        let fresh = SAMModelContainer.makeFreshContainer()
        SAMModelContainer.replaceShared(with: fresh)
        EvidenceRepository.shared.configure(container: fresh)
        PeopleRepository.shared.configure(container: fresh)
        FixtureSeeder.seedIfNeeded(using: fresh)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .task(priority: .high) {
                    // DEBUG ONLY: To trigger store reset, set `sam.debug.resetOnNextLaunch=1` in environment or hold Option at launch.
                    if SAM_crmApp.resetStoreIfRequested() {
                        // no-op; reset done
                    }
                }
                .modelContainer(SAMModelContainer.shared)
                .task {
                    // Phase-2 seed: populate SwiftData on first launch.
                    // No-op on every subsequent launch.
                    seedModelContainerOnFirstLaunch()

                    // Wire the shared repository to the app-wide container
                    // so that its writes land in the same store that @Query
                    // observes.  Must happen before the first calendar kick.
                    print("[App] About to configure repositories with container:", Unmanaged.passUnretained(SAMModelContainer.shared).toOpaque())
                    EvidenceRepository.shared.configure(container: SAMModelContainer.shared)
                    PeopleRepository.shared.configure(container: SAMModelContainer.shared)
                    print("[App] Repositories configured.")

                    // Startup safety net: generate insights at launch
                    CalendarImportCoordinator.kickOnStartup()
                    ContactsImportCoordinator.kickOnStartup()

                    CalendarImportCoordinator.shared.kick(reason: "app launch")
                    ContactsImportCoordinator.shared.kick(reason: "app launch")
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    CalendarImportCoordinator.shared.kick(reason: "app became active")
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    CalendarImportCoordinator.shared.kick(reason: "calendar changed")
                }
                .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
                    ContactsImportCoordinator.shared.kick(reason: "contacts changed")
                }
        }
        .commands {
            AppCommands()
        }
        // Remove .defaultAppStorage if present - it can interfere with @AppStorage in views
        
        #if os(macOS)
        SwiftUI.Settings {
            SamSettingsView()
                .modelContainer(SAMModelContainer.shared)
        }
        #endif
    }
}

