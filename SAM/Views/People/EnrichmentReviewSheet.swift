//
//  EnrichmentReviewSheet.swift
//  SAM
//
//  Sheet for reviewing and applying pending contact enrichment updates.
//  Shows per-field toggleable rows with current vs. proposed values.
//  Writes approved fields back to Apple Contacts via ContactEnrichmentCoordinator.
//

import SwiftUI

struct EnrichmentReviewSheet: View {

    // MARK: - Input

    let person: SamPerson
    let enrichments: [PendingEnrichment]

    // MARK: - State

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []
    @State private var isApplying = false
    @State private var applyError: String?
    @State private var enrichmentCoordinator = ContactEnrichmentCoordinator.shared

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Contact Updates")
                        .samFont(.title3)
                        .fontWeight(.semibold)
                    Text("Review suggested updates for \(person.displayNameCache ?? person.displayName)")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            // Field rows
            List {
                if enrichments.isEmpty {
                    Text("No pending updates")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(enrichments, id: \.id) { item in
                        EnrichmentRowView(
                            item: item,
                            isSelected: selectedIDs.contains(item.id),
                            onToggle: {
                                if selectedIDs.contains(item.id) {
                                    selectedIDs.remove(item.id)
                                } else {
                                    selectedIDs.insert(item.id)
                                }
                            }
                        )
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            // Error message
            if let error = applyError {
                Text(error)
                    .samFont(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button("Dismiss All") {
                    enrichmentCoordinator.dismissEnrichments(enrichments)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isApplying)

                Spacer()

                Button {
                    Task { await applySelected() }
                } label: {
                    if isApplying {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Applying...")
                        }
                    } else {
                        Text("Apply Selected (\(selectedIDs.count))")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty || isApplying)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            // Pre-select all pending items
            selectedIDs = Set(enrichments.map(\.id))
        }
    }

    // MARK: - Apply

    private func applySelected() async {
        isApplying = true
        applyError = nil

        let toApply = enrichments.filter { selectedIDs.contains($0.id) }
        let success = await enrichmentCoordinator.applyEnrichments(toApply, for: person)

        isApplying = false

        if success {
            dismiss()
        } else {
            applyError = "Some updates could not be written. Check Contacts permissions in System Settings."
        }
    }
}

// MARK: - Enrichment Row

private struct EnrichmentRowView: View {
    let item: PendingEnrichment
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .samFont(.title3)

                // Field info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.field.displayName)
                            .samFont(.subheadline)
                            .fontWeight(.medium)
                        Text(item.source.displayName)
                            .samFont(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    HStack(spacing: 8) {
                        if let current = item.currentValue, !current.isEmpty {
                            Text(current)
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                                .strikethrough()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        if item.field == .contactRelation {
                            Text(Self.formatContactRelation(item.proposedValue))
                                .samFont(.caption)
                                .foregroundStyle(.blue)
                        } else if item.field == .anniversary {
                            Text(Self.formatAnniversaryDate(item.proposedValue))
                                .samFont(.caption)
                                .foregroundStyle(.blue)
                        } else {
                            Text(item.proposedValue)
                                .samFont(.caption)
                                .foregroundStyle(.blue)
                        }
                    }

                    if let detail = item.sourceDetail, !detail.isEmpty {
                        Text(detail)
                            .samFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Format "wife|Ruth Smith" as "wife — Ruth Smith" for readable display.
    static func formatContactRelation(_ value: String) -> String {
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return value }
        return "\(parts[0]) — \(parts[1])"
    }

    /// Format "YYYY-MM-DD" or "MM-DD" anniversary date for readable display.
    static func formatAnniversaryDate(_ value: String) -> String {
        let components = value.split(separator: "-").compactMap { Int($0) }
        guard components.count >= 2 else { return value }

        var dc = DateComponents()
        if components.count == 3 {
            dc.year = components[0]
            dc.month = components[1]
            dc.day = components[2]
        } else {
            dc.month = components[0]
            dc.day = components[1]
        }

        if let date = Calendar.current.date(from: dc) {
            let formatter = DateFormatter()
            formatter.dateStyle = components.count == 3 ? .long : .long
            if components.count < 3 {
                formatter.dateFormat = "MMMM d"
            }
            return formatter.string(from: date)
        }
        return value
    }
}
