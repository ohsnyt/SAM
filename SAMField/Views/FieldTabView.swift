//
//  FieldTabView.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F1: iOS Companion App Foundation
//
//  Root tab navigation for SAM Field.
//  Four tabs: Today, Record, Trips, Nearby.
//

import SwiftUI
import SwiftData

struct FieldTabView: View {
    @State private var selectedTab: FieldTab = .today

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Today", systemImage: "sun.horizon", value: .today) {
                NavigationStack {
                    TodayView()
                }
            }

            // Unified recording tab — connects to the Mac when available
            // (live transcription + summary) or records locally and queues
            // for later sync when the Mac can't be reached.
            Tab("Record", systemImage: "waveform.and.mic", value: .record) {
                NavigationStack {
                    MeetingCaptureView()
                }
            }

            Tab("Trips", systemImage: "car.fill", value: .trips) {
                NavigationStack {
                    TripsView()
                }
            }

            Tab("Nearby", systemImage: "map", value: .nearby) {
                NavigationStack {
                    NearbyView()
                }
            }
        }
    }
}

enum FieldTab: String, Hashable {
    case today
    case record
    case trips
    case nearby
}

#Preview("SAM Field") {
    FieldTabView()
        .modelContainer(for: SamTrip.self, inMemory: true)
}
