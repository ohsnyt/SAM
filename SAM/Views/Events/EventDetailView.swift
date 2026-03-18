//
//  EventDetailView.swift
//  SAM
//
//  Created on March 11, 2026.
//  Event detail — participant list, RSVP management, invitations, and follow-ups.
//

import SwiftUI

struct EventDetailView: View {

    let eventID: UUID
    var onDelete: (() -> Void)?
    @State private var selectedParticipationID: UUID?
    @State private var participantFilter: ParticipantFilter = .all
    @State private var showAddParticipants = false
    @State private var showSocialPromotion = false
    @State private var showInvitationDrafts = false
    @State private var showDeleteConfirmation = false
    @State private var showEditEvent = false
    @State private var showUpdateNotification = false
    @State private var showUpdateSheet = false
    @State private var pendingChangeSummary: EventCoordinator.EventChangeSummary?
    @State private var refreshToken = UUID()
    @State private var lastActionMessage: String?
    @State private var unknownRSVPs: [EventCoordinator.UnknownEventRSVP] = []
    @State private var quickAddRSVP: EventCoordinator.UnknownEventRSVP?

    enum ParticipantFilter: String, CaseIterable {
        case all = "All"
        case accepted = "Accepted"
        case pending = "Pending"
        case declined = "Declined"
        case needsConfirmation = "Needs Review"
    }

    private var event: SamEvent? {
        _ = refreshToken // Force re-evaluation after participant changes
        return try? EventRepository.shared.fetch(id: eventID)
    }

    var body: some View {
        Group {
            if let event {
                HSplitView {
                    participantList(event: event)
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 500, maxHeight: .infinity)
                    participantDetail(event: event)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Event Not Found",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .frame(maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .samRSVPAutoAdded)) { notification in
            // Refresh if the auto-add was for this event
            if let eventIDStr = notification.userInfo?["eventID"] as? String,
               eventIDStr == eventID.uuidString {
                refreshToken = UUID()
                if let name = notification.userInfo?["personName"] as? String,
                   let status = notification.userInfo?["rsvpStatus"] as? String {
                    lastActionMessage = "\(name) was auto-added (\(status) detected from message)"
                }
            }
        }
        .alert("Delete Event?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteEvent()
            }
        } message: {
            Text("This will delete the event and all its participant data. You can undo this for up to 30 days.")
        }
        .alert("Notify Participants?", isPresented: $showUpdateNotification) {
            Button("Send Updates") {
                // showUpdateNotification is already dismissed; show the update sheet
                showUpdateSheet = true
            }
            Button("Skip", role: .cancel) {
                pendingChangeSummary = nil
            }
        } message: {
            Text("Event details changed. Would you like to notify participants who have already been invited?\n\n\(pendingChangeSummary?.changeDescription ?? "")")
        }
        .sheet(isPresented: $showUpdateSheet, onDismiss: {
            pendingChangeSummary = nil
            refreshToken = UUID()
        }) {
            if let event, let changes = pendingChangeSummary {
                EventUpdateSheet(event: event, changes: changes) {
                    refreshToken = UUID()
                }
            }
        }
    }

    // MARK: - Delete

    private func deleteEvent() {
        do {
            try EventRepository.shared.deleteEvent(id: eventID)
            onDelete?()
        } catch {
            lastActionMessage = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Participant List (left)

    private func participantList(event: SamEvent) -> some View {
        VStack(spacing: 0) {
            // Event header
            eventHeader(event: event)

            Divider()

            // Action bar
            actionBar(event: event)

            Divider()

            // Filter bar
            Picker("Filter", selection: $participantFilter) {
                ForEach(ParticipantFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Participant rows
            List(selection: $selectedParticipationID) {
                let participations = filteredParticipations(event: event)
                if participations.isEmpty {
                    ContentUnavailableView(
                        "No Participants",
                        systemImage: "person.badge.plus",
                        description: Text("Add people to this event")
                    )
                } else {
                    ForEach(participations, id: \.id) { participation in
                        ParticipantRowView(participation: participation)
                            .tag(participation.id)
                    }
                }
            }
            .listStyle(.plain)
            .frame(maxHeight: .infinity)

            // Unknown sender RSVPs
            if !unknownRSVPs.isEmpty {
                Divider()
                unknownRSVPSection
            }
        }
        .onAppear { refreshUnknownRSVPs(event: event) }
        .onChange(of: refreshToken) { refreshUnknownRSVPs(event: event) }
    }

    private func refreshUnknownRSVPs(event: SamEvent) {
        unknownRSVPs = EventCoordinator.shared.unknownSenderRSVPs(for: event)
    }

    private var unknownRSVPSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.orange)
                Text("Possible RSVPs from Unknown Contacts")
                    .samFont(.caption, weight: .bold)
                Spacer()
                Text("\(unknownRSVPs.count)")
                    .samFont(.caption, weight: .bold)
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ForEach(unknownRSVPs) { rsvp in
                Button {
                    quickAddRSVP = rsvp
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.plus")
                            .samFont(.caption)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(rsvp.displayName ?? rsvp.senderHandle)
                                .samFont(.callout)
                                .lineLimit(1)
                            Text(rsvp.messagePreview)
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Text(rsvp.messageDate.formatted(date: .abbreviated, time: .shortened))
                            .samFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        .sheet(item: $quickAddRSVP) { rsvp in
            UnknownSenderQuickAddSheet(rsvp: rsvp, eventID: eventID) {
                refreshToken = UUID()
                lastActionMessage = "Added to event and confirmed"
            }
        }
    }

    // MARK: - Event Header

    private func eventHeader(event: SamEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: event.format.icon)
                Text(event.title)
                    .samFont(.title3, weight: .bold)
                Spacer()
                Text(event.status.displayName)
                    .samFont(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tertiary.opacity(0.3), in: Capsule())

                Menu {
                    Button {
                        showEditEvent = true
                    } label: {
                        Label("Edit Event", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Event", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .sheet(isPresented: $showEditEvent) {
                    EventFormView(existingEvent: event, onUpdated: { changeSummary in
                        refreshToken = UUID()
                        if let changes = changeSummary {
                            pendingChangeSummary = changes
                            showUpdateNotification = true
                        }
                    })
                }
            }

            HStack(spacing: 16) {
                Label(
                    event.startDate.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
                .samFont(.caption)

                if let venue = event.venue {
                    let locationText = [venue, event.address].compactMap { $0 }.joined(separator: ", ")
                    Label(locationText, systemImage: "mappin")
                        .samFont(.caption)
                        .lineLimit(1)
                }

                if event.format == .virtual, event.joinLink != nil {
                    Label("Link Set", systemImage: "link")
                        .samFont(.caption)
                        .foregroundStyle(.green)
                }
            }
            .foregroundStyle(.secondary)

            // RSVP summary bar
            HStack(spacing: 12) {
                rsvpBadge(count: event.participations.filter { $0.rsvpStatus == .accepted }.count,
                          label: "Accepted", color: .green)
                rsvpBadge(count: event.participations.filter { $0.rsvpStatus == .tentative }.count,
                          label: "Tentative", color: .orange)
                rsvpBadge(count: event.participations.filter { $0.rsvpStatus == .declined }.count,
                          label: "Declined", color: .red)
                rsvpBadge(count: event.participations.filter {
                    $0.rsvpStatus == .invited || $0.rsvpStatus == .pending
                }.count, label: "Pending", color: .blue)

                Spacer()

                Text("\(event.acceptedCount)/\(event.targetParticipantCount) target")
                    .samFont(.caption, weight: .bold)
                    .foregroundStyle(event.acceptedCount >= event.targetParticipantCount ? .green : .secondary)
            }

            if let message = lastActionMessage {
                Text(message)
                    .samFont(.caption)
                    .foregroundStyle(.blue)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
    }

    private func rsvpBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .samFont(.caption, weight: .bold)
                .foregroundStyle(color)
            Text(label)
                .samFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Action Bar

    private func actionBar(event: SamEvent) -> some View {
        HStack(spacing: 8) {
            Button {
                showAddParticipants = true
            } label: {
                Label("Add People", systemImage: "person.badge.plus")
                    .samFont(.caption)
            }

            Spacer()

            Button {
                showSocialPromotion = true
            } label: {
                Label("Promote", systemImage: "megaphone")
                    .samFont(.caption)
            }

            Button {
                showInvitationDrafts = true
            } label: {
                Label("Draft Invitations", systemImage: "paperplane")
                    .samFont(.caption)
            }
            .disabled(!hasUninvitedParticipants(event: event))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showAddParticipants, onDismiss: { refreshToken = UUID() }) {
            AddParticipantsSheet(event: event)
        }
        .sheet(isPresented: $showSocialPromotion) {
            SocialPromotionSheet(event: event)
        }
        .sheet(isPresented: $showInvitationDrafts, onDismiss: { refreshToken = UUID() }) {
            InvitationDraftSheet(event: event) {
                refreshToken = UUID()
            }
        }
    }

    // MARK: - Participant Detail (right)

    private func participantDetail(event: SamEvent) -> some View {
        Group {
            if let participationID = selectedParticipationID,
               let participation = event.participations.first(where: { $0.id == participationID }) {
                ParticipantDetailView(participation: participation, event: event)
            } else {
                ContentUnavailableView(
                    "Select a Participant",
                    systemImage: "person.circle",
                    description: Text("Choose someone from the participant list")
                )
            }
        }
    }

    // MARK: - Filtering

    private func hasUninvitedParticipants(event: SamEvent) -> Bool {
        event.participations.contains { $0.inviteStatus == .notInvited }
    }

    private func filteredParticipations(event: SamEvent) -> [EventParticipation] {
        let sorted = EventRepository.shared.fetchParticipations(for: event)
        switch participantFilter {
        case .all:
            return sorted
        case .accepted:
            return sorted.filter { $0.rsvpStatus == .accepted }
        case .pending:
            return sorted.filter { $0.rsvpStatus == .pending || $0.rsvpStatus == .invited }
        case .declined:
            return sorted.filter { $0.rsvpStatus == .declined }
        case .needsConfirmation:
            return sorted.filter { !$0.rsvpUserConfirmed && $0.rsvpDetectionConfidence != nil }
        }
    }
}

// MARK: - Participant Row

struct ParticipantRowView: View {
    let participation: EventParticipation

    var body: some View {
        HStack(spacing: 8) {
            // Priority indicator
            if participation.priority != .standard {
                Image(systemName: participation.priority.icon)
                    .samFont(.caption)
                    .foregroundStyle(participation.priority == .vip ? .yellow : .blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(participation.person?.displayNameCache ?? "Unknown")
                    .samFont(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(participation.eventRole)
                        .samFont(.caption2)
                        .foregroundStyle(.secondary)

                    if participation.inviteStatus != .notInvited {
                        Text(participation.inviteStatus.displayName)
                            .samFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // RSVP status badge
            rsvpStatusBadge

            // Needs confirmation indicator
            if !participation.rsvpUserConfirmed && participation.rsvpDetectionConfidence != nil {
                Image(systemName: "exclamationmark.circle")
                    .samFont(.caption)
                    .foregroundStyle(.orange)
                    .help("SAM detected an RSVP — needs your confirmation")
            }
        }
        .padding(.vertical, 2)
    }

    private var rsvpStatusBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: participation.rsvpStatus.icon)
            Text(participation.rsvpStatus.displayName)
        }
        .samFont(.caption2)
        .foregroundStyle(rsvpColor)
    }

    private var rsvpColor: Color {
        switch participation.rsvpStatus {
        case .accepted:   return .green
        case .declined:   return .red
        case .tentative:  return .orange
        case .invited:    return .blue
        case .noResponse: return .gray
        case .pending:    return .secondary
        }
    }
}

// MARK: - Participant Detail

struct ParticipantDetailView: View {
    let participation: EventParticipation
    let event: SamEvent
    @State private var showInvitationDraft = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Person header
                personHeader

                Divider()

                // RSVP confirmation (if needed)
                if !participation.rsvpUserConfirmed, let confidence = participation.rsvpDetectionConfidence {
                    rsvpConfirmationCard(confidence: confidence)
                    Divider()
                }

                // Message log
                messageLogSection

                Divider()

                // Quick actions
                quickActions
            }
            .padding(16)
        }
    }

    private var personHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(participation.person?.displayNameCache ?? "Unknown")
                        .samFont(.title2, weight: .bold)

                    HStack(spacing: 8) {
                        if participation.priority != .standard {
                            Label(participation.priority.displayName, systemImage: participation.priority.icon)
                                .samFont(.caption)
                                .foregroundStyle(participation.priority == .vip ? .yellow : .blue)
                        }

                        Text(participation.eventRole)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: participation.rsvpStatus.icon)
                        Text(participation.rsvpStatus.displayName)
                    }
                    .samFont(.callout, weight: .bold)
                    .foregroundStyle(rsvpColor)

                    if let sentAt = participation.inviteSentAt {
                        Text("Invited \(sentAt.formatted(date: .abbreviated, time: .omitted))")
                            .samFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Roles from the person's contact record
            if let person = participation.person, !person.roleBadges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(person.roleBadges, id: \.self) { badge in
                        Text(badge)
                            .samFont(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private func rsvpConfirmationCard(confidence: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("RSVP Needs Confirmation")
                    .samFont(.headline)
                Spacer()
                Text("\(Int(confidence * 100))% confidence")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            if let quote = participation.rsvpResponseQuote {
                Text("\"\(quote)\"")
                    .samFont(.callout)
                    .italic()
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Text("SAM detected this as: \(participation.rsvpStatus.displayName)")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Confirm as \(participation.rsvpStatus.displayName)") {
                    try? EventCoordinator.shared.confirmDetectedRSVP(participationID: participation.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                ForEach([RSVPStatus.accepted, .declined, .tentative], id: \.self) { status in
                    if status != participation.rsvpStatus {
                        Button(status.displayName) {
                            try? EventCoordinator.shared.confirmDetectedRSVP(
                                participationID: participation.id,
                                correctedStatus: status
                            )
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var messageLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message History")
                .samFont(.headline)

            if participation.messageLog.isEmpty {
                Text("No messages yet")
                    .samFont(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(participation.messageLog) { message in
                    messageRow(message)
                }
            }
        }
    }

    private func messageRow(_ message: EventMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: messageIcon(for: message.kind))
                    .samFont(.caption)
                    .foregroundStyle(messageColor(for: message.kind))

                Text(message.kind.rawValue.capitalized)
                    .samFont(.caption, weight: .bold)

                if let channel = message.channel {
                    Text("via \(channel.displayName)")
                        .samFont(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if message.isDraft {
                    Text("DRAFT")
                        .samFont(.caption2, weight: .bold)
                        .foregroundStyle(.blue)
                } else if let sentAt = message.sentAt {
                    Text(sentAt.formatted(date: .abbreviated, time: .shortened))
                        .samFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(message.body)
                .samFont(.callout)
                .lineLimit(3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(message.isDraft ? Color.blue.opacity(0.05) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            if message.isDraft {
                HStack {
                    Spacer()
                    Button("Copy & Mark Sent") {
                        ClipboardSecurity.copy(message.body, clearAfter: 60)
                        try? EventRepository.shared.markMessageSent(
                            participationID: participation.id,
                            messageID: message.id
                        )
                    }
                    .samFont(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .samFont(.headline)

            HStack(spacing: 8) {
                if participation.inviteStatus == .notInvited || participation.inviteStatus == .draftReady {
                    Button {
                        showInvitationDraft = true
                    } label: {
                        Label("Draft Invitation", systemImage: "paperplane")
                    }
                    .controlSize(.small)
                } else if participation.inviteStatus == .invited || participation.inviteStatus == .reminderSent {
                    // Already invited but no confirmed RSVP — allow resend
                    if participation.rsvpStatus != .accepted && participation.rsvpStatus != .declined {
                        Button {
                            showInvitationDraft = true
                        } label: {
                            Label("Resend Invitation", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                }

                if participation.rsvpStatus != .accepted && participation.rsvpStatus != .declined {
                    Menu {
                        Button("Accepted") {
                            try? EventRepository.shared.updateRSVP(
                                participationID: participation.id,
                                status: .accepted,
                                userConfirmed: true
                            )
                        }
                        Button("Declined") {
                            try? EventRepository.shared.updateRSVP(
                                participationID: participation.id,
                                status: .declined,
                                userConfirmed: true
                            )
                        }
                        Button("Tentative") {
                            try? EventRepository.shared.updateRSVP(
                                participationID: participation.id,
                                status: .tentative,
                                userConfirmed: true
                            )
                        }
                    } label: {
                        Label("Set RSVP", systemImage: "checkmark.circle")
                    }
                    .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $showInvitationDraft) {
            InvitationDraftSheet(
                event: event,
                singleParticipation: participation
            ) {
                showInvitationDraft = false
            }
        }
    }

    // MARK: - Helpers

    private var rsvpColor: Color {
        switch participation.rsvpStatus {
        case .accepted:   return .green
        case .declined:   return .red
        case .tentative:  return .orange
        case .invited:    return .blue
        case .noResponse: return .gray
        case .pending:    return .secondary
        }
    }

    private func messageIcon(for kind: EventMessage.EventMessageKind) -> String {
        switch kind {
        case .invitation:      return "paperplane"
        case .reminder:        return "bell"
        case .acknowledgment:  return "checkmark.bubble"
        case .followUp:        return "arrow.turn.up.right"
        case .update:          return "arrow.triangle.2.circlepath"
        case .rsvpResponse:    return "bubble.left"
        case .custom:          return "text.bubble"
        }
    }

    private func messageColor(for kind: EventMessage.EventMessageKind) -> Color {
        switch kind {
        case .invitation:      return .blue
        case .reminder:        return .orange
        case .acknowledgment:  return .green
        case .followUp:        return .purple
        case .update:          return .indigo
        case .rsvpResponse:    return .teal
        case .custom:          return .secondary
        }
    }
}
