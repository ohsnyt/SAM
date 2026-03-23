//
//  InvitationRecipientReviewSheet.swift
//  SAM
//
//  Created on March 23, 2026.
//  Review sheet shown after sent mail detection when recipients need classification.
//  Handles ambiguous CC recipients (Client/Lead in CC) and new contacts in TO.
//

import SwiftUI

struct InvitationRecipientReviewSheet: View {

    let matchResult: SentMailMatchResult
    let recipients: [ResolvedRecipient]
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var decisions: [UUID: RecipientDecision] = [:]

    private enum RecipientDecision {
        case addAsInvitee
        case informationalOnly
        case ignore
    }

    /// Recipients that were auto-handled (already confirmed).
    private var autoHandled: [ResolvedRecipient] {
        recipients.filter { r in
            switch r.classification {
            case .invitee:
                return r.person != nil
            case .informational:
                return true
            default:
                return false
            }
        }
    }

    /// Recipients needing user decisions.
    private var needsDecision: [ResolvedRecipient] {
        recipients.filter { r in
            switch r.classification {
            case .ambiguous, .newContact:
                return true
            case .invitee:
                return r.person == nil  // New contact in TO
            default:
                return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invitation Recipients")
                        .samFont(.title3, weight: .bold)
                    Text("SAM detected your sent invitation — review recipients below")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Auto-handled section
                    if !autoHandled.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Automatically Updated", systemImage: "checkmark.circle.fill")
                                .samFont(.headline)
                                .foregroundStyle(.green)

                            ForEach(autoHandled) { recipient in
                                autoHandledRow(recipient)
                            }
                        }

                        Divider()
                    }

                    // Needs decision section
                    if !needsDecision.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Needs Your Input", systemImage: "questionmark.circle.fill")
                                .samFont(.headline)
                                .foregroundStyle(.orange)

                            ForEach(needsDecision) { recipient in
                                decisionRow(recipient)
                            }
                        }
                    }

                    if autoHandled.isEmpty && needsDecision.isEmpty {
                        ContentUnavailableView(
                            "All Processed",
                            systemImage: "checkmark.circle",
                            description: Text("All recipients were automatically handled")
                        )
                    }
                }
                .padding(16)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Done") {
                    applyDecisions()
                    onDismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
    }

    // MARK: - Row Views

    private func autoHandledRow(_ recipient: ResolvedRecipient) -> some View {
        HStack(spacing: 8) {
            Image(systemName: recipient.field == .to ? "person.fill" : "info.circle")
                .foregroundStyle(recipient.field == .to ? .blue : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                if let person = recipient.person {
                    Text(person.name)
                        .samFont(.body)
                } else {
                    Text(recipient.email)
                        .samFont(.body)
                }

                HStack(spacing: 4) {
                    Text(recipient.field.rawValue.uppercased())
                        .samFont(.caption2)
                        .foregroundStyle(.secondary)

                    switch recipient.classification {
                    case .invitee:
                        Text("Marked as invited")
                            .samFont(.caption2)
                            .foregroundStyle(.green)
                    case .informational:
                        Text("Informational — not an invitee")
                            .samFont(.caption2)
                            .foregroundStyle(.secondary)
                    default:
                        EmptyView()
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func decisionRow(_ recipient: ResolvedRecipient) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.orange)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    if let person = recipient.person {
                        HStack(spacing: 4) {
                            Text(person.name)
                                .samFont(.body)
                            ForEach(person.roles.prefix(2), id: \.self) { role in
                                Text(role)
                                    .samFont(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                    Text(recipient.email)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    switch recipient.classification {
                    case .ambiguous(let role):
                        Text("\(role) in CC — was this an invitation or informational?")
                            .samFont(.caption)
                            .foregroundStyle(.orange)
                    case .newContact(let email):
                        Text("\(email) is not in SAM — add as participant?")
                            .samFont(.caption)
                            .foregroundStyle(.orange)
                    default:
                        EmptyView()
                    }
                }

                Spacer()
            }

            // Decision buttons
            HStack(spacing: 8) {
                let decision = decisions[recipient.id]

                decisionButton("Add as Invitee", icon: "person.badge.plus", isSelected: decision == .addAsInvitee) {
                    decisions[recipient.id] = .addAsInvitee
                }

                decisionButton("Informational", icon: "info.circle", isSelected: decision == .informationalOnly) {
                    decisions[recipient.id] = .informationalOnly
                }

                decisionButton("Ignore", icon: "xmark", isSelected: decision == .ignore) {
                    decisions[recipient.id] = .ignore
                }
            }
            .padding(.leading, 28)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func decisionButton(_ title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : nil)
        .controlSize(.small)
    }

    // MARK: - Apply Decisions

    private func applyDecisions() {
        for recipient in needsDecision {
            guard let decision = decisions[recipient.id] else { continue }

            switch decision {
            case .addAsInvitee:
                if let person = recipient.person {
                    SentMailDetectionService.shared.addAsParticipantAndMarkInvited(
                        personID: person.id,
                        eventID: matchResult.matchedEventID
                    )
                }
            case .informationalOnly, .ignore:
                break
            }
        }
    }
}
