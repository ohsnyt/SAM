//
//  InboxDetailView.swift
//  SAM_crm
//

import SwiftUI
#if os(macOS)
import Contacts
// import ContactsUI
import AppKit
#endif

struct InboxDetailView: View {
    let store: MockEvidenceRuntimeStore
    let evidenceID: UUID?

    @State private var showFullText: Bool = true
    @State private var selectedFilter: LinkSuggestionStatus = .pending
    @State private var alertMessage: String? = nil
    @State private var pendingContactPrompt: PendingContactPrompt? = nil
    
    // Optional: for quick linking actions, we access these stores.
    private let peopleStore = MockPeopleRuntimeStore.shared
    private let contextStore = MockContextRuntimeStore.shared

    #if os(macOS)
    @State private var contactPresenter = ContactPresenter()
    @State private var popoverAnchorView: NSView?
    #endif

    var body: some View {
        if let item = store.item(id: evidenceID) {
            LoadedDetailView(
                item: item,
                showFullText: $showFullText,
                selectedFilter: $selectedFilter,
                alertMessage: $alertMessage,
                pendingContactPrompt: $pendingContactPrompt,
                peopleStore: peopleStore,
                contextStore: contextStore,
                contactPresenter: contactPresenter,
                popoverAnchorView: $popoverAnchorView,
                onMarkDone: { store.markDone(item.id) },
                onReopen: { store.reopen(item.id) },
                onAcceptSuggestion: { store.acceptSuggestion(evidenceID: item.id, suggestionID: $0) },
                onDeclineSuggestion: { store.declineSuggestion(evidenceID: item.id, suggestionID: $0) },
                onRemoveConfirmedLink: { target, targetID, revert in
                    store.removeConfirmedLink(
                        evidenceID: item.id,
                        target: target,
                        targetID: targetID,
                        revertSuggestionTo: revert
                    )
                },
                onResetSuggestion: { store.resetSuggestionToPending(evidenceID: item.id, suggestionID: $0) },
                onSuggestCreateContact: { first, last, email in
                    pendingContactPrompt = PendingContactPrompt(firstName: first, lastName: last, email: email)
                },
                refreshParticipants: { refreshParticipantsAfterDelay(evidenceID: item.id) }
            )
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
    private func refreshParticipantsAfterDelay(evidenceID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Task { @MainActor in
                await refreshParticipantsNow(evidenceID: evidenceID)
            }
        }
    }
    
    @MainActor
    private func refreshParticipantsNow(evidenceID: UUID) async {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        guard var current = store.item(id: evidenceID) else { return }
        let unverified = current.participantHints.filter { !$0.isVerified && $0.rawEmail != nil }
        guard !unverified.isEmpty else { return }
        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        var resolvedAny = false
        var newHints: [ParticipantHint] = current.participantHints
        for (index, hint) in current.participantHints.enumerated() {
            guard !hint.isVerified, let email = hint.rawEmail else { continue }
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            if let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch).first {
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
                let updated = ParticipantHint(
                    displayName: display,
                    isOrganizer: hint.isOrganizer,
                    isVerified: true,
                    rawEmail: email
                )
                newHints[index] = updated
                resolvedAny = true
            }
        }
        if resolvedAny {
            let updatedItem = EvidenceItem(
                id: current.id,
                state: current.state,
                sourceUID: current.sourceUID,
                source: current.source,
                occurredAt: current.occurredAt,
                title: current.title,
                snippet: current.snippet,
                bodyText: current.bodyText,
                participantHints: newHints,
                signals: current.signals,
                proposedLinks: current.proposedLinks,
                linkedPeople: current.linkedPeople,
                linkedContexts: current.linkedContexts
            )
            self.store.upsert(updatedItem)
        }
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
    let item: EvidenceItem
    @Binding var showFullText: Bool
    @Binding var selectedFilter: LinkSuggestionStatus
    @Binding var alertMessage: String?
    @Binding var pendingContactPrompt: InboxDetailView.PendingContactPrompt?

    let peopleStore: MockPeopleRuntimeStore
    let contextStore: MockContextRuntimeStore

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
            peopleStore: peopleStore,
            contextStore: contextStore,
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
        ToolbarItemGroup {
            Toggle(isOn: $showFullText) {
                Image(systemName: showFullText ? "doc.text" : "text.quote")
            }
            .toggleStyle(.button)
            .help(showFullText ? "Show full text" : "Show snippet")

            Button(action: onMarkDone) {
                Label("Mark Done", systemImage: "checkmark.circle")
            }
            .buttonStyle(.glass)
            .help("Mark this evidence as reviewed")
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

