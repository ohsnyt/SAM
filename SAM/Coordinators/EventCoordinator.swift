//
//  EventCoordinator.swift
//  SAM
//
//  Created on March 11, 2026.
//  Orchestrates the event lifecycle: setup, invitation drafting, RSVP observation,
//  reminders, auto-acknowledgments, and post-event follow-up.
//

import AppKit
import Foundation
import os.log

@MainActor @Observable
final class EventCoordinator {

    // MARK: - Singleton

    static let shared = EventCoordinator()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EventCoordinator")

    private init() {}

    // MARK: - State

    var selectedEvent: SamEvent?
    var isGeneratingDrafts = false
    var lastError: String?
    private var reminderSchedulerTask: Task<Void, Never>?

    // MARK: - Unknown Sender Event RSVPs

    /// An unknown sender whose message may reference an event.
    struct UnknownEventRSVP: Identifiable, Sendable {
        let id: UUID        // UnknownSender ID
        let senderHandle: String  // phone number or email
        let displayName: String?
        let messagePreview: String
        let messageDate: Date
        let matchedEventID: UUID
        let matchedEventTitle: String
    }

    /// Scan unknown senders for messages that reference upcoming events.
    func unknownSenderRSVPs(for event: SamEvent) -> [UnknownEventRSVP] {
        guard let unknownSenders = try? UnknownSenderRepository.shared.fetchPending() else { return [] }
        let titleWords = Set(event.title.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 })
        guard !titleWords.isEmpty else { return [] }

        var matches: [UnknownEventRSVP] = []
        for sender in unknownSenders where sender.source == .iMessage {
            guard let preview = sender.latestSubject, !preview.isEmpty else { continue }
            let previewLower = preview.lowercased()

            // Check if the message references this event by title keyword overlap
            let previewWords = Set(previewLower.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 })
            let overlap = titleWords.intersection(previewWords)

            // Require at least 2 word matches, or 1 match if the title is short (1-2 words)
            let threshold = titleWords.count <= 2 ? 1 : 2
            guard overlap.count >= threshold else { continue }

            // Also check for attendance-related keywords
            let attendKeywords = ["attend", "come", "coming", "rsvp", "join", "count me", "i'll be", "sign me", "interested", "want to"]
            let hasAttendanceIntent = attendKeywords.contains { previewLower.contains($0) }
            guard hasAttendanceIntent else { continue }

            matches.append(UnknownEventRSVP(
                id: sender.id,
                senderHandle: sender.email,  // phone number for iMessage senders
                displayName: sender.displayName,
                messagePreview: preview,
                messageDate: sender.latestEmailDate ?? sender.firstSeenAt,
                matchedEventID: event.id,
                matchedEventTitle: event.title
            ))
        }
        return matches
    }

    /// Add an unknown sender as a contact and confirm them for an event.
    /// Returns the created participation.
    func addUnknownSenderToEvent(
        unknownSenderID: UUID,
        eventID: UUID,
        contactName: String?
    ) throws -> EventParticipation? {
        let eventRepo = EventRepository.shared
        guard let event = try eventRepo.fetch(id: eventID) else { return nil }

        // Find the unknown sender
        guard let sender = try UnknownSenderRepository.shared.fetchByID(unknownSenderID) else { return nil }

        // Determine display name: use provided name, fall back to phone/email handle
        let displayName = (contactName?.isEmpty == false) ? contactName! : sender.email

        // Determine whether the handle is a phone number or email
        let isPhone = !sender.email.contains("@")
        let phone: String? = isPhone ? sender.email : nil
        let email: String? = isPhone ? nil : sender.email

        // Create a SamPerson (standalone, no Apple Contact required)
        let person = try PeopleRepository.shared.insertStandalone(
            displayName: displayName,
            phone: phone,
            email: email
        )

        // Mark unknown sender as added
        try UnknownSenderRepository.shared.markAdded(sender)

        // Add as participant with accepted RSVP
        let participation = try eventRepo.addParticipant(
            event: event,
            person: person,
            priority: .standard,
            eventRole: "Attendee"
        )
        try eventRepo.updateRSVP(
            participationID: participation.id,
            status: .accepted,
            userConfirmed: true
        )

        // Auto-transition draft → inviting
        transitionFromDraftIfNeeded(event: event)

        // NOTE: Do NOT call processAutoAcknowledgment here.
        // UnknownSenderQuickAddSheet Phase 2 handles the confirmation message,
        // letting the user review/edit before sending. Auto-acking here would
        // send a duplicate.

        logger.debug("Added unknown sender \(sender.email) to event \(event.title) as \(displayName)")
        return participation
    }

    // MARK: - Event Lifecycle

    /// Phase 1: Create an event, create a matching Apple Calendar event, and transition to inviting status.
    func createEvent(
        title: String,
        description: String? = nil,
        format: EventFormat,
        startDate: Date,
        duration: TimeInterval = 3600,
        venue: String? = nil,
        address: String? = nil,
        joinLink: String? = nil,
        targetParticipants: Int = 20
    ) throws -> SamEvent {
        let endDate = startDate.addingTimeInterval(duration)
        let event = try EventRepository.shared.createEvent(
            title: title,
            eventDescription: description,
            format: format,
            startDate: startDate,
            endDate: endDate,
            venue: venue,
            address: address,
            joinLink: joinLink,
            targetParticipantCount: targetParticipants
        )
        logger.debug("Event created: \(title)")

        // Create a matching Apple Calendar event
        Task.detached(priority: .utility) {
            await self.createCalendarEvent(
                title: title,
                description: description,
                format: format,
                startDate: startDate,
                endDate: endDate,
                venue: venue,
                joinLink: joinLink
            )
        }

        return event
    }

    /// Create an Apple Calendar event with location/link appropriate to the event format.
    private func createCalendarEvent(
        title: String,
        description: String?,
        format: EventFormat,
        startDate: Date,
        endDate: Date,
        venue: String?,
        joinLink: String?
    ) async {
        // Build location and notes based on format
        let location: String?
        let url: URL?
        var notes = description ?? ""

        switch format {
        case .inPerson:
            // Physical location only
            location = venue
            url = nil

        case .virtual:
            // Join link as the location so it's clickable in Calendar
            location = joinLink
            url = joinLink.flatMap { URL(string: $0) }

        case .hybrid:
            // Physical venue as the location; join link in notes and URL
            location = venue
            url = joinLink.flatMap { URL(string: $0) }
            if let link = joinLink, !link.isEmpty {
                if !notes.isEmpty { notes += "\n\n" }
                notes += "Join online: \(link)"
            }
        }

        let eventID = await CalendarService.shared.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            notes: notes.isEmpty ? nil : notes,
            location: location,
            url: url,
            calendarTitle: "SAM Events"
        )

        if let eventID {
            logger.debug("Apple Calendar event created: \(eventID)")
        } else {
            logger.warning("Could not create Apple Calendar event — calendar access may not be authorized")
        }
    }

    /// Add participants to an event with priority and role.
    func addParticipants(
        to event: SamEvent,
        people: [(person: SamPerson, priority: ParticipantPriority, role: String)]
    ) throws -> [EventParticipation] {
        var participations: [EventParticipation] = []
        for entry in people {
            let participation = try EventRepository.shared.addParticipant(
                event: event,
                person: entry.person,
                priority: entry.priority,
                eventRole: entry.role
            )
            participations.append(participation)
        }
        logger.debug("Added \(participations.count) participants to \(event.title)")
        return participations
    }

    // MARK: - Invitation Drafting

    /// Generate personalized invitation drafts for all uninvited participants.
    /// Returns the count of drafts generated.
    func generateInvitationDrafts(for event: SamEvent) async throws -> Int {
        isGeneratingDrafts = true
        defer { isGeneratingDrafts = false }

        let uninvited = event.participations.filter { $0.inviteStatus == .notInvited }
        guard !uninvited.isEmpty else { return 0 }

        var draftCount = 0

        for participation in uninvited {
            guard let person = participation.person else { continue }

            let draft = try await generatePersonalizedInvitation(
                event: event,
                person: person,
                priority: participation.priority
            )

            // Determine preferred channel for this person
            let channel = preferredInviteChannel(for: person)

            try EventRepository.shared.appendMessage(
                participationID: participation.id,
                kind: .invitation,
                channel: channel,
                body: draft,
                isDraft: true
            )

            participation.inviteStatus = .draftReady
            draftCount += 1
        }

        if event.status == .draft {
            try EventRepository.shared.updateEvent(id: event.id, status: .inviting)
        }

        logger.debug("Generated \(draftCount) invitation drafts for \(event.title)")
        return draftCount
    }

    /// Generate a personalized invitation for a single person.
    private func generatePersonalizedInvitation(
        event: SamEvent,
        person: SamPerson,
        priority: ParticipantPriority,
        channel: CommunicationChannel = .iMessage
    ) async throws -> String {
        let personContext = buildPersonContext(person: person)
        let eventDetails = buildEventDetails(event: event)
        let isWarm = isWarmRelationship(person: person)
        let senderName = AIService.senderName(forWarmRelationship: isWarm)
        let closing = AIService.closing(forMessageKind: "invitation", isWarm: isWarm)

        let channelGuidelines: String
        switch channel {
        case .email:
            channelGuidelines = """
                FORMAT: Email
                - Start with a greeting (e.g., "Hi {name}," or "Dear {name},")
                - Write in complete paragraphs — 3-5 sentences for standard, slightly longer for VIP
                - Include all event details: date, time, venue/link
                - Sign off with exactly: "\(closing)\\n\(senderName)"
                - Write ONLY the message body with greeting and sign-off — no subject line
                """
        case .iMessage, .whatsApp:
            channelGuidelines = """
                FORMAT: Text message (iMessage)
                - NO greeting/salutation — jump straight into the message
                - NO sign-off or closing — do not include "Best," or a signature
                - Keep it SHORT: 2-3 sentences max, conversational tone
                - Include the key details: what, when, where
                - End with a casual ask ("You in?" or "Would love to see you there")
                - Write like you're texting a colleague, not composing an email
                """
        default:
            channelGuidelines = """
                FORMAT: Short message
                - Keep it concise: 2-3 sentences
                - Include the key details: what, when, where
                """
        }

        let prompt = """
            Write a personalized invitation for the following event.

            EVENT DETAILS:
            \(eventDetails)

            PERSON CONTEXT:
            \(personContext)

            PRIORITY: \(priority.displayName)

            SENDER: \(AIService.userFullName)

            \(channelGuidelines)

            GUIDELINES:
            - Reference something specific from the person's context if available
            - For VIP/speakers: acknowledge their expertise and why their presence matters
            - For standard attendees: focus on what they'll gain from attending
            - ALWAYS include the full location (venue name AND street address) for in-person/hybrid events
            - ALWAYS include the join link for virtual/hybrid events
            - End with a soft ask, not a demand
            - Do NOT promise financial returns or use pressure tactics

            Return only the invitation text.
            """

        let persona = await BusinessProfileService.shared.personaFragment()
        let complianceNote = await BusinessProfileService.shared.complianceNote()
        let complianceLine = complianceNote.isEmpty ? "" : " \(complianceNote) Never promise returns, never pressure, always educate."

        let systemInstruction = """
            You are a warm, professional communication assistant for \(persona). \
            You write personalized messages that feel genuinely individual — never templated or mass-produced.\(complianceLine)
            """

        return try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: systemInstruction,
            maxTokens: 1024
        )
    }

    /// Generate a personalized invitation draft for a single participant (text only, does not save).
    func generateInvitationText(for participation: EventParticipation, channel: CommunicationChannel? = nil) async throws -> String {
        guard let event = participation.event, let person = participation.person else {
            throw EventCoordinatorError.missingData
        }
        let resolvedChannel = channel ?? participation.inviteChannel ?? preferredInviteChannel(for: person)
        return try await generatePersonalizedInvitation(
            event: event,
            person: person,
            priority: participation.priority,
            channel: resolvedChannel
        )
    }

    /// Save a finalized invitation draft and mark the participation as draft-ready.
    func saveInvitationDraft(for participation: EventParticipation, body: String, channel: CommunicationChannel? = nil) throws {
        guard let person = participation.person else { return }
        let channel = channel ?? participation.inviteChannel ?? preferredInviteChannel(for: person)
        try EventRepository.shared.appendMessage(
            participationID: participation.id,
            kind: .invitation,
            channel: channel,
            body: body,
            isDraft: true
        )
        participation.inviteStatus = .draftReady
    }

    /// Send an invitation: copy to clipboard, open compose in the preferred channel, and mark sent.
    func sendInvitation(for participation: EventParticipation, body: String, channel: CommunicationChannel? = nil) throws {
        guard let person = participation.person else { return }
        let channel = channel ?? participation.inviteChannel ?? preferredInviteChannel(for: person)

        // Append as a sent message (not draft)
        try EventRepository.shared.appendMessage(
            participationID: participation.id,
            kind: .invitation,
            channel: channel,
            body: body,
            isDraft: false
        )
        participation.inviteStatus = .invited
        participation.inviteSentAt = .now
        participation.inviteChannel = channel

        // Resolve recipient address based on channel
        let recipientID: String
        switch channel {
        case .email:
            recipientID = person.emailCache ?? person.phoneAliases.first ?? ""
        case .iMessage:
            recipientID = person.phoneAliases.first ?? person.emailCache ?? ""
        case .whatsApp:
            recipientID = person.phoneAliases.first ?? ""
        default:
            recipientID = person.phoneAliases.first ?? person.emailCache ?? ""
        }
        let compose = ComposeService.shared

        if compose.directSendEnabled {
            Task {
                var delivered = false
                switch channel {
                case .iMessage:
                    delivered = await compose.sendDirectIMessage(recipient: recipientID, body: body)
                case .email:
                    let subject = participation.event?.title ?? "Event Invitation"
                    delivered = await compose.sendDirectEmail(recipient: recipientID, subject: subject, body: body)
                default:
                    break
                }
                // Fall back to system handoff if direct send fails or unsupported channel
                if !delivered {
                    deliverViaSystemHandoff(channel: channel, recipient: recipientID, body: body)
                }
            }
        } else {
            deliverViaSystemHandoff(channel: channel, recipient: recipientID, body: body)
        }

        if let event = participation.event, event.status == .draft {
            try? EventRepository.shared.updateEvent(id: event.id, status: .inviting)
        }
    }

    /// System handoff delivery — opens the system app with the draft pre-filled.
    private func deliverViaSystemHandoff(channel: CommunicationChannel, recipient: String, body: String) {
        let compose = ComposeService.shared
        switch channel {
        case .iMessage:
            compose.composeIMessage(recipient: recipient, body: body)
        case .email:
            compose.composeEmail(recipient: recipient, subject: nil, body: body)
        case .whatsApp:
            compose.composeWhatsApp(phone: recipient, body: body)
        default:
            compose.copyToClipboard(body)
        }
    }

    enum EventCoordinatorError: Error, LocalizedError {
        case missingData
        var errorDescription: String? { "Missing event or person data" }
    }

    /// Generate or regenerate an invitation draft for a specific participant.
    func regenerateInvitation(for participation: EventParticipation, channel: CommunicationChannel? = nil) async throws {
        guard let event = participation.event, let person = participation.person else { return }

        let resolvedChannel = channel ?? participation.inviteChannel ?? preferredInviteChannel(for: person)

        let draft = try await generatePersonalizedInvitation(
            event: event,
            person: person,
            priority: participation.priority,
            channel: resolvedChannel
        )

        let channel = resolvedChannel

        try EventRepository.shared.appendMessage(
            participationID: participation.id,
            kind: .invitation,
            channel: channel,
            body: draft,
            isDraft: true
        )

        participation.inviteStatus = .draftReady
        logger.debug("Regenerated invitation for \(person.displayNameCache ?? "participant")")
    }

    // MARK: - Social Promotion

    /// Ask whether to promote on social media — returns platform suggestions.
    func suggestSocialPlatforms(for event: SamEvent) -> [String] {
        var platforms: [String] = []
        platforms.append("linkedin")    // Always relevant for professional events
        platforms.append("facebook")    // Good for local/community events
        if event.format == .virtual {
            platforms.append("substack") // Newsletter for virtual events with broader reach
        }
        return platforms
    }

    /// Generate a social media promotion draft for a specific platform.
    func generateSocialPromotion(for event: SamEvent, platform: String) async throws -> String {
        let eventDetails = buildEventDetails(event: event)
        let participantCount = event.participations.count
        let acceptedCount = event.acceptedCount

        let prompt = """
            Write a social media post promoting this event for \(platform).

            EVENT DETAILS:
            \(eventDetails)

            REGISTRATION STATUS: \(participantCount) invited, \(acceptedCount) confirmed so far
            TARGET: \(event.targetParticipantCount) participants

            PLATFORM GUIDELINES:
            \(platformGuidelines(for: platform))

            COMPLIANCE:
            - Educational framing only — no financial product promotion
            - No guaranteed outcomes or pressure tactics
            - Include appropriate disclaimers if discussing financial topics

            Return only the post text.
            """

        let output = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: "You write engaging social media content for financial professionals. " +
                "You balance educational value with event promotion. You understand platform-specific conventions.",
            maxTokens: 1024
        )

        try EventRepository.shared.upsertSocialPromotion(
            eventID: event.id,
            platform: platform,
            draftText: output
        )

        return output
    }

    // MARK: - RSVP Processing

    /// Auto-transition event from draft → inviting when meaningful activity occurs
    /// (RSVP received, invitation sent, or promotion posted).
    private func transitionFromDraftIfNeeded(event: SamEvent) {
        guard event.status == .draft else { return }
        event.status = .inviting
        logger.debug("Event '\(event.title)' auto-transitioned from Draft → Inviting")
    }

    /// Confirm a SAM-detected RSVP and trigger auto-acknowledgment if eligible.
    /// Call this instead of `EventRepository.confirmRSVP` to ensure the ack pipeline fires.
    func confirmDetectedRSVP(participationID: UUID) throws {
        // Capture detected status before confirming (status won't change, but ensure we have it)
        let detectedStatus = (try? EventRepository.shared.fetchParticipation(id: participationID))?.rsvpStatus

        try EventRepository.shared.confirmRSVP(participationID: participationID)

        // Record calibration feedback after successful confirmation
        if let detectedStatus {
            Task(priority: .background) {
                await CalibrationService.shared.recordRSVPFeedback(detectedStatus: detectedStatus, wasCorrect: true)
            }
        }

        if let participation = try? EventRepository.shared.fetchParticipation(id: participationID),
           let event = participation.event {
            transitionFromDraftIfNeeded(event: event)
        }
        try processAutoAcknowledgment(participationID: participationID)
    }

    /// Confirm a SAM-detected RSVP with a corrected status and trigger auto-acknowledgment.
    func confirmDetectedRSVP(participationID: UUID, correctedStatus: RSVPStatus) throws {
        // Capture the AI-detected status before overwriting it
        let detectedStatus = (try? EventRepository.shared.fetchParticipation(id: participationID))?.rsvpStatus

        try EventRepository.shared.updateRSVP(
            participationID: participationID,
            status: correctedStatus,
            userConfirmed: true
        )

        // Record calibration feedback: original detection was wrong (user corrected it)
        if let detectedStatus {
            Task(priority: .background) {
                await CalibrationService.shared.recordRSVPFeedback(detectedStatus: detectedStatus, wasCorrect: false)
            }
        }

        if let participation = try? EventRepository.shared.fetchParticipation(id: participationID),
           let event = participation.event {
            transitionFromDraftIfNeeded(event: event)
        }
        try processAutoAcknowledgment(participationID: participationID)
    }

    /// Dismiss a SAM-detected RSVP as incorrect. Records calibration feedback.
    func dismissDetectedRSVP(participationID: UUID) throws {
        // Capture the detected status before dismissing
        let detectedStatus: RSVPStatus?
        if let participation = try? EventRepository.shared.fetchParticipation(id: participationID) {
            detectedStatus = participation.rsvpStatus
        } else {
            detectedStatus = nil
        }

        try EventRepository.shared.dismissRSVP(participationID: participationID)

        if let status = detectedStatus {
            Task(priority: .background) {
                await CalibrationService.shared.recordRSVPFeedback(detectedStatus: status, wasCorrect: false)
            }
        }
    }

    /// Process a detected RSVP signal from evidence analysis.
    /// Called by the evidence pipeline when a message matches an invited participant.
    /// Compute the RSVP auto-confirm threshold from the cached calibration ledger.
    /// Reads from the synchronous cache — safe to call from @MainActor without async.
    static func computeRSVPThreshold(from ledger: CalibrationLedger) -> Double {
        let keys = ["rsvpAccepted", "rsvpDeclined", "rsvpTentative"]
        var totalCorrect = 0
        var totalWrong = 0

        for key in keys {
            if let stat = ledger.kindStats[key] {
                totalCorrect += stat.actedOn
                totalWrong += stat.dismissed
            }
        }

        let total = totalCorrect + totalWrong
        guard total >= 5 else { return 0.8 }

        let accuracy = Double(totalCorrect) / Double(total)
        return max(0.6, min(0.95, 1.0 - accuracy * 0.5))
    }

    func processRSVPSignal(
        participationID: UUID,
        detectedStatus: RSVPStatus,
        responseQuote: String,
        confidence: Double
    ) throws {
        let threshold = Self.computeRSVPThreshold(from: CalibrationService.cachedLedger)
        let needsConfirmation = confidence < threshold

        try EventRepository.shared.updateRSVP(
            participationID: participationID,
            status: detectedStatus,
            responseQuote: responseQuote,
            detectionConfidence: confidence,
            userConfirmed: !needsConfirmation
        )

        try EventRepository.shared.appendMessage(
            participationID: participationID,
            kind: .rsvpResponse,
            channel: .iMessage, // Will be updated by caller with actual channel
            body: responseQuote,
            isDraft: false
        )

        // Auto-transition draft → inviting on any RSVP activity
        if let participation = try? EventRepository.shared.fetchParticipation(id: participationID),
           let event = participation.event {
            transitionFromDraftIfNeeded(event: event)
        }

        if needsConfirmation {
            logger.debug("Low-confidence RSVP detected (confidence: \(String(format: "%.0f%%", confidence * 100))) — needs user confirmation")
        } else {
            logger.info("RSVP detected: \(detectedStatus.displayName) (confidence: \(String(format: "%.0f%%", confidence * 100)))")

            // Trigger auto-acknowledgment check
            try processAutoAcknowledgment(participationID: participationID)
        }
    }

    /// Check if a confirmed RSVP should trigger an auto-acknowledgment.
    /// When conditions are met, sends the acknowledgment via ComposeService
    /// (direct send if enabled, otherwise system handoff).
    private func processAutoAcknowledgment(participationID: UUID) throws {
        let repo = EventRepository.shared

        guard let participation = try repo.fetchParticipation(id: participationID),
              let event = participation.event,
              let person = participation.person else { return }

        // Check all conditions for auto-ack
        guard event.autoAcknowledgeEnabled,
              participation.priority.allowsAutoAcknowledge,
              !participation.acknowledgmentSent,
              participation.rsvpUserConfirmed else { return }

        let template: String?
        switch participation.rsvpStatus {
        case .accepted:
            template = event.ackAcceptTemplate
        case .declined:
            template = event.ackDeclineTemplate
        default:
            template = nil
        }

        guard let template else { return }

        // Resolve placeholders — use first name only for natural tone.
        // If the display name looks like a phone number (no letters), fall back to "there".
        let name = Self.friendlyFirstName(for: person)
        let dateStr = Self.smartDateTimeString(for: event.startDate)

        let body = template
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{date}", with: dateStr)

        let channel = event.autoAcknowledgeChannel
            ?? participation.inviteChannel
            ?? .iMessage

        // Log the message in the participation's message history
        try repo.appendMessage(
            participationID: participationID,
            kind: .acknowledgment,
            channel: channel,
            body: body,
            isDraft: false
        )

        // Actually deliver the message via ComposeService
        let recipientID = person.phoneAliases.first ?? person.emailCache ?? ""
        guard !recipientID.isEmpty else {
            logger.warning("No recipient identifier for auto-ack to \(name) — logged but not delivered")
            try repo.markAcknowledgmentSent(participationID: participationID, wasAuto: true)
            return
        }

        let compose = ComposeService.shared
        Task {
            var delivered = false
            if compose.directSendEnabled {
                // Direct send — no user interaction required
                switch channel {
                case .iMessage:
                    delivered = await compose.sendDirectIMessage(recipient: recipientID, body: body)
                case .email:
                    let subject = "Re: \(event.title)"
                    delivered = await compose.sendDirectEmail(recipient: recipientID, subject: subject, body: body)
                default:
                    break
                }
            }

            if !delivered {
                // Fall back to system handoff (opens Messages/Mail for user to confirm)
                switch channel {
                case .iMessage:
                    compose.composeIMessage(recipient: recipientID, body: body)
                case .email:
                    compose.composeEmail(recipient: recipientID, subject: nil, body: body)
                case .whatsApp:
                    compose.composeWhatsApp(phone: recipientID, body: body)
                default:
                    compose.copyToClipboard(body)
                }
            }

            logger.debug("Auto-acknowledgment \(delivered ? "sent directly" : "handed off") to \(name) for \(event.title)")
        }

        try repo.markAcknowledgmentSent(participationID: participationID, wasAuto: true)
    }

    // MARK: - Event Update Notifications

    /// Describes what changed in an event update.
    struct EventChangeSummary: Sendable {
        var timeChanged: Bool = false
        var venueChanged: Bool = false
        var joinLinkChanged: Bool = false
        var formatChanged: Bool = false

        var oldStartDate: Date?
        var newStartDate: Date?
        var oldVenue: String?
        var newVenue: String?
        var oldJoinLink: String?
        var newJoinLink: String?
        var oldFormat: EventFormat?
        var newFormat: EventFormat?

        var hasChanges: Bool {
            timeChanged || venueChanged || joinLinkChanged || formatChanged
        }

        /// Human-readable summary of what changed.
        var changeDescription: String {
            var parts: [String] = []
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            if timeChanged, let old = oldStartDate, let new = newStartDate {
                parts.append("Time changed from \(dateFormatter.string(from: old)) to \(dateFormatter.string(from: new))")
            }
            if venueChanged {
                if let new = newVenue, !new.isEmpty {
                    parts.append("Venue changed to \(new)")
                } else {
                    parts.append("Venue removed")
                }
            }
            if joinLinkChanged {
                if let new = newJoinLink, !new.isEmpty {
                    parts.append("Join link updated")
                } else {
                    parts.append("Join link removed")
                }
            }
            if formatChanged, let new = newFormat {
                parts.append("Format changed to \(new.displayName)")
            }
            return parts.joined(separator: ". ")
        }
    }

    /// Audience options for update notifications.
    enum UpdateAudience: String, CaseIterable, Sendable {
        case allContacted = "Everyone Contacted"
        case acceptedOnly = "Accepted Only"
        case includeDeclined = "Include Declined"

        var description: String {
            switch self {
            case .allContacted: return "Invited, accepted, and tentative"
            case .acceptedOnly: return "Only those who accepted"
            case .includeDeclined: return "Everyone, including those who declined"
            }
        }
    }

    /// Filter participants based on audience selection.
    func participantsForUpdate(event: SamEvent, audience: UpdateAudience) -> [EventParticipation] {
        event.participations.filter { p in
            switch audience {
            case .allContacted:
                return p.inviteStatus != .notInvited && p.rsvpStatus != .declined
            case .acceptedOnly:
                return p.rsvpStatus == .accepted
            case .includeDeclined:
                return p.inviteStatus != .notInvited
            }
        }
    }

    /// Generate an update notification message for a participant.
    func generateUpdateText(
        for participation: EventParticipation,
        changes: EventChangeSummary,
        channel: CommunicationChannel? = nil
    ) async throws -> String {
        guard let event = participation.event, let person = participation.person else {
            throw EventCoordinatorError.missingData
        }
        let resolvedChannel = channel ?? participation.inviteChannel ?? preferredInviteChannel(for: person)
        return try await generateUpdateNotification(
            event: event,
            person: person,
            changes: changes,
            channel: resolvedChannel
        )
    }

    /// Send an update notification for a participant.
    func sendUpdateNotification(for participation: EventParticipation, body: String, channel: CommunicationChannel? = nil) throws {
        guard let person = participation.person else { return }
        let channel = channel ?? participation.inviteChannel ?? preferredInviteChannel(for: person)

        // Resolve recipient address based on channel
        let recipientID: String
        switch channel {
        case .email:
            recipientID = person.emailCache ?? person.phoneAliases.first ?? ""
        case .iMessage:
            recipientID = person.phoneAliases.first ?? person.emailCache ?? ""
        case .whatsApp:
            recipientID = person.phoneAliases.first ?? ""
        default:
            recipientID = person.phoneAliases.first ?? person.emailCache ?? ""
        }

        try EventRepository.shared.appendMessage(
            participationID: participation.id,
            kind: .update,
            channel: channel,
            body: body,
            isDraft: false
        )

        let compose = ComposeService.shared
        if compose.directSendEnabled {
            Task {
                var delivered = false
                switch channel {
                case .iMessage:
                    delivered = await compose.sendDirectIMessage(recipient: recipientID, body: body)
                case .email:
                    let subject = "Update: \(participation.event?.title ?? "Event")"
                    delivered = await compose.sendDirectEmail(recipient: recipientID, subject: subject, body: body)
                default:
                    break
                }
                if !delivered {
                    deliverViaSystemHandoff(channel: channel, recipient: recipientID, body: body)
                }
            }
        } else {
            deliverViaSystemHandoff(channel: channel, recipient: recipientID, body: body)
        }
    }

    /// Generate an AI-powered update notification referencing specific changes.
    private func generateUpdateNotification(
        event: SamEvent,
        person: SamPerson,
        changes: EventChangeSummary,
        channel: CommunicationChannel
    ) async throws -> String {
        let firstName = Self.friendlyFirstName(for: person)
        let eventDetails = buildEventDetails(event: event)
        let isWarm = isWarmRelationship(person: person)
        let senderName = AIService.senderName(forWarmRelationship: isWarm)
        let closing = AIService.closing(forMessageKind: "update", isWarm: isWarm)

        let channelGuidelines: String
        switch channel {
        case .email:
            channelGuidelines = """
                FORMAT: Email
                - Start with "Hi \(firstName),"
                - Clearly state this is an update to "\(event.title)"
                - Describe what changed in a friendly, clear way
                - Include the updated event details (date, time, venue/link)
                - If they already RSVP'd, reassure them and ask if the change affects their plans
                - Sign off with exactly: "\(closing)\\n\(senderName)"
                """
        case .iMessage, .whatsApp:
            channelGuidelines = """
                FORMAT: Text message
                - NO greeting or sign-off
                - Lead with "Quick update on \(event.title):" or similar
                - State what changed concisely
                - Include the updated details
                - End with something like "Hope that still works for you!" or "Let me know if that changes anything"
                - Keep it to 2-4 sentences
                """
        default:
            channelGuidelines = """
                FORMAT: Short message
                - State what changed concisely
                - Include updated details
                """
        }

        let prompt = """
            Write an update notification for someone who was previously invited to this event. \
            The event details have changed and you need to inform them.

            EVENT (updated details):
            \(eventDetails)

            WHAT CHANGED:
            \(changes.changeDescription)

            RECIPIENT: \(firstName)

            SENDER: \(AIService.userFullName)

            \(channelGuidelines)

            GUIDELINES:
            - Be warm and apologetic about the change — people rearranged their schedules
            - Make the change obvious and easy to spot
            - Do NOT pressure them to still attend
            - If the time changed, emphasize the new date/time prominently

            Return only the notification text.
            """

        let persona = await BusinessProfileService.shared.personaFragment()

        let systemInstruction = """
            You are a warm, professional communication assistant for \(persona). \
            You write clear, considerate update messages that respect people's time and prior commitments.
            """

        return try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: systemInstruction,
            maxTokens: 1024
        )
    }

    // MARK: - Reminders

    /// Generate pre-event reminder drafts for all confirmed attendees.
    /// Called by OutcomeEngine at configured intervals (7 days, 1 day, 10 minutes).
    func generateReminderDrafts(for event: SamEvent, minutesBefore: Int) async throws -> Int {
        let accepted = event.participations.filter { $0.rsvpStatus == .accepted }
        guard !accepted.isEmpty else { return 0 }

        var count = 0
        for participation in accepted {
            guard let person = participation.person else { continue }

            let draft = try await generateReminder(
                event: event,
                person: person,
                minutesBefore: minutesBefore
            )

            let channel = participation.inviteChannel ?? preferredInviteChannel(for: person)

            try EventRepository.shared.appendMessage(
                participationID: participation.id,
                kind: .reminder,
                channel: channel,
                body: draft,
                isDraft: true
            )
            count += 1
        }

        logger.debug("Generated \(count) reminder drafts (\(minutesBefore) min before) for \(event.title)")
        return count
    }

    /// Generate a single reminder message.
    private func generateReminder(
        event: SamEvent,
        person: SamPerson,
        minutesBefore: Int
    ) async throws -> String {
        let name = Self.friendlyFirstName(for: person)

        // For last-minute reminders, keep it short with the join link
        if minutesBefore <= 15 {
            if let link = event.joinLink {
                return "Hi \(name) — starting in \(minutesBefore) minutes! Join here: \(link)"
            } else if let venue = event.venue {
                return "Hi \(name) — see you in \(minutesBefore) minutes at \(venue)!"
            }
        }

        let eventDetails = buildEventDetails(event: event)
        let timeframe = minutesBefore >= 1440 ? "\(minutesBefore / 1440) day(s)" : "\(minutesBefore / 60) hour(s)"

        let prompt = """
            Write a brief, friendly reminder for this event happening in \(timeframe).

            EVENT: \(eventDetails)
            RECIPIENT: \(name)

            Keep it to 2-3 sentences. Include the key logistics (time, location/link).
            Be warm but not pushy. Return only the message text.
            """

        return try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: "You write brief, friendly event reminders. Be concise and helpful.",
            maxTokens: 256
        )
    }

    // MARK: - Post-Event Follow-Up

    /// Generate post-event follow-up drafts based on attendance and RSVP status.
    /// Called after the event is marked complete.
    func generateFollowUpDrafts(for event: SamEvent, workshopNotes: String? = nil) async throws -> Int {
        var count = 0

        for participation in event.participations {
            guard let person = participation.person else { continue }

            let followUpKind: FollowUpKind
            switch (participation.rsvpStatus, participation.attended) {
            case (.accepted, true), (_, true):
                followUpKind = .attended
            case (.accepted, false):
                followUpKind = .noShow
            case (.declined, _):
                followUpKind = .declined
            case (.noResponse, _):
                continue // No follow-up for non-responders
            default:
                continue
            }

            let draft = try await generateFollowUp(
                event: event,
                person: person,
                kind: followUpKind,
                workshopNotes: workshopNotes
            )

            let channel = participation.inviteChannel ?? preferredInviteChannel(for: person)

            try EventRepository.shared.appendMessage(
                participationID: participation.id,
                kind: .followUp,
                channel: channel,
                body: draft,
                isDraft: true
            )
            count += 1
        }

        logger.debug("Generated \(count) follow-up drafts for \(event.title)")
        return count
    }

    private enum FollowUpKind: String {
        case attended
        case noShow
        case declined
    }

    private func generateFollowUp(
        event: SamEvent,
        person: SamPerson,
        kind: FollowUpKind,
        workshopNotes: String?
    ) async throws -> String {
        let personContext = buildPersonContext(person: person)
        let notesContext = workshopNotes.map { "WORKSHOP NOTES:\n\($0)" } ?? ""

        let kindGuidelines: String
        switch kind {
        case .attended:
            kindGuidelines = """
                This person ATTENDED the event. Reference something specific from the workshop \
                if notes are available. Transition naturally toward a 1:1 conversation — suggest \
                coffee, a call, or a follow-up meeting. This is a conversion opportunity.
                """
        case .noShow:
            kindGuidelines = """
                This person ACCEPTED but DID NOT ATTEND. Be warm and understanding — no guilt. \
                Offer to share a brief summary of what was covered. Leave the door open for future events.
                """
        case .declined:
            kindGuidelines = """
                This person DECLINED the invitation. Keep it very light — just a brief check-in. \
                Mention you're planning future events. Only send this if the relationship warrants it.
                """
        }

        let prompt = """
            Write a post-event follow-up message.

            EVENT: \(event.title) on \(event.startDate.formatted(date: .abbreviated, time: .omitted))
            PERSON: \(personContext)
            \(notesContext)

            FOLLOW-UP TYPE: \(kind.rawValue)
            \(kindGuidelines)

            Keep it to 3-5 sentences. Be genuine, not salesy.
            Do NOT promise financial outcomes or use pressure tactics.
            Return only the message text.
            """

        let persona = await BusinessProfileService.shared.personaFragment()

        return try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: "You write warm, genuine follow-up messages for \(persona). " +
                "You understand that post-event follow-up is about deepening relationships, not hard selling.",
            maxTokens: 512
        )
    }

    // MARK: - Cross-Event Deduplication

    /// Check if a person has active invitation sequences for other upcoming events.
    /// Returns the events they're already invited to.
    func activeInvitations(for person: SamPerson) throws -> [SamEvent] {
        let participations = try EventRepository.shared.activeEventParticipations(for: person.id)
        return participations.compactMap { $0.event }
    }

    /// Check if inviting a person would conflict with existing event invitations.
    /// Returns nil if safe to invite, or a warning message if there's a conflict.
    func invitationConflictCheck(person: SamPerson, event: SamEvent) throws -> String? {
        let active = try activeInvitations(for: person)
        let otherEvents = active.filter { $0.id != event.id }
        guard !otherEvents.isEmpty else { return nil }

        let names = otherEvents.map { $0.title }.joined(separator: ", ")
        let personName = person.displayNameCache ?? "This person"
        return "\(personName) already has active invitations for: \(names). Consider mentioning both events in one message."
    }

    // MARK: - Invitation Suggestions

    /// Suggest contacts from the active list who would be relevant for this event.
    /// Uses event description, format, and person roles/interaction history to rank.
    func suggestInvitationList(
        for event: SamEvent,
        limit: Int = 30
    ) async throws -> [(person: SamPerson, reason: String)] {
        let allPeople = try PeopleRepository.shared.fetchAll()
        let activePeople = allPeople.filter { $0.lifecycleStatus == .active && !$0.isMe }

        // Exclude people already participating in this event
        let existingIDs = Set(event.participations.compactMap { $0.person?.id })
        let candidates = activePeople.filter { !existingIDs.contains($0.id) }

        guard !candidates.isEmpty else { return [] }

        // Build a concise summary of each candidate for AI ranking
        let eventDetails = buildEventDetails(event: event)
        var candidateLines: [String] = []
        for (index, person) in candidates.prefix(100).enumerated() {
            let roles = person.roleBadges.isEmpty ? "no roles" : person.roleBadges.joined(separator: ", ")
            let name = person.displayNameCache ?? "Unknown"
            candidateLines.append("\(index): \(name) [\(roles)]")
        }

        let prompt = """
            Given the following event, suggest which contacts would be most relevant to invite. \
            Return a JSON array of objects with "index" (integer) and "reason" (short string, 5-10 words). \
            Select up to \(min(limit, candidates.count)) people. Prioritize:
            - Clients and leads for educational/financial workshops
            - Agents and recruits for training events
            - People whose roles match the event topic
            - People who haven't been contacted recently (relationship maintenance)

            EVENT:
            \(eventDetails)

            CANDIDATES:
            \(candidateLines.joined(separator: "\n"))

            Return ONLY valid JSON, no markdown fencing. Example: [{"index": 0, "reason": "Client interested in topic"}]
            """

        let response = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: "You select relevant event attendees from a contact list. Return only valid JSON.",
            maxTokens: 2048
        )

        // Parse AI response
        struct Suggestion: Decodable {
            let index: Int
            let reason: String
        }

        guard let data = response.data(using: .utf8),
              let suggestions = try? JSONDecoder().decode([Suggestion].self, from: data) else {
            // Fallback: return first N candidates with generic reason
            return Array(candidates.prefix(limit)).map { ($0, "Active contact") }
        }

        let cappedCandidates = Array(candidates.prefix(100))
        return suggestions.compactMap { suggestion in
            guard suggestion.index >= 0, suggestion.index < cappedCandidates.count else { return nil }
            return (cappedCandidates[suggestion.index], suggestion.reason)
        }
    }

    // MARK: - Context Builders

    private func buildPersonContext(person: SamPerson) -> String {
        var lines: [String] = []

        if let name = person.displayNameCache {
            lines.append("Name: \(name)")
        }

        if !person.roleBadges.isEmpty {
            lines.append("Roles: \(person.roleBadges.joined(separator: ", "))")
        }

        // Include recent interaction summary if available
        let recentEvidence = person.linkedEvidence
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(3)
        if !recentEvidence.isEmpty {
            let summaries = recentEvidence.map { "\($0.title) (\($0.occurredAt.formatted(date: .abbreviated, time: .omitted)))" }
            lines.append("Recent interactions: \(summaries.joined(separator: "; "))")
        }

        return lines.isEmpty ? "No prior context available." : lines.joined(separator: "\n")
    }

    private func buildEventDetails(event: SamEvent) -> String {
        var lines: [String] = []
        lines.append("Title: \(event.title)")
        if let desc = event.eventDescription { lines.append("Description: \(desc)") }
        lines.append("Format: \(event.format.displayName)")
        lines.append("Date: \(event.startDate.formatted(date: .complete, time: .shortened))")

        let duration = event.endDate.timeIntervalSince(event.startDate) / 60.0
        lines.append("Duration: \(Int(duration)) minutes")

        if let venue = event.venue { lines.append("Venue: \(venue)") }
        if let address = event.address { lines.append("Address: \(address)") }
        if let link = event.joinLink { lines.append("Join Link: \(link)") }
        lines.append("Target Participants: \(event.targetParticipantCount)")

        return lines.joined(separator: "\n")
    }

    /// Produces a natural, context-aware date+time string.
    /// - Same month as today: "1 pm on the 19th"
    /// - Different month, same year: "1 pm on March 19th"
    /// - Different year: "1 pm on March 19th, 2027"
    static func smartDateTimeString(for date: Date) -> String {
        let cal = Calendar.current
        let now = Date.now
        let sameMonth = cal.isDate(date, equalTo: now, toGranularity: .month)
        let sameYear = cal.isDate(date, equalTo: now, toGranularity: .year)

        // Time: "1 pm", "3:30 pm"
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let period = hour >= 12 ? "pm" : "am"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        let timeStr = minute == 0
            ? "\(displayHour) \(period)"
            : "\(displayHour):\(String(format: "%02d", minute)) \(period)"

        // Day ordinal: "19th", "1st", "2nd", "3rd"
        let day = cal.component(.day, from: date)
        let ordinal: String
        switch day {
        case 1, 21, 31: ordinal = "\(day)st"
        case 2, 22:     ordinal = "\(day)nd"
        case 3, 23:     ordinal = "\(day)rd"
        default:        ordinal = "\(day)th"
        }

        if sameMonth {
            return "\(timeStr) on the \(ordinal)"
        } else if sameYear {
            let monthName = cal.monthSymbols[cal.component(.month, from: date) - 1]
            return "\(timeStr) on \(monthName) \(ordinal)"
        } else {
            let monthName = cal.monthSymbols[cal.component(.month, from: date) - 1]
            let year = cal.component(.year, from: date)
            return "\(timeStr) on \(monthName) \(ordinal), \(year)"
        }
    }

    /// Resolve a friendly first name for a person, falling back to "there"
    /// when the display name is missing or looks like a phone number/email handle.
    static func friendlyFirstName(for person: SamPerson) -> String {
        guard let displayName = person.displayNameCache,
              !displayName.isEmpty else { return "there" }

        let firstName = displayName.components(separatedBy: " ").first ?? displayName

        // If the first name has no letters (e.g. a phone number like "5551234567"), use "there"
        guard firstName.contains(where: \.isLetter) else { return "there" }

        return firstName
    }

    private func preferredInviteChannel(for person: SamPerson) -> CommunicationChannel {
        // Prefer the channel with the most recent interaction
        let recent = person.linkedEvidence
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(5)

        var channelCounts: [CommunicationChannel: Int] = [:]
        for evidence in recent {
            switch evidence.source {
            case .iMessage: channelCounts[.iMessage, default: 0] += 1
            case .mail:     channelCounts[.email, default: 0] += 1
            case .whatsApp: channelCounts[.whatsApp, default: 0] += 1
            default: break
            }
        }

        // Return the most-used channel, defaulting to email
        return channelCounts.max(by: { $0.value < $1.value })?.key ?? .email
    }

    private func platformGuidelines(for platform: String) -> String {
        switch platform.lowercased() {
        case "linkedin":
            return """
                Professional tone. 150-250 words. Open with a hook question or bold statement. \
                Include 2-3 relevant hashtags. End with a clear CTA. Mention the registration method.
                """
        case "facebook":
            return """
                Warm, community-focused tone. 100-200 words. Personal story angle about why \
                you're hosting this. Include date/time prominently. Encourage sharing/tagging friends.
                """
        case "substack":
            return """
                Educational newsletter format. 200-400 words. Teaser of what attendees will learn. \
                Include a personal anecdote. Clear CTA with registration details. Frame as exclusive value.
                """
        case "instagram":
            return """
                Short and visual-friendly. 100-150 words. Use line breaks for readability. \
                Include relevant hashtags (5-10). Mention "link in bio" for registration.
                """
        default:
            return "Professional, concise format appropriate for the platform."
        }
    }

    /// Determine if the user has a warm/active relationship with this person.
    /// Warm = 3+ interactions in the last 90 days.
    private func isWarmRelationship(person: SamPerson) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .now
        let recentCount = person.linkedEvidence
            .filter { $0.occurredAt > cutoff }
            .count
        return recentCount >= 3
    }

    // MARK: - Auto-Reply to Unknown Sender Event RSVPs

    /// Scan unknown sender messages for event-matching RSVPs.
    /// If the event has `autoReplyUnknownSenders` enabled and direct send is on,
    /// sends a holding reply. Always posts an OS notification.
    func autoReplyToUnknownEventRSVPs(messages: [(handleID: String, text: String?, date: Date)]) {
        guard let events = try? EventRepository.shared.fetchUpcoming() else { return }
        guard !events.isEmpty else { return }

        for event in events {
            let titleWords = Set(
                event.title.lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { $0.count > 2 }
            )
            guard !titleWords.isEmpty else { continue }

            let attendKeywords = ["attend", "come", "coming", "rsvp", "join", "count me", "i'll be", "sign me", "interested", "want to"]

            for message in messages {
                guard let text = message.text, !text.isEmpty else { continue }
                let textLower = text.lowercased()

                // Check title keyword overlap
                let textWords = Set(textLower.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 })
                let overlap = titleWords.intersection(textWords)
                let threshold = titleWords.count <= 2 ? 1 : 2
                guard overlap.count >= threshold else { continue }

                // Check attendance intent
                guard attendKeywords.contains(where: { textLower.contains($0) }) else { continue }

                // This message matches an event RSVP
                let didAutoReply: Bool

                if (event.autoReplyUnknownSenders || event.autoAcknowledgeEnabled) && ComposeService.shared.directSendEnabled {
                    let holdingReply = "Got your message — I'll get back to you soon!"
                    Task {
                        let sent = await ComposeService.shared.sendDirectIMessage(
                            recipient: message.handleID,
                            body: holdingReply
                        )
                        if sent {
                            self.logger.debug("Auto-replied to unknown sender \(message.handleID) for event \(event.title)")
                        }
                    }
                    didAutoReply = true
                } else {
                    didAutoReply = false
                }

                // Post OS notification
                Task {
                    await SystemNotificationService.shared.postUnknownSenderRSVP(
                        senderHandle: message.handleID,
                        eventTitle: event.title,
                        eventID: event.id,
                        autoReplied: didAutoReply
                    )
                }
            }
        }
    }

    // MARK: - Post-Confirmation Message Generation

    /// Generate a confirmation message for a newly confirmed unknown sender.
    /// Resolves {name} and {date} from the event's ackAcceptTemplate.
    /// If the person has no real name, appends a name-request line.
    func generateConfirmationMessage(for person: SamPerson, event: SamEvent) -> String {
        let name = Self.friendlyFirstName(for: person)
        let dateStr = Self.smartDateTimeString(for: event.startDate)

        var message = event.ackAcceptTemplate
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{date}", with: dateStr)

        // If the person's name resolved to "there" (nameless), ask for their name
        if name == "there" {
            message += "\n\nBy the way, I don't recognize this number — could you share your name?"
        }

        return message
    }

    // MARK: - Reminder Scheduler

    /// Start a background 5-minute polling loop to check for events needing reminders.
    func startReminderScheduler() {
        guard reminderSchedulerTask == nil else { return }
        reminderSchedulerTask = Task(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300)) // 5 minutes
                guard !Task.isCancelled else { break }
                await self.checkAndSendReminders()
            }
        }
        logger.debug("Reminder scheduler started (5-minute interval)")
    }

    /// Stop the reminder scheduler.
    func stopReminderScheduler() {
        reminderSchedulerTask?.cancel()
        reminderSchedulerTask = nil
        logger.debug("Reminder scheduler stopped")
    }

    /// Check all upcoming events for reminder windows and generate/send as needed.
    private func checkAndSendReminders() async {
        guard let events = try? EventRepository.shared.fetchUpcoming() else { return }

        for event in events {
            guard let minutesUntil = event.minutesUntilStart else { continue }

            // 1-day window: fire when between 1440 and 1435 minutes out (catches within 5-min poll)
            if minutesUntil <= 1440 && minutesUntil > 1435 {
                await sendReminderDrafts(for: event, minutesBefore: 1440)
            }

            // 10-minute window (virtual/hybrid only): fire when between 10 and 5 minutes out
            if (event.format == .virtual || event.format == .hybrid),
               minutesUntil <= 10 && minutesUntil > 5 {
                await sendReminderDrafts(for: event, minutesBefore: 10)
            }
        }
    }

    /// Generate and optionally send reminders for an event at a given window.
    private func sendReminderDrafts(for event: SamEvent, minutesBefore: Int) async {
        let accepted = event.participations.filter { $0.rsvpStatus == .accepted }
        guard !accepted.isEmpty else { return }

        // Dedup: skip if reminders already exist for this window
        let windowLabel = minutesBefore >= 1440 ? "1day" : "\(minutesBefore)min"
        for participation in accepted {
            // More robust dedup: check if any reminder was sent/drafted in the last hour
            let recentCutoff = Date.now.addingTimeInterval(-3600)
            let hasRecentReminder = participation.messageLog.contains { msg in
                msg.kind == .reminder && (msg.sentAt ?? .distantPast) > recentCutoff
            }
            if hasRecentReminder { continue }
        }

        do {
            let count = try await generateReminderDrafts(for: event, minutesBefore: minutesBefore)
            guard count > 0 else { return }

            let directSend = ComposeService.shared.directSendEnabled

            if directSend {
                // Auto-send all drafts
                var sentCount = 0
                let refreshedEvent = try? EventRepository.shared.fetch(id: event.id)
                let participations = (refreshedEvent ?? event).participations.filter { $0.rsvpStatus == .accepted }

                for participation in participations {
                    guard let person = participation.person else { continue }
                    // Find the most recent reminder draft
                    guard let draft = participation.messageLog.last(where: { $0.kind == .reminder && $0.isDraft }) else { continue }

                    let handle = person.phoneAliases.first ?? person.emailAliases.first ?? ""
                    guard !handle.isEmpty else { continue }

                    let sent = await ComposeService.shared.sendDirectIMessage(recipient: handle, body: draft.body)
                    if sent {
                        try? EventRepository.shared.markMessageSent(participationID: participation.id, messageID: draft.id)
                        sentCount += 1
                    }
                }

                await SystemNotificationService.shared.postEventReminder(
                    eventTitle: event.title,
                    eventID: event.id,
                    attendeeCount: sentCount,
                    autoSent: true
                )
                logger.debug("Auto-sent \(sentCount) reminders for \(event.title) (\(windowLabel))")
            } else {
                // Drafts only — notify user to review
                await SystemNotificationService.shared.postEventReminder(
                    eventTitle: event.title,
                    eventID: event.id,
                    attendeeCount: count,
                    autoSent: false
                )
                logger.debug("Generated \(count) reminder drafts for \(event.title) (\(windowLabel))")
            }
        } catch {
            logger.error("Failed to generate/send reminders for \(event.title): \(error)")
        }
    }
}

