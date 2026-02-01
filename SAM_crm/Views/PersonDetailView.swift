//
//  PersonDetailView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct PersonDetailView: View {
    let person: PersonRowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                header

                GroupBox("Contexts") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(person.contexts) { ctx in
                            HStack {
                                Label(ctx.name, systemImage: ctx.icon)
                                Spacer()
                                Text(ctx.kindDisplay)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Obligations") {
                    VStack(alignment: .leading, spacing: 10) {
                        if person.consentAlertsCount == 0 && person.responsibilityNotes.isEmpty {
                            Text("No outstanding obligations.")
                                .foregroundStyle(.secondary)
                        } else {
                            if person.consentAlertsCount > 0 {
                                Label("\(person.consentAlertsCount) consent item(s) need review", systemImage: "checkmark.seal")
                            }
                            if !person.responsibilityNotes.isEmpty {
                                ForEach(person.responsibilityNotes, id: \.self) { note in
                                    Label(note, systemImage: "person.badge.shield.checkmark")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Recent Interactions") {
                    VStack(alignment: .leading, spacing: 8) {
                        if person.recentInteractions.isEmpty {
                            Text("No recent interactions recorded.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(person.recentInteractions) { i in
                                HStack(alignment: .top) {
                                    Image(systemName: i.icon)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(i.title)
                                        Text(i.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(i.whenText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("SAM Insights") {
                    VStack(alignment: .leading, spacing: 16) {
                        if person.insights.isEmpty {
                            Text("No insights for this person right now.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(person.insights.enumerated()), id: \.offset) { pair in
                                InsightCardView(insight: pair.element)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading) // <- pins to leading edge
        }
        .navigationTitle(person.displayName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(person.displayName)
                .font(.title2)
                .bold()

            if !person.roleBadges.isEmpty {
                Text(person.roleBadges.joined(separator: " • "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Open in Contacts") { /* later */ }
                Button("Message") { /* later */ }
                Button("Schedule") { /* later */ }
            }
            .buttonStyle(.glass)
            .padding(.top, 4)
        }
    }
}
