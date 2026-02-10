//
//  InboxDetailView.swift
//  SAM_crm
//

import SwiftUI
import SwiftData
#if os(macOS)
import Contacts
// import ContactsUI
import AppKit
#endif

struct InboxDetailView: View {
    let repo: EvidenceRepository
    let evidenceID: UUID?

    @State private var showFullText: Bool = true
    @State private var selectedFilter: LinkSuggestionStatus = .pending
    @State private var alertMessage: String? = nil
    @State private var pendingContactPrompt: PendingContactPrompt? = nil

    @Environment(\.modelContext) private var modelContext

    #if os(macOS)
    @State private var contactPresenter = ContactPresenter()
    @State private var popoverAnchorView: NSView?
    #endif

    // ── SwiftData-driven lookup ───────────────────────────────────────
    // A static @Query keyed on evidenceID keeps SwiftUI in the loop when
    // the selected item mutates (state change, link added, etc.).
    // We use a helper view so that the @Query predicate can close over the
    // concrete (non-optional) ID; when evidenceID is nil we short-circuit
    // to EmptyDetailView without ever issuing a query.
    var body: some View {
        if let id = evidenceID {
#if os(macOS)
            InboxDetailLoader(
                id: id,
                repo: repo,
                showFullText: $showFullText,
                selectedFilter: $selectedFilter,
                alertMessage: $alertMessage,
                pendingContactPrompt: $pendingContactPrompt,
                contactPresenter: contactPresenter,
                popoverAnchorView: $popoverAnchorView
            )
#else
            InboxDetailLoader(
                id: id,
                repo: repo,
                showFullText: $showFullText,
                selectedFilter: $selectedFilter,
                alertMessage: $alertMessage,
                pendingContactPrompt: $pendingContactPrompt
            )
#endif
        } else {
            EmptyDetailView()
                .padding()
        }
    }

    fileprivate struct AlertMessage: Identifiable {
        let id = UUID()
        let text: String
    }
    
    struct PendingContactPrompt: Identifiable {
        let id = UUID()
        let firstName: String
        let lastName: String
        let email: String
        var displayName: String {
            let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? email : "\(name) <\(email)>"
        }
    }

    private func openContactsToCreate(firstName: String, lastName: String, email: String) {
        let contactsApp = URL(fileURLWithPath: "/System/Applications/Contacts.app")
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        var queryItems: [URLQueryItem] = []
        if !firstName.isEmpty { queryItems.append(URLQueryItem(name: "firstname", value: firstName)) }
        if !lastName.isEmpty { queryItems.append(URLQueryItem(name: "lastname", value: lastName)) }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let mailto = components.url else { return }

        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([mailto], withApplicationAt: contactsApp, configuration: config) { app, error in
            if let error {
                NSLog("Failed to open Contacts for new contact: %@", error.localizedDescription)
                alertMessage = "Contacts could not be opened. You can add it manually in Contacts."
            }
        }
    }
    
    #if os(macOS)
    // Nonisolated helper: resolves a contact by email and returns display name + identifier
    nonisolated private func resolveByEmail(_ email: String) -> (displayName: String, contactIdentifier: String)? {
        #if canImport(Contacts)
        let store = ContactsImportCoordinator.contactStore
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        guard let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch).first else {
            return nil
        }
        let given = contact.givenName
        let family = contact.familyName
        let full = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        let display: String
        if full.isEmpty {
            display = email
        } else if contact.emailAddresses.first != nil {
            display = "\(full) <\(email)>"
        } else {
            display = full
        }
        return (display, contact.identifier)
        #else
        return nil
        #endif
    }

    private func refreshParticipantsAfterDelay(evidenceID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refreshParticipantsNow(evidenceID: evidenceID)
        }
    }

    /// A value type carrying the resolved contact data back from the
    /// background thread — avoids holding CNContact references across
    /// actor boundaries.
    private struct ResolvedContact {
        let index: Int
        let hint: ParticipantHint        // original, for isOrganizer etc.
        let displayName: String
        let email: String
        let contactIdentifier: String
    }

    @MainActor
    private func refreshParticipantsNow(evidenceID: UUID) async {
        // Use centralized permissions manager to check access (no dialog)
        guard PermissionsManager.shared.hasContactsAccess else { return }
        guard let current = try? repo.item(id: evidenceID) else { return }
        let unverified = current.participantHints.filter { !$0.isVerified && $0.rawEmail != nil }
        guard !unverified.isEmpty else { return }

        // Snapshot everything the background closure needs so we don't
        // capture MainActor-isolated state.
        let hints = current.participantHints
        
        // --- perform all CNContactStore I/O off the main actor ---
        // Snapshot value data to avoid capturing MainActor state
        let hintsCopy = hints

        let resolved: [ResolvedContact] = await Task.detached(priority: .userInitiated) { @Sendable in
            var results: [ResolvedContact] = []
            for (index, hint) in hintsCopy.enumerated() {
                guard !hint.isVerified, let email = hint.rawEmail else { continue }
                if let (display, identifier) = resolveByEmail(email) {
                    results.append(ResolvedContact(
                        index: index,
                        hint: hint,
                        displayName: display,
                        email: email,
                        contactIdentifier: identifier
                    ))
                }
            }
            return results
        }.value

        guard !resolved.isEmpty else { return }

        // --- back on the main actor: mutate the @Model instance directly ---
        // SamEvidenceItem is a SwiftData @Model class; property mutations
        // are automatically tracked and persisted.
        var newHints = hints
        for r in resolved {
            newHints[r.index] = ParticipantHint(
                displayName: r.displayName,
                isOrganizer: r.hint.isOrganizer,
                isVerified: true,
                rawEmail: r.email
            )

            // --- Person creation / identifier sync ---
            ensurePersonExists(
                displayName: r.displayName,
                email: r.email,
                contactIdentifier: r.contactIdentifier
            )
        }

        current.participantHints = newHints
    }

    /// If no Person with this email exists yet, create one from the resolved
    /// contact data.  If one already exists but lacks a `contactIdentifier`,
    /// patch it in.  Either way the person ends up with both fields populated
    /// so `ContactPhotoFetcher` uses the fast identifier path.
    private func ensurePersonExists(displayName: String, email: String, contactIdentifier: String) {
        // SwiftData-backed: find by email, patch identifier if missing, or create.
        // 1) Try to fetch an existing SamPerson by email.
        let fetch = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.email == email }
        )
        let existing = try? modelContext.fetch(fetch).first

        if let person = existing {
            if person.contactIdentifier == nil {
                person.contactIdentifier = contactIdentifier
                try? modelContext.save()
            }
            return
        }

        // 2) Create a new person using the resolved contact details.
        let newPerson = SamPerson(
            id: UUID(),
            displayName: displayName,
            roleBadges: ["Client"],
            contactIdentifier: contactIdentifier,
            email: email,
            consentAlertsCount: 0,
            reviewAlertsCount: 0
        )
        modelContext.insert(newPerson)
        try? modelContext.save()
    }
    #endif
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - InboxDetailLoader  (query-driven wrapper)
// ─────────────────────────────────────────────────────────────────────

/// Wraps the detail pane so that SwiftData keeps it live.
///
/// We deliberately avoid building a `#Predicate` inside a hand-written
/// `init` — that combination triggers a Swift-compiler crash in the
/// constraint solver (recordOpenedTypes assertion, Swift 6.2).
///
/// Instead we fetch the full evidence set with an unfiltered `@Query`
/// (the Inbox table is small) and filter to the selected `id` in
/// Swift.  The `@Query` still gives us automatic invalidation when
/// *any* `SamEvidenceItem` changes, which is exactly what we need:
/// the detail pane re-renders whenever its item is mutated.
private struct InboxDetailLoader: View {
    let id: UUID
    let repo: EvidenceRepository

    @Binding var showFullText: Bool
    @Binding var selectedFilter: LinkSuggestionStatus
    @Binding var alertMessage: String?
    @Binding var pendingContactPrompt: InboxDetailView.PendingContactPrompt?

    #if os(macOS)
    var contactPresenter: ContactPresenter
    @Binding var popoverAnchorView: NSView?
    #endif

    // Unfiltered query — SwiftData invalidates this whenever any
    // SamEvidenceItem row changes, so the computed `item` below
    // automatically picks up mutations to the selected item.
    @Query(sort: \SamEvidenceItem.occurredAt, order: .reverse)
    private var allItems: [SamEvidenceItem]

    /// The single item we actually want to display.
    private var item: SamEvidenceItem? {
        allItems.first { $0.id == id }
    }

    var body: some View {
        if let item = item {
#if os(macOS)
            LoadedDetailView(
                item: item,
                showFullText: $showFullText,
                selectedFilter: $selectedFilter,
                alertMessage: $alertMessage,
                pendingContactPrompt: $pendingContactPrompt,
                contactPresenter: contactPresenter,
                popoverAnchorView: $popoverAnchorView,
                onMarkDone: { try? repo.markDone(item.id) },
                onReopen: { try? repo.reopen(item.id) },
                onAcceptSuggestion: { try? repo.acceptSuggestion(evidenceID: item.id, suggestionID: $0) },
                onDeclineSuggestion: { try? repo.declineSuggestion(evidenceID: item.id, suggestionID: $0) },
                onRemoveConfirmedLink: { target, targetID, revert in
                    try? repo.removeConfirmedLink(
                        evidenceID: item.id,
                        target: target,
                        targetID: targetID,
                        revertSuggestionTo: revert
                    )
                },
                onResetSuggestion: { try? repo.resetSuggestionToPending(evidenceID: item.id, suggestionID: $0) },
                onSuggestCreateContact: { first, last, email in
                    pendingContactPrompt = InboxDetailView.PendingContactPrompt(firstName: first, lastName: last, email: email)
                },
                refreshParticipants: { refreshParticipantsAfterDelay(evidenceID: item.id) }
            )
#else
            LoadedDetailView(
                item: item,
                showFullText: $showFullText,
                selectedFilter: $selectedFilter,
                alertMessage: $alertMessage,
                pendingContactPrompt: $pendingContactPrompt,
                onMarkDone: { try? repo.markDone(item.id) },
                onReopen: { try? repo.reopen(item.id) },
                onAcceptSuggestion: { try? repo.acceptSuggestion(evidenceID: item.id, suggestionID: $0) },
                onDeclineSuggestion: { try? repo.declineSuggestion(evidenceID: item.id, suggestionID: $0) },
                onRemoveConfirmedLink: { target, targetID, revert in
                    try? repo.removeConfirmedLink(
                        evidenceID: item.id,
                        target: target,
                        targetID: targetID,
                        revertSuggestionTo: revert
                    )
                },
                onResetSuggestion: { try? repo.resetSuggestionToPending(evidenceID: item.id, suggestionID: $0) },
                onSuggestCreateContact: { first, last, email in
                    pendingContactPrompt = InboxDetailView.PendingContactPrompt(firstName: first, lastName: last, email: email)
                },
                refreshParticipants: { refreshParticipantsAfterDelay(evidenceID: item.id) }
            )
#endif
        } else {
            EmptyDetailView()
                .padding()
        }
    }

    #if os(macOS)
    private func refreshParticipantsAfterDelay(evidenceID: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let _ = try? repo.item(id: evidenceID) else { return }
        }
    }
    #else
    private func refreshParticipantsAfterDelay(evidenceID: UUID) {
        // No-op on non-macOS for now; participant refresh is macOS-only.
    }
    #endif
}

private struct EmptyDetailView: View {
    var body: some View {
        ContentUnavailableView(
            "Select an item",
            systemImage: "tray",
            description: Text("Choose an evidence item from the Inbox list.")
        )
    }
}
private struct LoadedDetailView: View {
    let item: SamEvidenceItem
    @Binding var showFullText: Bool
    @Binding var selectedFilter: LinkSuggestionStatus
    @Binding var alertMessage: String?
    @Binding var pendingContactPrompt: InboxDetailView.PendingContactPrompt?

    #if os(macOS)
    var contactPresenter: ContactPresenter
    @Binding var popoverAnchorView: NSView?
    #endif

    let onMarkDone: () -> Void
    let onReopen: () -> Void
    let onAcceptSuggestion: (UUID) -> Void
    let onDeclineSuggestion: (UUID) -> Void
    let onRemoveConfirmedLink: (EvidenceLinkTarget, UUID, LinkSuggestionStatus) -> Void
    let onResetSuggestion: (UUID) -> Void
    let onSuggestCreateContact: (String, String, String) -> Void
    let refreshParticipants: () -> Void

    var body: some View {
        DetailScrollContent(
            item: item,
            showFullText: $showFullText,
            selectedFilter: $selectedFilter,
            alertMessage: $alertMessage,
            pendingContactPrompt: $pendingContactPrompt,
            onMarkDone: onMarkDone,
            onReopen: onReopen,
            onAcceptSuggestion: onAcceptSuggestion,
            onDeclineSuggestion: onDeclineSuggestion,
            onRemoveConfirmedLink: onRemoveConfirmedLink,
            onResetSuggestion: onResetSuggestion,
            onSuggestCreateContact: onSuggestCreateContact
        )
        .navigationTitle("Inbox")
        .toolbar { toolbarContent }
        .overlay(alignment: Alignment.top) { overlayContent }
        #if os(macOS)
        .background(PopoverAnchorView(anchorView: $popoverAnchorView).frame(width: 0, height: 0))
        #endif
        .alert(item: Binding(
            get: { alertMessage.map { InboxDetailView.AlertMessage(text: $0) } },
            set: { alertMessage = $0?.text }
        )) { wrapped in
            Alert(
                title: Text("Couldn’t Open Contacts"),
                message: Text(wrapped.text),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $showFullText) {
                Image(systemName: showFullText ? "doc.text" : "text.quote")
            }
            .toggleStyle(.button)
            .help(showFullText ? "Show full text" : "Show snippet")
            .keyboardShortcut("t", modifiers: [.command])

            Button(action: onMarkDone) {
                Label("Mark Done", systemImage: "checkmark.circle")
            }
            .buttonStyle(.glass)
            .help("Mark this evidence as reviewed (⌘D)")
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(item.state == .done)
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        OverlayArea(
            alertMessage: $alertMessage,
            pendingContactPrompt: $pendingContactPrompt,
            onAddContact: { prompt in
                #if os(macOS)
                Task { @MainActor in
                    let granted = await contactPresenter.requestAccessIfNeeded()
                    if granted, let anchor = popoverAnchorView {
                        contactPresenter.presentNewContact(from: anchor, firstName: prompt.firstName, lastName: prompt.lastName, email: prompt.email) { saved in
                            if saved {
                                refreshParticipants()
                            }
                        }
                    } else {
                        alertMessage = "Contacts access is required to add a new contact."
                    }
                    withAnimation { pendingContactPrompt = nil }
                }
                #else
                openContacts(first: prompt.firstName, last: prompt.lastName, email: prompt.email)
                withAnimation { pendingContactPrompt = nil }
                refreshParticipants()
                #endif
            },
            onDismissPrompt: {
                withAnimation { pendingContactPrompt = nil }
            }
        )
        .padding(Edge.Set.top, 8)
        .padding(Edge.Set.horizontal, 12)
    }

    #if !os(macOS)
    private func openContacts(first: String, last: String, email: String) {
        // iOS/tvOS/watchOS path (placeholder for parity with macOS branch)
    }
    #endif
}

