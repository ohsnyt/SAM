//
//  SAMFieldApp.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F1: iOS Companion App Foundation
//
//  SAM Field — the iOS companion app for SAM.
//  Captures voice notes, tracks mileage, and delivers pre-meeting
//  briefings while in the field.
//

import SwiftUI
import SwiftData

@main
struct SAMFieldApp: App {

    let container: ModelContainer

    init() {
        container = SAMFieldModelContainer.shared
    }

    var body: some Scene {
        WindowGroup {
            FieldTabView()
                .modelContainer(container)
                .task {
                    // TipKit must be configured before any TipView appears.
                    FieldTipState.configure()

                    // Bootstrap the pairing trust store before the audio
                    // streaming service browses — without this, a reconnect
                    // after launch would race the keychain load and drop
                    // known-good Macs as "not paired".
                    await DevicePairingService.shared.bootstrap()

                    // Configure the meeting capture coordinator with the
                    // shared container. This also wires up the pending
                    // upload service and runs crash recovery on any
                    // orphaned WAV files from force-quits / crashes.
                    MeetingCaptureCoordinator.shared.configure(container: container)

                    // Configure the saved-address service so trip autocomplete,
                    // Home chips, and the Trip Settings screen can read/write.
                    SavedAddressService.shared.configure(container: container)
                }
        }
    }
}
