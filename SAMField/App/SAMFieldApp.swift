//
//  SAMFieldApp.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F1: iOS Companion App Foundation
//
//  SAM Field — the iOS companion app for SAM.
//  Captures voice notes, tracks mileage, surfaces nearby contacts,
//  and delivers pre-meeting briefings while in the field.
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
        }
    }
}
