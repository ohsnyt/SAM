//
//  PersonRow.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI

struct PersonRow: View {
    let person: PersonListItemModel
    var onLinkContactTapped: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.displayName)
                        .font(.body)
                    
                    // Show "Me" badge if this is the me card
                    if person.isMeCard {
                        MeCardBadge()
                    }
                }

                if !person.roleBadges.isEmpty {
                    Text(person.roleBadges.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Compact status indicators
            if person.consentAlertsCount > 0 {
                Badge(count: person.consentAlertsCount, systemImage: "checkmark.seal")
            }
            if person.reviewAlertsCount > 0 {
                Badge(count: person.reviewAlertsCount, systemImage: "exclamationmark.triangle")
            }
            if person.contactIdentifier == nil || person.contactIdentifier?.isEmpty == true {
                Button {
                    onLinkContactTapped?()
                } label: {
                    Label("Unlinked", systemImage: "person.crop.circle.badge.questionmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("Link to an existing contact or create a new one")
                .accessibilityLabel("Unlinked contact. Tap to link.")
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            // Set/Clear Me Card (manual selection for macOS)
            if person.isMeCard {
                Button("Clear as Me") {
                    Task { @MainActor in
                        MeCardManager.shared.clearMeCard()
                    }
                }
                Divider()
            } else if let contactIdentifier = person.contactIdentifier {
                Button("Set as Me") {
                    Task { @MainActor in
                        MeCardManager.shared.setMeCard(contactIdentifier: contactIdentifier)
                    }
                }
                Divider()
            }
            
            Button("Open in Contacts") { /* later */ }
            Button("Copy Name") { 
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(person.displayName, forType: .string) 
            }
        }
    }
}

private struct Badge: View {
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text("\(count)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}
