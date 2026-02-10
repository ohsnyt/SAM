//
//  LinkContactSheet.swift
//  SAM_crm
//
//  Modal sheet that walks the user through linking an unlinked
//  SamPerson to a CNContact.  Flow:
//
//    ┌─ confirm intent ──────────────────────────────────────┐
//    │  "Would you like to try linking …?"                   │
//    │   No  → dismiss                                       │
//    │   Yes → run duplicate detection                       │
//    └───────────────────────────────────────────────────────┘
//                          │
//            ┌─────────────┴─────────────┐
//            ▼                           ▼
//    duplicates found            no duplicates
//            │                           │
//            ▼                           ▼
//    3-way choice               2-way choice
//      • Merge (adopt the         • Search Contacts
//        duplicate's identifier)  • Create New Contact
//      • Search Contacts
//      • Create New Contact
//
//  Callbacks
//  ─────────
//    onLinked(contactIdentifier)   – persist the resolved identifier
//    onMerge(survivingID)          – caller merges current person into
//                                    survivingID and dismisses
//

#if os(macOS)
import SwiftUI
import Contacts
#if canImport(ContactsUI)
import ContactsUI
#endif

/// The three steps the sheet can be showing at any point.
private enum LinkStep {
    case confirm                     // initial "do you want to try?"
    case resolving                   // duplicate check in progress
    case picker([DuplicateMatch])    // show searchable list (with suggested matches at top)
}

struct LinkContactSheet: View {

    /// The person we are trying to link.
    let person: PersonListItemModel

    /// All current SamPerson rows (for duplicate detection).
    let existingCandidates: [PersonDuplicateCandidate]

    /// Called when a CNContact identifier has been resolved.
    /// The caller is responsible for writing it to SwiftData.
    let onLinked: (String) -> Void

    /// Called when the user chooses to merge into an existing person.
    /// The UUID is the *surviving* row.  Caller handles the merge
    /// and dismisses this sheet.
    let onMerge: (UUID) -> Void

    // ── internal state ──────────────────────────────────────────
    @State private var step: LinkStep = .confirm
    @State private var searchText: String = ""

    /// AppKit anchor for presenting Contacts sheets on macOS.
    @State private var anchorView: NSView?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch step {
            case .confirm:
                confirmView

            case .resolving:
                // Brief spinner while we run the (synchronous but fast) matcher.
                // In practice this resolves on the next frame; kept for clarity.
                ProgressView("Checking for duplicates…")
                    .task { runDuplicateCheck() }

            case .picker(let suggestedMatches):
                pickerView(suggestedMatches: suggestedMatches)
            }
        }
        .padding(24)
        .frame(width: 520, height: 600)
        // Invisible anchor so ContactPresenter can sheet from an NSView.
        .background(PopoverAnchorView(anchorView: $anchorView))
    }

    // ── Step: Confirm ─────────────────────────────────────────────

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link to Contacts")
                .font(.title2)
                .bold()

            Text("\"\(person.displayName)\" is not linked to a contact in the Contacts app.")
                .foregroundStyle(.secondary)

            Text("Would you like to try linking this person to an existing contact, or create a new one?")

            Spacer()

            HStack {
                Button("No, Thanks") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Yes, Let's Link") {
                    step = .resolving
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // ── Step: Duplicate check (runs once, transitions immediately) ─

    private func runDuplicateCheck() {
        let matches = PersonDuplicateMatcher.findMatches(
            for: person.displayName,
            among: existingCandidates,
            threshold: 0.60
        )
        // Filter out the person itself (shouldn't appear, but be safe).
        let filtered = matches.filter { $0.candidate.id != person.id }
        
        // Always show the picker, with suggested matches at the top
        step = .picker(filtered)
    }

    // ── Step: Picker (searchable list with suggested matches at top) ─

    private func pickerView(suggestedMatches: [DuplicateMatch]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Link \"\(person.displayName)\"")
                    .font(.title2)
                    .bold()
                
                Text("Select a linked contact from your SAM group")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)
            
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search contacts", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)
            
            // Contact list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Suggested matches (if any and not filtered by search)
                    if !suggestedMatches.isEmpty && searchText.isEmpty {
                        Text("SUGGESTED MATCHES")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        
                        ForEach(suggestedMatches.prefix(3), id: \.candidate.id) { match in
                            contactRow(
                                candidate: match.candidate,
                                badge: "Match \(Int(match.score * 100))%"
                            )
                        }
                        
                        Divider()
                            .padding(.vertical, 8)
                        
                        Text("ALL CONTACTS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    
                    // All contacts (sorted by last name, filtered by search)
                    ForEach(filteredAndSortedCandidates, id: \.id) { candidate in
                        contactRow(candidate: candidate, badge: nil)
                    }
                    
                    if filteredAndSortedCandidates.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.slash")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("No contacts found")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if !searchText.isEmpty {
                                Text("Try adjusting your search")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            
            Divider()
                .padding(.vertical, 8)
            
            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button {
                    createNewContact()
                } label: {
                    Label("Create New Contact", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }
    
    private func contactRow(candidate: PersonDuplicateCandidate, badge: String?) -> some View {
        Button {
            linkToContact(candidate)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: candidate.contactIdentifier != nil
                      ? "person.crop.circle.fill"
                      : "person.crop.circle")
                    .foregroundStyle(candidate.contactIdentifier != nil ? Color.accentColor : .secondary)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let secondary = candidate.secondaryLine {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if let badge {
                    Text(badge)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
                
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
        )
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    // Filtered and sorted candidate list
    private var filteredAndSortedCandidates: [PersonDuplicateCandidate] {
        let query = searchText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Only show candidates with contactIdentifier (linked contacts)
        let linked = existingCandidates.filter { $0.contactIdentifier != nil && $0.id != person.id }
        
        // Filter by search query
        let filtered: [PersonDuplicateCandidate]
        if query.isEmpty {
            filtered = linked
        } else {
            filtered = linked.filter { candidate in
                candidate.displayName.lowercased().contains(query) ||
                candidate.addressLine?.lowercased().contains(query) == true ||
                candidate.phoneLine?.lowercased().contains(query) == true
            }
        }
        
        // Sort by last name
        return filtered.sorted { a, b in
            let aLast = a.displayName.split(separator: " ").last.map(String.init) ?? a.displayName
            let bLast = b.displayName.split(separator: " ").last.map(String.init) ?? b.displayName
            return aLast.localizedStandardCompare(bLast) == .orderedAscending
        }
    }
    
    private func linkToContact(_ candidate: PersonDuplicateCandidate) {
        guard let identifier = candidate.contactIdentifier else {
            // This shouldn't happen since we filter to linked contacts only,
            // but be defensive.
            return
        }
        
        // If the candidate is a different person (not the one we're linking),
        // this is a merge scenario - the candidate is an existing linked person
        // and we want to merge the current unlinked person into it.
        if candidate.id != person.id {
            // Merge: the candidate is the survivor
            onMerge(candidate.id)
        } else {
            // This shouldn't happen (we filter out self), but just adopt the identifier
            onLinked(identifier)
        }
        
        dismiss()
    }

    // ── Contacts interactions (macOS) ────────────────────────────

    private func createNewContact() {
        let parts = person.displayName.split(separator: " ", maxSplits: 1).map(String.init)
        let first = parts.first ?? person.displayName
        let last  = parts.count > 1 ? parts[1] : ""

        guard let anchor = anchorView else { return }

        let presenter = ContactPresenter()

        // Ensure we have Contacts access before trying to create.
        Task {
            let granted = await presenter.requestAccessIfNeeded()
            guard granted else { return }

            await MainActor.run {
                presenter.presentNewContact(
                    from: anchor,
                    firstName: first,
                    lastName:  last,
                    email:     nil
                ) { success in
                    if success {
                        // The contact was opened in Contacts.app.
                        // The user will create/save it there.  We can't
                        // automatically pick up the new identifier in
                        // real time on macOS (no CNContactPickerViewController),
                        // so we dismiss and prompt a re-link if needed.
                        dismiss()
                    }
                }
            }
        }
    }
}

#endif  // os(macOS)
