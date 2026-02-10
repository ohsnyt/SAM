import SwiftUI
import SwiftUI
import SwiftData
import Contacts

// MARK: - Main Scroll Content
struct DetailScrollContent: View {
    let item: SamEvidenceItem
    @Binding var showFullText: Bool
    @Binding var selectedFilter: LinkSuggestionStatus
    @Binding var alertMessage: String?
    @Binding var pendingContactPrompt: InboxDetailView.PendingContactPrompt?

    let onMarkDone: () -> Void
    let onReopen: () -> Void

    let onAcceptSuggestion: (UUID) -> Void
    let onDeclineSuggestion: (UUID) -> Void
    let onRemoveConfirmedLink: (EvidenceLinkTarget, UUID, LinkSuggestionStatus) -> Void
    let onResetSuggestion: (UUID) -> Void
    let onSuggestCreateContact: (String, String, String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeaderSection(item: item)
                
                // Display LLM analysis for note-based evidence
                if item.source == .note,
                   let noteID = item.sourceUID,
                   let noteUUID = UUID(uuidString: noteID) {
                    NoteArtifactDisplay(noteID: noteUUID, item: item, onSuggestCreateContact: onSuggestCreateContact)
                }
                
                EvidenceSection(item: item, showFullText: showFullText)
                ParticipantsSection(item: item, alertMessage: $alertMessage, onSuggestCreateContact: onSuggestCreateContact)
                SignalsSection(item: item)
                ConfirmedLinksSection(item: item, onRemoveConfirmedLink: onRemoveConfirmedLink)
                SuggestedLinksSection(
                    item: item,
                    selectedFilter: $selectedFilter,
                    onAcceptSuggestion: onAcceptSuggestion,
                    onDeclineSuggestion: onDeclineSuggestion,
                    onRemoveConfirmedLink: onRemoveConfirmedLink,
                    onResetSuggestion: onResetSuggestion
                )
                ActionsRow(state: item.state, onMarkDone: onMarkDone, onReopen: onReopen)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 760, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Sections
struct HeaderSection: View {
    let item: SamEvidenceItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.title2)
                    .bold()
                Spacer()
                Text(formatDate(item.occurredAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Label(item.source.title, systemImage: item.source.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.state == .needsReview {
                    Label("Needs Review", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Done", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

struct EvidenceSection: View {
    let item: SamEvidenceItem
    let showFullText: Bool
    var body: some View {
        GroupBox("Evidence") {
            if showFullText, let bodyText = item.bodyText, !bodyText.isEmpty {
                Text(bodyText)
                    .textSelection(.enabled)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                Text(item.snippet)
                    .textSelection(.enabled)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }
}

struct ParticipantsSection: View {
    let item: SamEvidenceItem
    @Binding var alertMessage: String?
    let onSuggestCreateContact: (String, String, String) -> Void
    var body: some View {
        if !item.participantHints.isEmpty {
            GroupBox("Participants") {
                VStack(alignment: .leading, spacing: 6) {
                    let sorted = item.participantHints.sorted {
                        if $0.isOrganizer != $1.isOrganizer { return $0.isOrganizer }
                        return false
                    }
                    ForEach(sorted) { hint in
                        ParticipantRow(hint: hint, alertMessage: $alertMessage) { first, last, email in
                            onSuggestCreateContact(first, last, email)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct SignalsSection: View {
    let item: SamEvidenceItem
    var body: some View {
        if !item.signals.isEmpty {
            GroupBox("Signals") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.signals) { s in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.kind.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.kind.title)
                                    .font(.headline)
                                Text(s.reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Text("Confidence: \(Int((s.confidence * 100).rounded()))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct SuggestedLinksSection: View {
    let item: SamEvidenceItem
    @Binding var selectedFilter: LinkSuggestionStatus

    let onAcceptSuggestion: (UUID) -> Void
    let onDeclineSuggestion: (UUID) -> Void
    let onRemoveConfirmedLink: (EvidenceLinkTarget, UUID, LinkSuggestionStatus) -> Void
    let onResetSuggestion: (UUID) -> Void

    var body: some View {
        GroupBox("Suggested Links") {
            if item.proposedLinks.isEmpty {
                Text("No suggestions yet. Attach this evidence to a person or context manually.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(LinkSuggestionStatus.allCases, id: \.self) { status in
                            Text(filterTitle(status, for: item)).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)

                    if isEmptyForSelectedFilter(item) {
                        Text(emptyFilterMessage(for: selectedFilter))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    } else {
                        let visible = item.proposedLinks
                            .filter { $0.status == selectedFilter }
                            .sorted { $0.confidence > $1.confidence }
                        let people = visible.filter { $0.target == .person }
                        let contexts = visible.filter { $0.target == .context }
                        if !people.isEmpty {
                            Text("People")
                                .font(.headline)
                            ForEach(people) { link in
                                SuggestedLinkRow(
                                    title: link.displayName,
                                    subtitle: link.secondaryLine,
                                    confidence: link.confidence,
                                    reason: link.reason,
                                    systemImage: "person.crop.circle",
                                    status: link.status,
                                    decidedAt: link.decidedAt,
                                    primaryActionTitle: primaryTitle(for: link),
                                    onPrimary: { primaryAction(for: item, link: link) },
                                    actionsMenu: {
                                        Menu {
                                            suggestionContextMenu(item: item, link: link)
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .imageScale(.medium)
                                        }
                                        .menuStyle(.borderlessButton)
                                        .buttonStyle(.plain)
                                        .help("Actions")
                                    }
                                )
                                .contextMenu {
                                    suggestionContextMenu(item: item, link: link)
                                }
                            }
                        }
                        if !contexts.isEmpty {
                            if !people.isEmpty { Divider().padding(.vertical, 6) }
                            Text("Contexts")
                                .font(.headline)
                            ForEach(contexts) { link in
                                SuggestedLinkRow(
                                    title: link.displayName,
                                    subtitle: link.secondaryLine,
                                    confidence: link.confidence,
                                    reason: link.reason,
                                    systemImage: "square.3.layers.3d",
                                    status: link.status,
                                    decidedAt: link.decidedAt,
                                    primaryActionTitle: primaryTitle(for: link),
                                    onPrimary: { primaryAction(for: item, link: link) },
                                    actionsMenu: {
                                        Menu {
                                            suggestionContextMenu(item: item, link: link)
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .imageScale(.medium)
                                        }
                                        .menuStyle(.borderlessButton)
                                        .buttonStyle(.plain)
                                        .help("Actions")
                                    }
                                )
                                .contextMenu {
                                    suggestionContextMenu(item: item, link: link)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func filterTitle(_ status: LinkSuggestionStatus, for item: SamEvidenceItem) -> String {
        let count = item.proposedLinks.filter { $0.status == status }.count
        return count > 0 ? "\(status.title) (\(count))" : status.title
    }

    private func isEmptyForSelectedFilter(_ item: SamEvidenceItem) -> Bool {
        item.proposedLinks.first(where: { $0.status == selectedFilter }) == nil
    }

    private func emptyFilterMessage(for status: LinkSuggestionStatus) -> String {
        switch status {
        case .pending: return "No pending suggestions for this evidence item."
        case .accepted: return "No accepted suggestions yet. Accept a suggestion to confirm a link."
        case .declined: return "No declined suggestions. Decline a suggestion if it’s irrelevant."
        }
    }

    private func primaryTitle(for link: ProposedLink) -> String {
        switch link.status {
        case .pending: return "Accept"
        case .accepted: return "Unlink"
        case .declined: return "Reset"
        }
    }

    private func primaryAction(for item: SamEvidenceItem, link: ProposedLink) {
        switch link.status {
        case .pending:
            onAcceptSuggestion(link.id)
        case .accepted:
            onRemoveConfirmedLink(link.target, link.targetID, .pending)
        case .declined:
            onResetSuggestion(link.id)
        }
    }

    @ViewBuilder
    private func suggestionContextMenu(item: SamEvidenceItem, link: ProposedLink) -> some View {
        switch link.status {
        case .pending:
            Button("Accept") { onAcceptSuggestion(link.id) }
            Button("Decline") { onDeclineSuggestion(link.id) }
        case .accepted:
            Button(role: .destructive) { onRemoveConfirmedLink(link.target, link.targetID, .pending) } label: { Text("Unlink") }
            Button("Decline Suggestion") { onRemoveConfirmedLink(link.target, link.targetID, .declined) }
        case .declined:
            Button("Reset to Pending") { onResetSuggestion(link.id) }
        }
    }
}

struct ConfirmedLinksSection: View {
    let item: SamEvidenceItem
    let onRemoveConfirmedLink: (EvidenceLinkTarget, UUID, LinkSuggestionStatus) -> Void

    @Query private var people: [SamPerson]
    @Query private var contexts: [SamContext]

    init(
        item: SamEvidenceItem,
        onRemoveConfirmedLink: @escaping (EvidenceLinkTarget, UUID, LinkSuggestionStatus) -> Void
    ) {
        self.item = item
        self.onRemoveConfirmedLink = onRemoveConfirmedLink

        let linkedPeopleIDs = Set(item.linkedPeople.map { $0.id })
        if linkedPeopleIDs.isEmpty {
            _people = Query()
        } else {
            _people = Query(filter: #Predicate<SamPerson> { linkedPeopleIDs.contains($0.id) })
        }

        let linkedContextIDs = Set(item.linkedContexts.map { $0.id })
        if linkedContextIDs.isEmpty {
            _contexts = Query()
        } else {
            _contexts = Query(filter: #Predicate<SamContext> { linkedContextIDs.contains($0.id) })
        }
    }

    var body: some View {
        GroupBox("Confirmed Links") {
            if item.linkedPeople.isEmpty && item.linkedContexts.isEmpty {
                Text("Nothing attached yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !item.linkedPeople.isEmpty {
                        Text("People")
                            .font(.headline)
                        ForEach(item.linkedPeople, id: \.id) { p in
                            let name = p.displayName
                            HStack {
                                Label(name, systemImage: "person.crop.circle")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button(role: .destructive) {
                                    onRemoveConfirmedLink(.person, p.id, .pending)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove link")
                                .contextMenu {
                                    Button("Remove & Decline Suggestion") {
                                        onRemoveConfirmedLink(.person, p.id, .declined)
                                    }
                                }
                            }
                        }
                    }
                    if !item.linkedContexts.isEmpty {
                        if !item.linkedPeople.isEmpty { Divider().padding(.vertical, 6) }
                        Text("Contexts")
                            .font(.headline)
                        ForEach(item.linkedContexts, id: \.id) { c in
                            let name = c.name
                            HStack {
                                Label(name, systemImage: "square.3.layers.3d")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button(role: .destructive) {
                                    onRemoveConfirmedLink(.context, c.id, .pending)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove link")
                                .contextMenu {
                                    Button("Remove & Decline Suggestion") {
                                        onRemoveConfirmedLink(.context, c.id, .declined)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ActionsRow: View {
    let state: EvidenceTriageState
    let onMarkDone: () -> Void
    let onReopen: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(action: onMarkDone) {
                Label("Mark Done", systemImage: "checkmark.circle")
            }
            .buttonStyle(.glass)
            .disabled(state == .done)
            Button(action: onReopen) {
                Label("Reopen", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.glass)
            .disabled(state == .needsReview)
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Note Artifact Display
/// Displays the analysis artifact for a given note-based evidence item
private struct NoteArtifactDisplay: View {
    let noteID: UUID
    let item: SamEvidenceItem
    let onSuggestCreateContact: (String, String, String) -> Void
    
    @Query private var notes: [SamNote]
    @State private var showAddRelationship = false
    @State private var pendingPerson: StoredPersonEntity?
    @State private var targetParent: SamPerson?
    @State private var successMessage: String?
    @State private var errorMessage: String?
    
    init(noteID: UUID, item: SamEvidenceItem, onSuggestCreateContact: @escaping (String, String, String) -> Void) {
        self.noteID = noteID
        self.item = item
        self.onSuggestCreateContact = onSuggestCreateContact
        // Query for the specific note
        _notes = Query(
            filter: #Predicate<SamNote> { $0.id == noteID },
            sort: \SamNote.createdAt
        )
    }
    
    private var note: SamNote? {
        notes.first { $0.id == noteID }
    }
    
    private var artifact: SamAnalysisArtifact? {
        note?.analysisArtifact
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if let artifact = artifact {
                AnalysisArtifactCard(artifact: artifact) { person in
                    handlePersonAction(person)
                }
            }
            
            // Success/Error banners
            if let success = successMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(success)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") {
                        withAnimation {
                            successMessage = nil
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(.green.opacity(0.1))
                .cornerRadius(8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") {
                        withAnimation {
                            errorMessage = nil
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(.red.opacity(0.1))
                .cornerRadius(8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showAddRelationship) {
            if let person = pendingPerson, let parent = targetParent {
                AddRelationshipSheet(
                    parentPerson: parent,
                    suggestedName: person.name,
                    suggestedLabel: relationshipLabel(from: person.relationship),
                    onAdd: { name, label in
                        addToFamily(name: name, label: label, parent: parent)
                        showAddRelationship = false
                    },
                    onCancel: {
                        showAddRelationship = false
                        pendingPerson = nil
                        targetParent = nil
                    }
                )
            }
        }
    }
    
    private func handlePersonAction(_ person: StoredPersonEntity) {
        // Detect if person is a dependent
        if isDependent(person.relationship),
           let parent = item.linkedPeople.first {
            // Show editable relationship sheet
            pendingPerson = person
            targetParent = parent
            showAddRelationship = true
        } else {
            // Fallback: Create separate contact
            let components = person.name.split(separator: " ", maxSplits: 1)
            let firstName = components.first.map(String.init) ?? person.name
            let lastName = components.count > 1 ? String(components[1]) : ""
            onSuggestCreateContact(firstName, lastName, "")
        }
    }
    
    private func isDependent(_ relationship: String?) -> Bool {
        guard let rel = relationship?.lowercased() else { return false }
        return rel.contains("son") ||
               rel.contains("daughter") ||
               rel.contains("child") ||
               rel.contains("dependent")
    }
    
    private func relationshipLabel(from relationship: String?) -> String {
        guard let rel = relationship?.lowercased() else {
            return CNLabelContactRelationChild
        }
        
        if rel.contains("son") && !rel.contains("step") {
            return CNLabelContactRelationSon
        } else if rel.contains("daughter") && !rel.contains("step") {
            return CNLabelContactRelationDaughter
        } else if rel.contains("step-son") || rel.contains("stepson") {
            return "step-son"
        } else if rel.contains("step-daughter") || rel.contains("stepdaughter") {
            return "step-daughter"
        } else if rel.contains("child") {
            return CNLabelContactRelationChild
        } else if rel.contains("dependent") {
            return "dependent"
        }
        
        return CNLabelContactRelationChild
    }
    
    private func addToFamily(name: String, label: String, parent: SamPerson) {
        Task {
            do {
                try ContactSyncService.shared.addRelationship(
                    name: name,
                    label: label,
                    to: parent
                )
                
                withAnimation {
                    successMessage = "Added \(name) to \(parent.displayNameCache ?? "contact")'s family in Contacts"
                }
                
                // Auto-dismiss success after 5 seconds
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation {
                        successMessage = nil
                    }
                }
            } catch {
                withAnimation {
                    errorMessage = "Failed to add family member: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func applyAllSuggestions(_ actions: SuggestionActions) {
        Task {
            do {
                // 1. Add family members to contacts
                for update in actions.contactUpdates {
                    try await MainActor.run {
                        try ContactSyncService.shared.addRelationship(
                            name: update.personName,
                            label: relationshipLabel(from: update.relationship),
                            to: update.targetPerson
                        )
                    }
                }
                
                // 2. Update summary note
                if let noteText = actions.noteUpdate,
                   let person = item.linkedPeople.first {
                    try await MainActor.run {
                        try ContactSyncService.shared.updateSummaryNote(noteText, for: person)
                    }
                }
                
                // Success feedback
                await MainActor.run {
                    withAnimation {
                        let contactCount = actions.contactUpdates.count
                        let noteAdded = actions.noteUpdate != nil
                        
                        var parts: [String] = []
                        if contactCount > 0 {
                            parts.append("\(contactCount) family member(s) added")
                        }
                        if noteAdded {
                            parts.append("Summary note updated")
                        }
                        
                        successMessage = "✅ " + parts.joined(separator: ", ")
                    }
                }
                
                // Auto-dismiss after 5 seconds
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await MainActor.run {
                        withAnimation {
                            successMessage = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        errorMessage = "Failed to apply suggestions: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private func openInContacts(_ identifier: String?) {
        guard let identifier = identifier else { return }
        #if os(macOS)
        let url = URL(string: "addressbook://\(identifier)")!
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Suggestion Actions Data Models

/// Actions that can be applied from analyzing a note
struct SuggestionActions {
    let contactUpdates: [ContactUpdate]
    let noteUpdate: String?
    let messages: [SuggestedMessage]
}

struct ContactUpdate {
    enum UpdateType {
        case addFamilyMember
        case updateInfo
    }
    
    let type: UpdateType
    let personName: String
    let relationship: String
    let targetPerson: SamPerson
    let description: String
}

struct SuggestedMessage {
    enum MessageType {
        case sms
        case email
    }
    
    let type: MessageType
    let subject: String?
    let body: String
    let recipient: String
}

struct LifeEvent {
    enum EventType {
        case birth
        case workSuccess
    }
    
    let type: EventType
    let personName: String
    let details: String
}

