//
//  ContentView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct ContentView: View {

    struct MockInsight: InsightDisplayable, Identifiable {
        let id = UUID()
        let kind: InsightKind
        let message: String
        let confidence: Double
        let interactionsCount: Int
        let consentsCount: Int
    }

    let insights: [MockInsight] = [
        .init(kind: .relationshipAtRisk,
              message: "Possible household structure change detected for John and Mary Smith.",
              confidence: 0.72,
              interactionsCount: 3,
              consentsCount: 0),

        .init(kind: .consentMissing,
              message: "Spousal consent is no longer valid for an active household policy.",
              confidence: 0.95,
              interactionsCount: 1,
              consentsCount: 2),

        .init(kind: .complianceWarning,
              message: "Household survivorship structure requires review following relationship change.",
              confidence: 0.88,
              interactionsCount: 2,
              consentsCount: 1)
    ]

    var body: some View {
        NavigationStack {
            AwarenessView(insights: insights)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

#Preview {
    ContentView()
}
