//
//  NearbyView.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F5: Nearby Contacts (placeholder)
//

import SwiftUI

struct NearbyView: View {
    var body: some View {
        ContentUnavailableView(
            "Nearby",
            systemImage: "map",
            description: Text("A map of nearby contacts and drop-in route planning will appear here.")
        )
        .navigationTitle("Nearby")
    }
}

#Preview("Nearby") {
    NavigationStack {
        NearbyView()
    }
}
