//
//  ContextListPlaceholderView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct ContextListPlaceholderView: View {

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No contexts selected")
                .font(.title3)
                .bold()

            Text("Contexts represent households, businesses, and recruiting relationships. Select one to view participants, products, and obligations.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            Button("Create New Context") {
                // future action
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .navigationTitle("Contexts")
    }
}
