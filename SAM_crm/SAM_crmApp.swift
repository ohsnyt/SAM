//
//  SAM_crmApp.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import EventKit

@main
struct SAM_crmApp: App {

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .task {
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
        }
    }
}
