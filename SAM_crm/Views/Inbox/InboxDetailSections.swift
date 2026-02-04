import SwiftUI
import SwiftData

// MARK: - Main Scroll Content
struct DetailScrollContent: View {
    let item: SamEvidenceItem
    @Binding var showFullText: Bool
    @Binding var selectedFilter: LinkSuggestionStatus
    @Binding var alertMessage: String?
    @Binding var pendingContactPrompt: InboxDetailView.PendingContactPrompt?

    let peopleStore: MockPeopleRuntimeStore
    let contextStore: MockContextRuntimeStore

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
                EvidenceSection(item: item, showFullText: showFullText)
                ParticipantsSection(item: item, alertMessage: $alertMessage, onSuggestCreateContact: onSuggestCreateContact)
                SignalsSection(item: item)
                ConfirmedLinksSection(item: item, peopleStore: peopleStore, contextStore: contextStore, onRemoveConfirmedLink: onRemoveConfirmedLink)
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
    let peopleStore: MockPeopleRuntimeStore
    let contextStore: MockContextRuntimeStore
    let onRemoveConfirmedLink: (EvidenceLinkTarget, UUID, LinkSuggestionStatus) -> Void
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
                        ForEach(item.linkedPeople, id: \.self) { pid in
                            let name = peopleStore.byID[pid]?.displayName ?? "Unknown Person"
                            HStack {
                                Label(name, systemImage: "person.crop.circle")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button(role: .destructive) {
                                    onRemoveConfirmedLink(.person, pid, .pending)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove link")
                                .contextMenu {
                                    Button("Remove & Decline Suggestion") {
                                        onRemoveConfirmedLink(.person, pid, .declined)
                                    }
                                }
                            }
                        }
                    }
                    if !item.linkedContexts.isEmpty {
                        if !item.linkedPeople.isEmpty { Divider().padding(.vertical, 6) }
                        Text("Contexts")
                            .font(.headline)
                        ForEach(item.linkedContexts, id: \.self) { cid in
                            let name = contextStore.byID[cid]?.name ?? "Unknown Context"
                            HStack {
                                Label(name, systemImage: "square.3.layers.3d")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button(role: .destructive) {
                                    onRemoveConfirmedLink(.context, cid, .pending)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove link")
                                .contextMenu {
                                    Button("Remove & Decline Suggestion") {
                                        onRemoveConfirmedLink(.context, cid, .declined)
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
