//
//  PeopleListView.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import SwiftData
#if canImport(Contacts)
import Contacts
#endif

// MARK: - People List View

struct PeopleListView: View {
    @Binding var selectedPersonID: UUID?
    @AppStorage("sam.people.searchText") private var searchText: String = ""
    @AppStorage("sam.people.filter") private var filterRaw: String = PeopleFilter.all.rawValue
    @State private var showingNewPersonSheet = false
    
    private var filter: PeopleFilter {
        get { PeopleFilter(rawValue: filterRaw) ?? .all }
        set { filterRaw = newValue.rawValue }
    }

    /// The person whose unlinked badge was tapped; drives LinkContactSheet.
    @State private var personToLink: PersonListItemModel? = nil
    
    /// Contact sync manager for validating linked contacts.
    @State private var contactsSyncManager = ContactsSyncManager()
    
    /// Show a banner when contacts are auto-unlinked.
    @State private var showContactSyncBanner = false

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\SamPerson.displayName, comparator: .localizedStandard)])
    private var people: [SamPerson]
    
    var body: some View {
        ZStack(alignment: .top) {
            listContent
            
            // Show banner when contacts were auto-unlinked
            if showContactSyncBanner && contactsSyncManager.lastClearedCount > 0 {
                ContactSyncStatusView(
                    clearedCount: contactsSyncManager.lastClearedCount,
                    onDismiss: { showContactSyncBanner = false }
                )
                .padding(.top, 8)
                .zIndex(100)
            }
        }
    }
    
    private var listContent: some View {
        List(filteredListItems, selection: $selectedPersonID) { item in
            PersonRow(person: item) {
                // Unlinked-badge tapped → open the linking flow.
                personToLink = item
            }
            .tag(item.id as UUID?)
        }
        .navigationTitle("People")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search people")
        .toolbar {
            ToolbarItemGroup {
                Picker("Filter", selection: Binding(
                    get: { filter },
                    set: { filterRaw = $0.rawValue }
                )) {
                    ForEach(PeopleFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .help("Filter people")
                
                Button {
                    showingNewPersonSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .help("New Person")
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        // ── New-person sheet ──────────────────────────────────
        .sheet(isPresented: $showingNewPersonSheet) {
            NewPersonSheet(
                existingCandidates: duplicateCandidates,
                onCreate: { draft in
                    let new = SamPerson(
                        id: UUID(),
                        displayName: draft.fullName,
                        roleBadges: draft.rolePreset.roleBadges,
                        contactIdentifier: draft.contactIdentifier,
                        email: draft.email,
                        consentAlertsCount: 0,
                        reviewAlertsCount: 0
                    )
                    modelContext.insert(new)
                    do {
                        try modelContext.save()
                    } catch {
                        // Optional: handle error (e.g., toast/alert)
                    }
                    selectedPersonID = new.id
                },
                onOpenExisting: { existingID in
                    selectedPersonID = existingID
                }
            )
        }

        // ── Link-contact sheet (driven by the unlinked badge) ─
        .sheet(item: $personToLink) { target in
            LinkContactSheet(
                person: target,
                existingCandidates: duplicateCandidates,
                onLinked: { identifier in
                    // Persist the resolved contactIdentifier.
                    linkPerson(target.id, to: identifier)
                },
                onMerge: { survivingID in
                    // Merge target into the surviving person.
                    mergePerson(target.id, into: survivingID)
                }
            )
        }

        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        .task {
            // Start observing Contacts changes when the view appears.
            contactsSyncManager.startObserving(modelContext: modelContext)
            autoSelectIfNeeded()
        }
        .onChange(of: contactsSyncManager.lastClearedCount) { oldValue, newValue in
            // Show banner when contacts are cleared (but not on initial load)
            if newValue > 0 && oldValue != newValue {
                showContactSyncBanner = true
                
                // Auto-dismiss after configured delay
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(ContactSyncConfiguration.bannerAutoDismissDelay))
                    showContactSyncBanner = false
                }
            }
        }
        .onChange(of: searchText) { _, _ in
            // If the current selection is still visible under the new query, keep it.
            // Otherwise clear so the detail pane shows the placeholder until the user picks.
            if let current = selectedPersonID,
               !filteredListItems.contains(where: { $0.id == current }) {
                selectedPersonID = nil
            }
        }
        .onChange(of: filterRaw) { _, _ in
            // Clear selection if it's no longer visible after filter change
            if let current = selectedPersonID,
               !filteredListItems.contains(where: { $0.id == current }) {
                selectedPersonID = nil
            }
        }
    }
    
    private var listItems: [PersonListItemModel] {
        people.map { p in
            PersonListItemModel(
                id: p.id,
                displayName: p.displayName,
                roleBadges: p.roleBadges,
                consentAlertsCount: p.consentAlertsCount,
                reviewAlertsCount: p.reviewAlertsCount,
                contactIdentifier: p.contactIdentifier
            )
        }
    }

    private var duplicateCandidates: [PersonDuplicateCandidate] {
        listItems.map { p in
            PersonDuplicateCandidate(
                id: p.id,
                displayName: p.displayName,
                addressLine: nil,
                phoneLine: nil,
                contactIdentifier: p.contactIdentifier
            )
        }
    }

    private var filteredListItems: [PersonListItemModel] {
        let items = listItems
        
        // Apply category filter first
        let categoryFiltered: [PersonListItemModel]
        switch filter {
        case .all:
            categoryFiltered = items
        case .clients:
            categoryFiltered = items.filter { $0.roleBadges.contains("Client") }
        case .prospects:
            categoryFiltered = items.filter { $0.roleBadges.contains("Prospect") }
        case .partners:
            categoryFiltered = items.filter { $0.roleBadges.contains("Partner") }
        case .vendors:
            categoryFiltered = items.filter { $0.roleBadges.contains("Vendor") }
        case .recruits:
            categoryFiltered = items.filter { $0.roleBadges.contains("Recruit") }
        }
        
        // Then apply search filter
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return categoryFiltered }
        return categoryFiltered.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.roleBadges.joined(separator: " ").lowercased().contains(q)
        }
    }
    
    private func autoSelectIfNeeded() {
        guard selectedPersonID == nil else { return }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return }
        let pool = filteredListItems.isEmpty ? listItems : filteredListItems
        guard let best = pool.max(by: { score($0) < score($1) }) else { return }
        selectedPersonID = score(best) > 0 ? best.id : pool.first?.id
    }
    
    private func score(_ p: PersonListItemModel) -> Int {
        p.consentAlertsCount * 3 + p.reviewAlertsCount * 2
    }

    // ── Link / Merge helpers ─────────────────────────────────────

    /// Write a resolved CNContact identifier onto the target person.
    private func linkPerson(_ personID: UUID, to identifier: String) {
        guard let person = people.first(where: { $0.id == personID }) else { return }
        person.contactIdentifier = identifier
        do { try modelContext.save() } catch { /* log */ }
    }

    /// Merge *sourceID* into *survivingID*.
    ///
    /// Minimal merge policy:
    ///   • The surviving person keeps all of its own data.
    ///   • Participations, coverages, consent requirements, etc. that
    ///     pointed at the source are re-pointed at the survivor.
    ///   • The survivor's displayName is updated from Contacts if it has a contactIdentifier.
    ///   • The source row is deleted.
    ///
    /// This is the minimum viable merge.  Richer conflict-resolution
    /// (e.g. combining role badges, deduplicating participations in
    /// the same context) can be layered on top later.
    private func mergePerson(_ sourceID: UUID, into survivingID: UUID) {
        guard let source   = people.first(where: { $0.id == sourceID }),
              let survivor = people.first(where: { $0.id == survivingID }) else { return }

        // Re-point participations
        for p in source.participations {
            p.person = survivor
            if !survivor.participations.contains(where: { $0.id == p.id }) {
                survivor.participations.append(p)
            }
        }

        // Re-point coverages
        for c in source.coverages {
            c.person = survivor
            if !survivor.coverages.contains(where: { $0.id == c.id }) {
                survivor.coverages.append(c)
            }
        }

        // Re-point consent requirements
        for cr in source.consentRequirements {
            cr.person = survivor
            if !survivor.consentRequirements.contains(where: { $0.id == cr.id }) {
                survivor.consentRequirements.append(cr)
            }
        }

        // Re-point responsibilities (both directions)
        for r in source.responsibilitiesAsGuardian {
            r.guardian = survivor
            if !survivor.responsibilitiesAsGuardian.contains(where: { $0.id == r.id }) {
                survivor.responsibilitiesAsGuardian.append(r)
            }
        }
        for r in source.responsibilitiesAsDependent {
            r.dependent = survivor
            if !survivor.responsibilitiesAsDependent.contains(where: { $0.id == r.id }) {
                survivor.responsibilitiesAsDependent.append(r)
            }
        }

        // Adopt contactIdentifier if the survivor doesn't already have one
        if survivor.contactIdentifier == nil, let ci = source.contactIdentifier {
            survivor.contactIdentifier = ci
        }
        
        // Fetch fresh name from Contacts if survivor is linked
        if let identifier = survivor.contactIdentifier {
            let survivorID = survivor.id
            Task(priority: .userInitiated) {
                let freshName = await Self.fetchContactName(identifier)
                await MainActor.run {
                    if let name = freshName,
                       let refreshed = people.first(where: { $0.id == survivorID }) {
                        refreshed.displayName = name
                    }
                    // Save is handled below after all sync operations
                }
            }
        }

        // Merge alert counters (additive)
        survivor.consentAlertsCount += source.consentAlertsCount
        survivor.reviewAlertsCount  += source.reviewAlertsCount

        // Merge context chips (deduplicate by id)
        for chip in source.contextChips {
            if !survivor.contextChips.contains(where: { $0.id == chip.id }) {
                survivor.contextChips.append(chip)
            }
        }

        // Delete the source
        modelContext.delete(source)

        do { try modelContext.save() } catch { /* log */ }

        // If the deleted person was selected, pivot to the survivor.
        if selectedPersonID == sourceID {
            selectedPersonID = survivingID
        }
    }
    
    // MARK: - Contact Name Fetching
    
    /// Fetch the current display name from Contacts for a given identifier.
    /// Returns nil if the contact can't be found or accessed.
    private static func fetchContactName(_ identifier: String) async -> String? {
        #if canImport(Contacts)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let store = CNContactStore()
                do {
                    let keys: [CNKeyDescriptor] = [
                        CNContactGivenNameKey as CNKeyDescriptor,
                        CNContactFamilyNameKey as CNKeyDescriptor
                    ]
                    let contact = try store.unifiedContact(
                        withIdentifier: identifier,
                        keysToFetch: keys
                    )
                    
                    // Build display name (first + last)
                    let fullName = [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    
                    continuation.resume(returning: fullName.isEmpty ? nil : fullName)
                } catch {
                    // Contact not found or access denied
                    continuation.resume(returning: nil)
                }
            }
        }
        #else
        return nil
        #endif
    }
}

