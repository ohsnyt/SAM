//
//  ContextDetailView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

// MARK: - Context Detail View

struct ContextDetailView: View {
    let context: ContextDetailModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                header

                GroupBox("Participants") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(context.participants) { p in
                            ContextParticipantRow(participant: p)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Products & Policies") {
                    VStack(alignment: .leading, spacing: 10) {
                        if context.products.isEmpty {
                            Text("No products recorded yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(context.products) { product in
                                ProductRow(product: product)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Consent Requirements") {
                    VStack(alignment: .leading, spacing: 10) {
                        if context.consentRequirements.isEmpty {
                            Text("No outstanding consent requirements.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(context.consentRequirements) { cr in
                                ConsentRequirementRow(requirement: cr)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Recent Interactions") {
                    VStack(alignment: .leading, spacing: 10) {
                        if context.recentInteractions.isEmpty {
                            Text("No recent interactions recorded.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(context.recentInteractions) { i in
                                InteractionRow(interaction: i)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("SAM Insights") {
                    VStack(alignment: .leading, spacing: 12) {
                        if context.insights.isEmpty {
                            Text("No insights for this context right now.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(context.insights.enumerated()), id: \.offset) { pair in
                                InsightCardView(insight: pair.element)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading) // pin to leading edge
        }
        .navigationTitle(context.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Add Person") { }
                    .buttonStyle(.glass)

                Button("Add Product") { }
                    .buttonStyle(.glass)

                Button {
                    // future: open a context inspector / notes panel
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.glass)
                .help("Context Info")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(context.name)
                .font(.title2)
                .bold()

            Text(context.kindDisplay)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if context.alerts.consentCount > 0 {
                    CountPill(systemImage: "checkmark.seal", text: "\(context.alerts.consentCount) consent")
                }
                if context.alerts.reviewCount > 0 {
                    CountPill(systemImage: "exclamationmark.triangle", text: "\(context.alerts.reviewCount) review")
                }
                if context.alerts.followUpCount > 0 {
                    CountPill(systemImage: "arrow.turn.down.right", text: "\(context.alerts.followUpCount) follow-up")
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Rows

private struct ContextParticipantRow: View {
    let participant: ContextParticipantModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: participant.icon)
                .foregroundStyle(.secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(participant.displayName)
                        .font(.body)

                    Spacer()

                    if participant.isPrimary {
                        Text("Primary")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.secondary.opacity(0.12)))
                    }
                }

                if !participant.roleBadges.isEmpty {
                    FlowChips(labels: participant.roleBadges)
                }

                if let note = participant.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ProductRow: View {
    let product: ContextProductModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: product.icon)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(product.title)
                    Spacer()
                    Text(product.statusDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let subtitle = product.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ConsentRequirementRow: View {
    let requirement: ConsentRequirementModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: requirement.statusIcon)
                .foregroundStyle(requirement.statusColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(requirement.title)
                    Spacer()
                    Text(requirement.statusDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(requirement.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let jurisdiction = requirement.jurisdiction, !jurisdiction.isEmpty {
                    Text("Jurisdiction: \(jurisdiction)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct InteractionRow: View {
    let interaction: InteractionModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: interaction.icon)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(interaction.title)
                Text(interaction.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(interaction.whenText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Small UI helpers

private struct CountPill: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

private struct FlowChips: View {
    let labels: [String]

    var body: some View {
        // Simple wrap-ish layout without custom layout types:
        // keeps it compact and stable; later we can swap to a true wrap layout.
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
        }
    }
}
