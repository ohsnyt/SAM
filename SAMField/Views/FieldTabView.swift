//
//  FieldTabView.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F1: iOS Companion App Foundation
//
//  Root tab navigation for SAM Field.
//  Four tabs: Today, Capture, Trips, Nearby.
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

            Tab("Capture", systemImage: "mic.badge.plus", value: .capture) {
                NavigationStack {
                    CaptureView()
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
    case capture
    case trips
    case nearby
}

#Preview("SAM Field") {
    FieldTabView()
        .modelContainer(for: SamTrip.self, inMemory: true)
}
