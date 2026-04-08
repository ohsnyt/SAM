//
//  EventDetailView.swift
//  SAM
//
//  Created on March 11, 2026.
//  Event detail — participant list, RSVP management, invitations, and follow-ups.
//

import SwiftData
import SwiftUI

struct EventDetailView: View {

    let eventID: UUID
    var onDelete: (() -> Void)?
    @State private var event: SamEvent?
    @State private var cachedParticipations: [EventParticipation] = []
    @State private var selectedParticipationID: UUID?
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
    @State private var showBulkReviewSheet = false
    @State private var inferredExpanded = true
    @State private var dismissedExpanded = false
    @State private var showEvaluationImport = false

    private func reloadEvent() {
        let loaded = try? EventRepository.shared.fetch(id: eventID)
        event = loaded
        if let loaded {
            cachedParticipations = EventRepository.shared.fetchParticipations(for: loaded)
        } else {
            cachedParticipations = []
        }
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
        .task(id: eventID) {
            selectedParticipationID = nil
            unknownRSVPs = []
            lastActionMessage = nil
            reloadEvent()
            if let event {
                refreshUnknownRSVPs(event: event)
            }
        }
        .onChange(of: refreshToken) { reloadEvent() }
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

            // Two-tier participant list
            List(selection: $selectedParticipationID) {
                let confirmed = confirmedParticipations
                let inferred = inferredParticipations
                let dismissed = dismissedParticipations

                if confirmed.isEmpty && inferred.isEmpty && dismissed.isEmpty {
                    ContentUnavailableView(
                        "No Participants",
                        systemImage: "person.badge.plus",
                        description: Text("Add people to this event")
                    )
                } else {
                    // Confirmed participants
                    if !confirmed.isEmpty {
                        Section("Participants (\(confirmed.count))") {
                            ForEach(confirmed, id: \.id) { participation in
                                ParticipantRowView(participation: participation)
                                    .tag(participation.id)
                            }
                        }
                    }

                    // Inferred (AI-detected, unconfirmed) participants
                    if !inferred.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $inferredExpanded) {
                                ForEach(inferred, id: \.id) { participation in
                                    InferredParticipantRowView(participation: participation) {
                                        refreshToken = UUID()
                                    }
                                    .tag(participation.id)
                                }
                                if inferred.count > 3 {
                                    Button {
                                        showBulkReviewSheet = true
                                    } label: {
                                        Label("Review All", systemImage: "checklist")
                                            .samFont(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.orange)
                                    Text("Inferred (\(inferred.count))")
                                        .samFont(.subheadline, weight: .medium)
                                }
                            }
                        }
                    }

                    // Dismissed detections
                    if !dismissed.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $dismissedExpanded) {
                                ForEach(dismissed, id: \.id) { participation in
                                    DismissedParticipantRowView(participation: participation) {
                                        refreshToken = UUID()
                                    }
                                    .tag(participation.id)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "eye.slash")
                                        .foregroundStyle(.secondary)
                                    Text("Dismissed (\(dismissed.count))")
                                        .samFont(.subheadline, weight: .medium)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .frame(maxHeight: .infinity)
            .sheet(isPresented: $showBulkReviewSheet, onDismiss: { refreshToken = UUID() }) {
                BulkRSVPReviewSheet(event: event) {
                    refreshToken = UUID()
                }
            }

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
                rsvpBadge(count: cachedParticipations.filter { $0.rsvpStatus == .accepted }.count,
                          label: "Accepted", color: .green)
                rsvpBadge(count: cachedParticipations.filter { $0.rsvpStatus == .tentative }.count,
                          label: "Tentative", color: .orange)
                rsvpBadge(count: cachedParticipations.filter { $0.rsvpStatus == .declined }.count,
                          label: "Declined", color: .red)
                rsvpBadge(count: cachedParticipations.filter {
                    $0.rsvpStatus == .invited || $0.rsvpStatus == .pending
                }.count, label: "Pending", color: .blue)

                let dismissedCount = cachedParticipations.filter { $0.rsvpDismissed }.count
                if dismissedCount > 0 {
                    rsvpBadge(count: dismissedCount, label: "Dismissed", color: .gray)
                }

                Spacer()

                let acceptedCount = cachedParticipations.filter { $0.rsvpStatus == .accepted }.count
                Text("\(acceptedCount)/\(event.targetParticipantCount) target")
                    .samFont(.caption, weight: .bold)
                    .foregroundStyle(acceptedCount >= event.targetParticipantCount ? .green : .secondary)
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
            .disabled(!hasUninvitedParticipants())

            if event.status == .completed {
                Button {
                    showEvaluationImport = true
                } label: {
                    Label("Evaluate", systemImage: "chart.bar.doc.horizontal")
                        .samFont(.caption)
                }
            }
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
        .sheet(isPresented: $showEvaluationImport, onDismiss: { refreshToken = UUID() }) {
            EventEvaluationImportSheet(event: event) {
                refreshToken = UUID()
            }
        }
        .sheet(isPresented: Binding(
            get: { SentMailDetectionService.shared.pendingReviewResult != nil },
            set: { if !$0 { SentMailDetectionService.shared.pendingReviewResult = nil } }
        ), onDismiss: { refreshToken = UUID() }) {
            if let (match, recipients) = SentMailDetectionService.shared.pendingReviewResult {
                InvitationRecipientReviewSheet(matchResult: match, recipients: recipients) {
                    SentMailDetectionService.shared.pendingReviewResult = nil
                    refreshToken = UUID()
                }
            }
        }
    }

    // MARK: - Participant Detail (right)

    private func participantDetail(event: SamEvent) -> some View {
        Group {
            if let participationID = selectedParticipationID,
               let participation = cachedParticipations.first(where: { $0.id == participationID }),
               !participation.isDeleted {
                ParticipantDetailView(
                    participation: participation,
                    event: event,
                    onRemoved: {
                        // Remove from cached list immediately so the stale entry
                        // can't be clicked while the deferred SwiftData delete runs.
                        // Do NOT set refreshToken here — that triggers reloadEvent()
                        // which re-fetches from SwiftData before the deferred delete.
                        cachedParticipations.removeAll { $0.id == participationID }
                        selectedParticipationID = nil
                    },
                    onDeleted: {
                        // SwiftData delete is done — safe to reload from database
                        refreshToken = UUID()
                    }
                )
            } else if event.status == .completed {
                PostEventEvaluationView(event: event)
            } else {
                ContentUnavailableView(
                    "Select a Participant",
                    systemImage: "person.circle",
                    description: Text("Choose someone from the participant list")
                )
            }
        }
    }

    // MARK: - Two-Tier Filtering

    private func hasUninvitedParticipants() -> Bool {
        cachedParticipations.contains { $0.inviteStatus == .notInvited }
    }

    /// The adaptive RSVP auto-confirm threshold from calibration data.
    private var rsvpThreshold: Double {
        EventCoordinator.computeRSVPThreshold(from: CalibrationService.cachedLedger)
    }

    /// Confirmed: user-set status, manually confirmed, no AI detection, or high-confidence auto-detection.
    private var confirmedParticipations: [EventParticipation] {
        let threshold = rsvpThreshold
        return cachedParticipations.filter { p in
            guard !p.rsvpDismissed else { return false }
            if p.rsvpUserConfirmed || p.rsvpDetectionConfidence == nil { return true }
            // High-confidence detections are treated as confirmed
            if let confidence = p.rsvpDetectionConfidence, confidence >= threshold { return true }
            return false
        }
    }

    /// Inferred: AI-detected RSVP below the confidence threshold, not yet confirmed or dismissed.
    private var inferredParticipations: [EventParticipation] {
        let threshold = rsvpThreshold
        return cachedParticipations
            .filter { p in
                guard let confidence = p.rsvpDetectionConfidence else { return false }
                return confidence < threshold && !p.rsvpUserConfirmed && !p.rsvpDismissed
            }
            .sorted { ($0.rsvpDetectionConfidence ?? 0) > ($1.rsvpDetectionConfidence ?? 0) }
    }

    /// Dismissed: user rejected the AI detection.
    private var dismissedParticipations: [EventParticipation] {
        cachedParticipations.filter { $0.rsvpDismissed }
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
    var onRemoved: (() -> Void)?
    var onDeleted: (() -> Void)?
    @State private var showInvitationDraft = false
    @State private var showRemoveConfirmation = false

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
                } else if [.handedOff, .invited, .reminderSent].contains(participation.inviteStatus) {
                    // Already invited (or handed off to Mail) but no confirmed RSVP — allow resend
                    if participation.rsvpStatus != .accepted && participation.rsvpStatus != .declined {
                        Button {
                            showInvitationDraft = true
                        } label: {
                            Label(
                                participation.inviteStatus == .handedOff ? "Reinvite" : "Resend Invitation",
                                systemImage: "arrow.clockwise"
                            )
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

                Spacer()

                Button(role: .destructive) {
                    showRemoveConfirmation = true
                } label: {
                    Label("Remove from Event", systemImage: "person.badge.minus")
                }
                .controlSize(.small)
            }
        }
        .alert("Remove Participant?", isPresented: $showRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                let participationID = participation.id
                let targetEvent = event
                // Clear selection first so the parent stops rendering this view
                onRemoved?()
                // Defer deletion until after the alert dismiss animation completes
                // and SwiftUI processes the selection change. Without this delay,
                // the layout pass triggered by NSWindowEndWindowModalSession
                // re-evaluates this view's body before the parent can deselect it,
                // causing a fault on the detached SwiftData backing store.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    try? EventRepository.shared.removeParticipant(participationID: participationID, from: targetEvent)
                    onDeleted?()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove \(participation.person?.displayNameCache ?? "this person") from the event and clear all invitation and RSVP data. SAM will not associate them with this event.")
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

// MARK: - Inferred Participant Row

struct InferredParticipantRowView: View {
    let participation: EventParticipation
    var onAction: () -> Void

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
                    // RSVP status badge
                    HStack(spacing: 3) {
                        Image(systemName: participation.rsvpStatus.icon)
                        Text(participation.rsvpStatus.displayName)
                    }
                    .samFont(.caption2)
                    .foregroundStyle(rsvpColor)

                    if let confidence = participation.rsvpDetectionConfidence {
                        Text("\(Int(confidence * 100))%")
                            .samFont(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let quote = participation.rsvpResponseQuote {
                        Text(quote)
                            .samFont(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .italic()
                    }
                }
            }

            Spacer()

            // Confirm button
            Button {
                try? EventCoordinator.shared.confirmDetectedRSVP(participationID: participation.id)
                onAction()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help("Confirm this RSVP detection")

            // Dismiss button
            Button {
                try? EventCoordinator.shared.dismissDetectedRSVP(participationID: participation.id)
                onAction()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Dismiss — SAM got this wrong")
        }
        .padding(.vertical, 2)
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

// MARK: - Dismissed Participant Row

struct DismissedParticipantRowView: View {
    let participation: EventParticipation
    var onAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(participation.person?.displayNameCache ?? "Unknown")
                    .samFont(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let originalStatus = participation.rsvpOriginalDetectedStatus {
                    Text("SAM detected: \(originalStatus.displayName)")
                        .samFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button("Undo") {
                try? EventRepository.shared.undoDismissRSVP(participationID: participation.id)
                onAction()
            }
            .controlSize(.mini)
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Bulk RSVP Review Sheet

struct BulkRSVPReviewSheet: View {
    let event: SamEvent
    var onDismiss: () -> Void
    @State private var participations: [EventParticipation] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Review Inferred RSVPs")
                    .samFont(.title3, weight: .bold)
                Spacer()
                Button("Done") {
                    onDismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Toolbar
            HStack(spacing: 12) {
                Button {
                    confirmAll()
                } label: {
                    Label("Confirm All", systemImage: "checkmark.circle")
                }
                .controlSize(.small)

                Button {
                    dismissAll()
                } label: {
                    Label("Dismiss All", systemImage: "xmark.circle")
                }
                .controlSize(.small)

                Spacer()

                Text("\(participations.count) inferred")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // List
            List {
                ForEach(participations, id: \.id) { participation in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(participation.person?.displayNameCache ?? "Unknown")
                                .samFont(.body)

                            HStack(spacing: 8) {
                                HStack(spacing: 3) {
                                    Image(systemName: participation.rsvpStatus.icon)
                                    Text(participation.rsvpStatus.displayName)
                                }
                                .samFont(.caption)
                                .foregroundStyle(badgeColor(for: participation.rsvpStatus))

                                if let confidence = participation.rsvpDetectionConfidence {
                                    Text("\(Int(confidence * 100))% confidence")
                                        .samFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let quote = participation.rsvpResponseQuote {
                                Text("\"\(quote)\"")
                                    .samFont(.caption)
                                    .italic()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        Spacer()

                        // Per-row actions
                        HStack(spacing: 8) {
                            Button {
                                try? EventCoordinator.shared.confirmDetectedRSVP(participationID: participation.id)
                                reload()
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.borderless)
                            .help("Confirm")

                            // Correct status menu
                            Menu {
                                ForEach([RSVPStatus.accepted, .declined, .tentative], id: \.self) { status in
                                    if status != participation.rsvpStatus {
                                        Button(status.displayName) {
                                            try? EventCoordinator.shared.confirmDetectedRSVP(
                                                participationID: participation.id,
                                                correctedStatus: status
                                            )
                                            reload()
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.triangle.swap")
                                    .foregroundStyle(.blue)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 20)
                            .help("Correct the detected status")

                            Button {
                                try? EventCoordinator.shared.dismissDetectedRSVP(participationID: participation.id)
                                reload()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 550, height: 450)
        .onAppear { reload() }
    }

    private func reload() {
        participations = EventRepository.shared.fetchParticipations(for: event)
            .filter { $0.rsvpDetectionConfidence != nil && !$0.rsvpUserConfirmed && !$0.rsvpDismissed }
            .sorted { ($0.rsvpDetectionConfidence ?? 0) > ($1.rsvpDetectionConfidence ?? 0) }
    }

    private func confirmAll() {
        for p in participations {
            try? EventCoordinator.shared.confirmDetectedRSVP(participationID: p.id)
        }
        reload()
    }

    private func dismissAll() {
        let ids = participations.map(\.id)
        try? EventRepository.shared.bulkDismissRSVPs(participationIDs: ids)
        // Record calibration feedback for each
        for p in participations {
            let status = p.rsvpStatus
            Task(priority: .background) {
                await CalibrationService.shared.recordRSVPFeedback(detectedStatus: status, wasCorrect: false)
            }
        }
        reload()
    }

    private func badgeColor(for status: RSVPStatus) -> Color {
        switch status {
        case .accepted:   return .green
        case .declined:   return .red
        case .tentative:  return .orange
        case .invited:    return .blue
        case .noResponse: return .gray
        case .pending:    return .secondary
        }
    }
}
