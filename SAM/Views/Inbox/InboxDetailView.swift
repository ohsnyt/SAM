//
//  InboxDetailView.swift
//  SAM_crm
//
//  Created on February 11, 2026.
//  Phase F: Inbox (Evidence Triage UI)
//
//  Detail view for a single evidence item showing content,
//  participants, signals, linked entities, and triage actions.
//

import SwiftUI
import SwiftData

struct InboxDetailView: View {

    // MARK: - Properties

    let item: SamEvidenceItem

    // MARK: - Dependencies

    @State private var repository = EvidenceRepository.shared
    @State private var notesRepository = NotesRepository.shared

    /// @Query triggers SwiftUI re-render when SamPerson records change in the store.
    @Query private var allPeople: [SamPerson]

    // MARK: - State

    @State private var showingDeleteConfirmation = false
    @State private var editingNote: SamNote?

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerSection
                    .padding(.horizontal)
                    .padding(.top)

                contentSection

                if !item.participantHints.isEmpty {
                    participantsSection
                }

                if !item.signals.isEmpty {
                    signalsSection
                }

                if !item.linkedPeople.isEmpty {
                    linkedPeopleSection
                }

                if !item.linkedContexts.isEmpty {
                    linkedContextsSection
                }

                metadataSection
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup {
                // Attach note
                Button {
                    createAndEditNote()
                } label: {
                    Label("Attach Note", systemImage: "note.text.badge.plus")
                }
                .help("Attach a note to this evidence")
                
                // Primary: triage toggle
                Button {
                    toggleTriageState()
                } label: {
                    if item.state == .needsReview {
                        Label("Mark as Reviewed", systemImage: "checkmark.circle")
                    } else {
                        Label("Mark as Needs Review", systemImage: "arrow.uturn.backward.circle")
                    }
                }
                .help(item.state == .needsReview ? "Mark as Reviewed" : "Mark as Needs Review")

                // Menu: delete
                Menu {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingNote) { note in
            NoteEditorView(note: note) {
                // Note saved
            }
        }
        .confirmationDialog(
            "Delete Evidence",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteItem()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete \"\(item.title)\"? This action cannot be undone.")
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text(item.title)
                .font(.system(size: 28, weight: .bold))

            // Source and state badges
            HStack(spacing: 8) {
                // Source badge
                Label(item.source.rawValue, systemImage: sourceIcon)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(sourceColor.opacity(0.15))
                    .foregroundStyle(sourceColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                // State badge
                Text(item.state == .needsReview ? "Needs Review" : "Reviewed")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stateColor.opacity(0.15))
                    .foregroundStyle(stateColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Date
            Text(item.occurredAt, format: .dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        let text = item.bodyText ?? item.snippet
        if !text.isEmpty {
            section(title: "Content") {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Participants Section

    /// Participants excluding the Me contact
    private var visibleParticipants: [ParticipantHint] {
        let meEmails = Set(allPeople.first(where: \.isMe)?.emailAliases.map { $0.lowercased() } ?? [])
        guard !meEmails.isEmpty else { return item.participantHints }
        return item.participantHints.filter { hint in
            guard let email = hint.rawEmail?.lowercased() else { return true }
            return !meEmails.contains(email)
        }
    }

    private var participantsSection: some View {
        section(title: "Participants") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleParticipants.enumerated()), id: \.offset) { _, participant in
                    let status = participantStatus(for: participant)
                    HStack(spacing: 8) {
                        // Green checkmark if person is in SAM (known), grey otherwise
                        if status.isKnown {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Image(systemName: "person.circle")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }

                        // Name
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(participant.displayName)
                                    .font(.body)

                                if participant.isOrganizer {
                                    Text("Organizer")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.2))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }

                                if let matched = status.matchedPerson {
                                    NotInContactsCapsule(person: matched)
                                } else if !status.isKnown {
                                    NotInContactsCapsule(
                                        name: participant.displayName,
                                        email: participant.rawEmail
                                    )
                                }
                            }

                            if let email = participant.rawEmail {
                                Text(email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// Compute participant status live from the @Query people list.
    private func participantStatus(for participant: ParticipantHint) -> ParticipantHint.Status {
        participant.status(against: allPeople)
    }

    // MARK: - Signals Section

    private var signalsSection: some View {
        section(title: "Signals") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(item.signals) { signal in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(signal.type.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.indigo.opacity(0.2))
                                .foregroundStyle(.indigo)
                                .clipShape(Capsule())

                            Text(signal.message)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text("\(Int(signal.confidence * 100))%")
                            .font(.caption)
                            .foregroundStyle(.green.opacity(0.7))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Linked People Section

    private var linkedPeopleSection: some View {
        section(title: "Linked People") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(item.linkedPeople, id: \.id) { person in
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.secondary)

                        Text(person.displayNameCache ?? person.displayName)
                            .font(.body)

                        Spacer()

                        if !person.roleBadges.isEmpty {
                            ForEach(person.roleBadges, id: \.self) { badge in
                                Text(badge)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.2))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Linked Contexts Section

    private var linkedContextsSection: some View {
        section(title: "Linked Contexts") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(item.linkedContexts, id: \.id) { context in
                    HStack(spacing: 8) {
                        Image(systemName: "building.2")
                            .foregroundStyle(.secondary)

                        Text(context.name)
                            .font(.body)

                        Spacer()

                        Text(context.kind.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.2))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        section(title: "Metadata") {
            VStack(alignment: .leading, spacing: 8) {
                metadataRow(label: "Source", value: item.source.rawValue)
                metadataRow(label: "State", value: item.state == .needsReview ? "Needs Review" : "Done")

                if let sourceUID = item.sourceUID {
                    metadataRow(label: "Source UID", value: sourceUID)
                }

                metadataRow(label: "ID", value: item.id.uuidString)
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.caption)
                .textSelection(.enabled)

            Spacer()
        }
    }

    // MARK: - Section Helper

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 6)

            Divider()
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Computed Properties

    private var sourceIcon: String {
        switch item.source {
        case .calendar: return "calendar"
        case .mail: return "envelope"
        case .contacts: return "person.crop.circle"
        case .note: return "note.text"
        case .manual: return "square.and.pencil"
        case .iMessage: return "message"
        case .phoneCall: return "phone"
        case .faceTime: return "video"
        }
    }

    private var sourceColor: Color {
        switch item.source {
        case .calendar: return .red
        case .mail: return .blue
        case .contacts: return .green
        case .note: return .orange
        case .manual: return .purple
        case .iMessage: return .teal
        case .phoneCall: return .green
        case .faceTime: return .mint
        }
    }

    private var stateColor: Color {
        item.state == .needsReview ? .orange : .green
    }

    // MARK: - Actions

    private func createAndEditNote() {
        do {
            let note = try notesRepository.create(
                content: "",
                linkedEvidenceIDs: [item.id]
            )
            editingNote = note
        } catch {
            // Non-critical — user can create note from person/context detail instead
        }
    }

    private func toggleTriageState() {
        do {
            if item.state == .needsReview {
                try repository.markAsReviewed(item: item)
            } else {
                try repository.markAsNeedsReview(item: item)
            }
        } catch {
            // Triage toggle error — state will revert on next load
        }
    }

    private func deleteItem() {
        do {
            try repository.delete(item: item)
        } catch {
            // Delete error — item will reappear on next load
        }
    }
}

// MARK: - Preview

#Preview {
    let container = SAMModelContainer.shared
    EvidenceRepository.shared.configure(container: container)
    let context = ModelContext(container)

    let item = SamEvidenceItem(
        id: UUID(),
        state: .needsReview,
        sourceUID: "eventkit:abc123",
        source: .calendar,
        occurredAt: Date(),
        title: "Annual Review - Smith Family",
        snippet: "Discuss portfolio rebalancing, beneficiary updates, and new life insurance policy",
        bodyText: "Full meeting notes would appear here. This is a longer form text that contains all the details from the calendar event, including any notes the user has added.",
        participantHints: [
            ParticipantHint(displayName: "John Smith", isOrganizer: true, isVerified: true, rawEmail: "john@smith.com"),
            ParticipantHint(displayName: "Jane Smith", isOrganizer: false, isVerified: true, rawEmail: "jane@smith.com"),
            ParticipantHint(displayName: "Unknown Attendee", isOrganizer: false, isVerified: false, rawEmail: "unknown@example.com")
        ],
        signals: [
            EvidenceSignal(type: .financialEvent, message: "Annual portfolio review detected", confidence: 0.92),
            EvidenceSignal(type: .lifeEvent, message: "Beneficiary update may indicate family change", confidence: 0.65)
        ]
    )

    context.insert(item)
    try? context.save()

    return NavigationStack {
        InboxDetailView(item: item)
            .modelContainer(container)
    }
    .frame(width: 700, height: 800)
}

