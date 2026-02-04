//
//  SAM_crmApp.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import EventKit
import SwiftData

@main
struct SAM_crmApp: App {

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .modelContainer(SAMModelContainer.shared)
                .task {
                    // Phase-2 seed: populate SwiftData on first launch.
                    // No-op on every subsequent launch.
                    SAMModelContainer.seedOnFirstLaunch()

                    // Wire the shared repository to the app-wide container
                    // so that its writes land in the same store that @Query
                    // observes.  Must happen before the first calendar kick.
                    EvidenceRepository.shared.configure(container: SAMModelContainer.shared)

                    CalendarImportCoordinator.shared.kick(reason: "app launch")
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    CalendarImportCoordinator.shared.kick(reason: "app became active")
                }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                    CalendarImportCoordinator.shared.kick(reason: "calendar changed")
                }
        }

        Settings {
            SamSettingsView()
                .modelContainer(SAMModelContainer.shared)
        }
    }
}
