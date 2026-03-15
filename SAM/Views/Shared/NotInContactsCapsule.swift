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
    private let phone: String?  // First phone alias for matching

    // MARK: - State

    @State private var showingConfirmation = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var didCreate = false
    @State private var matchStatus: MatchStatus = .unknown
    @State private var containerMismatch = false
    @State private var mismatchedContactIdentifier: String?

    /// Whether the person exists in Apple Contacts (outside SAM group) or not at all
    private enum MatchStatus {
        case unknown        // Haven't checked yet
        case notInContacts  // No Apple Contact exists
        case notInSAMGroup  // Apple Contact exists but not in SAM group
    }

    // MARK: - Initializers

    /// For a SamPerson that exists but has no Apple Contact link.
    init(person: SamPerson) {
        self.person = person
        self.displayName = person.displayNameCache ?? person.displayName
        self.email = person.emailCache ?? person.email
        self.phone = person.phoneAliases.first
    }

    /// For an unmatched participant (no SamPerson exists yet).
    init(name: String, email: String?) {
        self.person = nil
        self.displayName = name
        self.email = email
        self.phone = nil
    }

    // MARK: - Body

    var body: some View {
        // For SamPerson mode: only show when contactIdentifier is nil
        // For name/email mode: always show (caller decides visibility)
        if shouldShow {
            Button {
                showingConfirmation = true
            } label: {
                Text(badgeLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(matchStatus == .notInSAMGroup
                  ? "Add \(displayName) to SAM group"
                  : "Add \(displayName) to Apple Contacts")
            .popover(isPresented: $showingConfirmation) {
                confirmationPopover
            }
            .task {
                await checkMatchStatus()
            }
        }
    }

    private var badgeLabel: String {
        switch matchStatus {
        case .unknown, .notInContacts:
            return "Not in Contacts"
        case .notInSAMGroup:
            return "Not in SAM"
        }
    }

    private var shouldShow: Bool {
        if didCreate { return false }
        if let person { return person.contactIdentifier == nil }
        return true
    }

    private var confirmationPopover: some View {
        VStack(spacing: 12) {
            if containerMismatch {
                // Container mismatch: offer move, duplicate, or cancel
                Text("Different Account")
                    .font(.headline)

                Text("\"\(displayName)\" is stored in a non-iCloud account and can't be added to your SAM group directly.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                VStack(spacing: 8) {
                    Button {
                        Task { await copyToICloud(deleteOriginal: true) }
                    } label: {
                        HStack {
                            Label("Move to iCloud", systemImage: "arrow.right.circle")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating)
                    .help("Move this contact to iCloud and add to SAM. The original will be deleted.")

                    Button {
                        Task { await copyToICloud(deleteOriginal: false) }
                    } label: {
                        HStack {
                            Label("Copy to iCloud", systemImage: "doc.on.doc")
                            Spacer()
                        }
                    }
                    .disabled(isCreating)
                    .help("Create a copy of this contact in iCloud and add to SAM. The original stays where it is.")

                    Button("Cancel", role: .cancel) {
                        showingConfirmation = false
                        errorMessage = nil
                        containerMismatch = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
            } else {
                // Normal flow: add to SAM group or create contact
                Text(matchStatus == .notInSAMGroup ? "Add to SAM?" : "Add to Contacts?")
                    .font(.headline)

                VStack(spacing: 4) {
                    Text(matchStatus == .notInSAMGroup
                         ? "\"\(displayName)\" is in your Contacts but not in the SAM group."
                         : "Create \"\(displayName)\" in Apple Contacts.")
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
        }
        .padding()
        .frame(width: 280)
    }

    // MARK: - Actions

    /// Check whether the person exists in Apple Contacts (outside SAM group)
    private func checkMatchStatus() async {
        let contactsService = ContactsService.shared

        // Try phone search first if we have a phone number
        if let phone, !phone.isEmpty {
            let phoneMatches = await contactsService.searchContactsByPhone(phoneNumber: phone, keys: .detail)
            if !phoneMatches.isEmpty {
                matchStatus = .notInSAMGroup
                return
            }
        }

        // Fall back to name/email search
        let matches = await contactsService.searchContacts(query: displayName, keys: .detail)
        let hasMatch = matches.contains { match in
            let nameMatch = match.displayName.lowercased() == displayName.lowercased()
            let emailMatch: Bool = {
                guard let email else { return false }
                return match.emailAddresses.contains { $0.lowercased() == email.lowercased() }
            }()
            return nameMatch || emailMatch
        }
        matchStatus = hasMatch ? .notInSAMGroup : .notInContacts
    }

    private func addToContacts() async {
        isCreating = true
        errorMessage = nil

        let contactsService = ContactsService.shared
        let peopleRepo = PeopleRepository.shared

        // Search for an existing Apple Contact before creating a new one
        var existingContact: ContactDTO?

        // Try phone search first
        if let phone, !phone.isEmpty {
            let phoneMatches = await contactsService.searchContactsByPhone(phoneNumber: phone, keys: .detail)
            existingContact = phoneMatches.first
        }

        // Fall back to name/email search
        if existingContact == nil {
            let nameMatches = await contactsService.searchContacts(query: displayName, keys: .detail)
            existingContact = nameMatches.first { match in
                let nameMatch = match.displayName.lowercased() == displayName.lowercased()
                let emailMatch: Bool = {
                    guard let email else { return false }
                    return match.emailAddresses.contains { $0.lowercased() == email.lowercased() }
                }()
                return nameMatch || emailMatch
            }
        }

        let contactDTO: ContactDTO
        if let existing = existingContact {
            // Use existing Apple Contact — add to SAM group if needed
            contactDTO = existing
            let groupResult = await contactsService.addContactToSAMGroup(identifier: existing.identifier)
            if case .containerMismatch = groupResult {
                mismatchedContactIdentifier = existing.identifier
                containerMismatch = true
                isCreating = false
                return
            }
            logger.info("Linked to existing Apple Contact for \(displayName, privacy: .private)")
        } else {
            // No match — create new Apple Contact (auto-adds to SAM group)
            guard let created = await contactsService.createContact(
                fullName: displayName,
                email: email,
                note: nil
            ) else {
                errorMessage = "Failed to create contact"
                isCreating = false
                return
            }
            contactDTO = created
            logger.info("Created new Apple Contact for \(displayName, privacy: .private)")
        }

        do {
            if let person {
                // SamPerson already exists — link it to the contact (avoids duplicate)
                try peopleRepo.linkPerson(person, toContact: contactDTO)
            } else {
                // No SamPerson yet — upsert will create one
                try peopleRepo.upsert(contact: contactDTO)
            }
            didCreate = true
            showingConfirmation = false
        } catch {
            errorMessage = "Failed to link: \(error.localizedDescription)"
        }

        isCreating = false
    }

    /// Copy (or move) the mismatched contact to iCloud, add to SAM group, and link.
    private func copyToICloud(deleteOriginal: Bool) async {
        guard let sourceIdentifier = mismatchedContactIdentifier else { return }

        isCreating = true
        errorMessage = nil

        let contactsService = ContactsService.shared
        let peopleRepo = PeopleRepository.shared

        guard let contactDTO = await contactsService.copyContactToICloud(
            identifier: sourceIdentifier,
            deleteOriginal: deleteOriginal
        ) else {
            errorMessage = "Failed to \(deleteOriginal ? "move" : "copy") contact to iCloud."
            isCreating = false
            return
        }

        do {
            if let person {
                try peopleRepo.linkPerson(person, toContact: contactDTO)
            } else {
                try peopleRepo.upsert(contact: contactDTO)
            }
            didCreate = true
            showingConfirmation = false
            containerMismatch = false
            mismatchedContactIdentifier = nil
        } catch {
            errorMessage = "Contact copied but failed to link: \(error.localizedDescription)"
        }

        isCreating = false
    }
}
