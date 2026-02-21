//
//  NotInContactsCapsule.swift
//  SAM
//
//  Reusable capsule badge + button for people not yet in Apple Contacts.
//  Shown wherever a SamPerson with nil contactIdentifier appears,
//  or for unmatched event participants.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "NotInContactsCapsule")

/// Orange "Not in Contacts" capsule that doubles as an "Add to Contacts" button.
///
/// Two usage modes:
/// 1. `init(person:)` — for a SamPerson without contactIdentifier
/// 2. `init(name:email:)` — for unmatched event participants not yet in SAM
///
/// When tapped, shows a confirmation popover. On confirm, creates the contact
/// in Apple Contacts and links/creates the SamPerson.
struct NotInContactsCapsule: View {

    // MARK: - Parameters

    private let person: SamPerson?
    private let displayName: String
    private let email: String?

    // MARK: - State

    @State private var showingConfirmation = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var didCreate = false

    // MARK: - Initializers

    /// For a SamPerson that exists but has no Apple Contact link.
    init(person: SamPerson) {
        self.person = person
        self.displayName = person.displayNameCache ?? person.displayName
        self.email = person.emailCache ?? person.email
    }

    /// For an unmatched participant (no SamPerson exists yet).
    init(name: String, email: String?) {
        self.person = nil
        self.displayName = name
        self.email = email
    }

    // MARK: - Body

    var body: some View {
        // For SamPerson mode: only show when contactIdentifier is nil
        // For name/email mode: always show (caller decides visibility)
        if shouldShow {
            Button {
                showingConfirmation = true
            } label: {
                Text("Not in Contacts")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Add \(displayName) to Apple Contacts")
            .popover(isPresented: $showingConfirmation) {
                confirmationPopover
            }
        }
    }

    private var shouldShow: Bool {
        if didCreate { return false }
        if let person { return person.contactIdentifier == nil }
        return true
    }

    private var confirmationPopover: some View {
        VStack(spacing: 12) {
            Text("Add to Contacts?")
                .font(.headline)

            VStack(spacing: 4) {
                Text("Create \"\(displayName)\" in Apple Contacts.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showingConfirmation = false
                    errorMessage = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    Task { await addToContacts() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 260)
    }

    // MARK: - Action

    private func addToContacts() async {
        isCreating = true
        errorMessage = nil

        guard let contactDTO = await ContactsService.shared.createContact(
            fullName: displayName,
            email: email,
            note: nil
        ) else {
            errorMessage = "Failed to create contact"
            isCreating = false
            return
        }

        do {
            try PeopleRepository.shared.upsert(contact: contactDTO)
            logger.info("Created Apple Contact for \(displayName, privacy: .public)")
            didCreate = true
            showingConfirmation = false
        } catch {
            errorMessage = "Created but failed to link: \(error.localizedDescription)"
        }

        isCreating = false
    }
}
