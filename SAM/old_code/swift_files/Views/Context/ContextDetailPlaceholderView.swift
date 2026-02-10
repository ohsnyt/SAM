//
//  ContextDetailPlaceholderView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct ContextDetailPlaceholderView: View {

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No context selected")
                .font(.title3)
                .bold()

            Text("Contexts group people and policies into a household, business, or recruiting relationship. Select one from the list to review participants and obligations.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button("New Household") { }
                Button("New Business") { }
                Button("New Recruiting Context") { }
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .navigationTitle("Context")
    }
}
