//
//  UnknownSenderQuickAddSheet.swift
//  SAM
//
//  Quick-add sheet for unknown senders who appear to be RSVPing to an event.
//  Phase 1: Name + Add to Event.
//  Phase 2: Editable confirmation message draft → Send or Cancel with options.
//

import SwiftUI

struct UnknownSenderQuickAddSheet: View {

    let rsvp: EventCoordinator.UnknownEventRSVP
    let eventID: UUID
    var onAdded: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var contactName: String = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    // Phase management
    @State private var phase: SheetPhase = .addContact
    @State private var confirmationDraft: String = ""
    @State private var addedParticipation: EventParticipation?
    @State private var addedPerson: SamPerson?
    @State private var isSendingMessage = false
    @State private var showCancelOptions = false

    private enum SheetPhase {
        case addContact     // Phase 1: Name + Add
        case sendMessage    // Phase 2: Confirmation message
    }

    /// Whether the handle looks like a phone number (no @).
    private var isPhone: Bool { !rsvp.senderHandle.contains("@") }

    /// Display-friendly version of the handle.
    private var formattedHandle: String {
        if isPhone {
            // Format as phone: (XXX) XXX-XXXX if 10 digits
            let digits = rsvp.senderHandle.filter(\.isNumber)
            if digits.count == 10 {
                let area = digits.prefix(3)
                let mid = digits.dropFirst(3).prefix(3)
                let last = digits.suffix(4)
                return "(\(area)) \(mid)-\(last)"
            }
            return rsvp.senderHandle
        }
        return rsvp.senderHandle
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(phase == .addContact ? "Add to Event" : "Send Confirmation")
                    .samFont(.headline)
                Spacer()
                if phase == .addContact {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding()

            Divider()

            switch phase {
            case .addContact:
                addContactPhase
            case .sendMessage:
                sendMessagePhase
            }
        }
        .frame(width: 440)
        .onAppear {
            // Pre-fill name if the unknown sender has a display name
            if let name = rsvp.displayName, !name.isEmpty {
                contactName = name
            }
        }
        .confirmationDialog("Cancel Confirmation Message", isPresented: $showCancelOptions) {
            Button("Unconfirm and Remove", role: .destructive) {
                revertAndDismiss()
            }
            Button("Keep Confirmed, Skip Message") {
                onAdded?()
                dismiss()
            }
            Button("Write a Different Message") {
                confirmationDraft = ""
            }
            Button("Go Back", role: .cancel) {}
        }
    }

    // MARK: - Phase 1: Add Contact

    private var addContactPhase: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                // Message preview
                VStack(alignment: .leading, spacing: 6) {
                    Label("Message Received", systemImage: "bubble.left.fill")
                        .samFont(.caption, weight: .bold)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isPhone ? "phone.circle.fill" : "envelope.circle.fill")
                            .samFont(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(rsvp.displayName ?? formattedHandle)
                                .samFont(.callout, weight: .bold)
                            if rsvp.displayName != nil {
                                Text(formattedHandle)
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(rsvp.messageDate.formatted(date: .abbreviated, time: .shortened))
                                .samFont(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text("\"\(rsvp.messagePreview)\"")
                        .samFont(.callout)
                        .italic()
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                // Name field
                VStack(alignment: .leading, spacing: 4) {
                    Text("Contact Name")
                        .samFont(.caption, weight: .bold)
                        .foregroundStyle(.secondary)

                    TextField("Name (optional — leave blank if unknown)", text: $contactName)
                        .textFieldStyle(.roundedBorder)

                    Text("If left blank, the contact will be saved using their \(isPhone ? "phone number" : "email address").")
                        .samFont(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Event context
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .foregroundStyle(.green)
                    Text("Will be added to **\(rsvp.matchedEventTitle)** as Accepted")
                        .samFont(.caption)
                }

                if let error = errorMessage {
                    Text(error)
                        .samFont(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()

            Divider()

            // Actions
            HStack {
                Button("Dismiss Message") {
                    dismissUnknownSender()
                }
                .controlSize(.regular)

                Spacer()

                Button("Add to Event") {
                    addToEvent()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    // MARK: - Phase 2: Send Confirmation Message

    private var sendMessagePhase: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // Confirmed badge
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Added to **\(rsvp.matchedEventTitle)**")
                        .samFont(.callout)
                }

                Divider()

                // Draft message
                VStack(alignment: .leading, spacing: 4) {
                    Label("Confirmation Message", systemImage: "paperplane")
                        .samFont(.caption, weight: .bold)
                        .foregroundStyle(.secondary)

                    Text("To: \(formattedHandle)")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $confirmationDraft)
                        .samFont(.body)
                        .frame(minHeight: 80, maxHeight: 120)
                        .padding(4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                if let error = errorMessage {
                    Text(error)
                        .samFont(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    showCancelOptions = true
                }
                .controlSize(.regular)

                Spacer()

                Button {
                    sendConfirmation()
                } label: {
                    if isSendingMessage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(confirmationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingMessage)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func addToEvent() {
        isSaving = true
        errorMessage = nil

        do {
            let nameToUse = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
            let participation = try EventCoordinator.shared.addUnknownSenderToEvent(
                unknownSenderID: rsvp.id,
                eventID: eventID,
                contactName: nameToUse.isEmpty ? nil : nameToUse
            )
            addedParticipation = participation

            // Look up the person and event to generate confirmation draft
            if let participation,
               let person = participation.person,
               let event = participation.event {
                addedPerson = person
                confirmationDraft = EventCoordinator.shared.generateConfirmationMessage(for: person, event: event)
            }

            // Transition to Phase 2 BEFORE calling onAdded —
            // onAdded may refresh the parent and dismiss the sheet prematurely.
            phase = .sendMessage
            isSaving = false
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    private func sendConfirmation() {
        guard !confirmationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSendingMessage = true
        errorMessage = nil

        Task {
            let sent: Bool
            if ComposeService.shared.directSendEnabled {
                sent = await ComposeService.shared.sendDirectIMessage(
                    recipient: rsvp.senderHandle,
                    body: confirmationDraft
                )
            } else {
                sent = ComposeService.shared.composeIMessage(
                    recipient: rsvp.senderHandle,
                    body: confirmationDraft
                )
            }

            if sent {
                // Log the message on the participation
                if let participationID = addedParticipation?.id {
                    try? EventRepository.shared.appendMessage(
                        participationID: participationID,
                        kind: .acknowledgment,
                        channel: .iMessage,
                        body: confirmationDraft,
                        isDraft: false
                    )
                }
                onAdded?()
                dismiss()
            } else {
                errorMessage = "Could not send message. Draft copied to clipboard."
                ComposeService.shared.copyToClipboard(confirmationDraft)
                isSendingMessage = false
            }
        }
    }

    private func dismissUnknownSender() {
        // Just mark the unknown sender as dismissed without adding to event
        if let sender = try? UnknownSenderRepository.shared.fetchByID(rsvp.id) {
            try? UnknownSenderRepository.shared.markDismissed(sender)
        }
        onAdded?()  // Refresh the list
        dismiss()
    }

    /// Revert the add: remove participation and person, re-mark sender as pending.
    private func revertAndDismiss() {
        if let participation = addedParticipation,
           let event = participation.event {
            try? EventRepository.shared.removeParticipant(participationID: participation.id, from: event)
        }
        if let person = addedPerson {
            try? PeopleRepository.shared.delete(person: person)
        }
        // Re-mark the unknown sender as dismissed (user chose to undo the add)
        if let sender = try? UnknownSenderRepository.shared.fetchByID(rsvp.id) {
            try? UnknownSenderRepository.shared.markDismissed(sender)
        }
        onAdded?()
        dismiss()
    }
}
