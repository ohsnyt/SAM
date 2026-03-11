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

    // MARK: - Event Lifecycle

    /// Phase 1: Create an event, create a matching Apple Calendar event, and transition to inviting status.
    func createEvent(
        title: String,
        description: String? = nil,
        format: EventFormat,
        startDate: Date,
        duration: TimeInterval = 3600,
        venue: String? = nil,
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
            joinLink: joinLink,
            targetParticipantCount: targetParticipants
        )
        logger.info("Event created: \(title)")

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
            logger.info("Apple Calendar event created: \(eventID)")
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
        logger.info("Added \(participations.count) participants to \(event.title)")
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

        logger.info("Generated \(draftCount) invitation drafts for \(event.title)")
        return draftCount
    }

    /// Generate a personalized invitation for a single person.
    private func generatePersonalizedInvitation(
        event: SamEvent,
        person: SamPerson,
        priority: ParticipantPriority
    ) async throws -> String {
        let personContext = buildPersonContext(person: person)
        let eventDetails = buildEventDetails(event: event)
        let isWarm = isWarmRelationship(person: person)
        let senderName = AIService.senderName(forWarmRelationship: isWarm)
        let closing = AIService.closing(forMessageKind: "invitation", isWarm: isWarm)

        let prompt = """
            Write a personalized invitation for the following event. \
            The invitation should feel warm and individual — not like a mass email.

            EVENT DETAILS:
            \(eventDetails)

            PERSON CONTEXT:
            \(personContext)

            PRIORITY: \(priority.displayName)

            SENDER: \(AIService.userFullName)

            GUIDELINES:
            - Reference something specific from the person's context if available
            - For VIP/speakers: acknowledge their expertise and why their presence matters
            - For standard attendees: focus on what they'll gain from attending
            - Keep it concise: 3-5 sentences for standard, slightly longer for VIP
            - Include the date, time, and venue/link
            - End with a soft ask, not a demand ("Would love to have you there" not "Please confirm")
            - Do NOT promise financial returns or use pressure tactics
            - Sign off with exactly: "\(closing)\n\(senderName)"
            - Write ONLY the message body with sign-off — no subject line

            Return only the invitation text.
            """

        let systemInstruction = """
            You are a warm, professional communication assistant for an independent financial strategist. \
            You write personalized messages that feel genuinely individual — never templated or mass-produced. \
            You understand financial services compliance: never promise returns, never pressure, always educate.
            """

        return try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: systemInstruction,
            maxTokens: 1024
        )
    }

    /// Generate a personalized invitation draft for a single participant (text only, does not save).
    func generateInvitationText(for participation: EventParticipation) async throws -> String {
        guard let event = participation.event, let person = participation.person else {
            throw EventCoordinatorError.missingData
        }
        return try await generatePersonalizedInvitation(
            event: event,
            person: person,
            priority: participation.priority
        )
    }

    /// Save a finalized invitation draft and mark the participation as draft-ready.
    func saveInvitationDraft(for participation: EventParticipation, body: String) throws {
        guard let person = participation.person else { return }
        let channel = preferredInviteChannel(for: person)
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
    func sendInvitation(for participation: EventParticipation, body: String) throws {
        guard let person = participation.person else { return }
        let channel = participation.inviteChannel ?? preferredInviteChannel(for: person)

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

        // Hand off to system compose
        let recipientID = person.phoneAliases.first ?? person.emailCache ?? ""
        switch channel {
        case .iMessage:
            ComposeService.shared.composeIMessage(recipient: recipientID, body: body)
        case .email:
            ComposeService.shared.composeEmail(recipient: recipientID, subject: nil, body: body)
        case .whatsApp:
            ComposeService.shared.composeWhatsApp(phone: recipientID, body: body)
        default:
            // Fallback: copy to clipboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }

        if let event = participation.event, event.status == .draft {
            try? EventRepository.shared.updateEvent(id: event.id, status: .inviting)
        }
    }

    enum EventCoordinatorError: Error, LocalizedError {
        case missingData
        var errorDescription: String? { "Missing event or person data" }
    }

    /// Generate or regenerate an invitation draft for a specific participant.
    func regenerateInvitation(for participation: EventParticipation) async throws {
        guard let event = participation.event, let person = participation.person else { return }

        let draft = try await generatePersonalizedInvitation(
            event: event,
            person: person,
            priority: participation.priority
        )

        let channel = preferredInviteChannel(for: person)

        try EventRepository.shared.appendMessage(
            participationID: participation.id,
            kind: .invitation,
            channel: channel,
            body: draft,
            isDraft: true
        )

        participation.inviteStatus = .draftReady
        logger.info("Regenerated invitation for \(person.displayNameCache ?? "participant")")
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

    /// Process a detected RSVP signal from evidence analysis.
    /// Called by the evidence pipeline when a message matches an invited participant.
    func processRSVPSignal(
        participationID: UUID,
        detectedStatus: RSVPStatus,
        responseQuote: String,
        confidence: Double
    ) throws {
        let needsConfirmation = confidence < 0.8

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

        if needsConfirmation {
            logger.info("Low-confidence RSVP detected (confidence: \(String(format: "%.0f%%", confidence * 100))) — needs user confirmation")
        } else {
            logger.info("RSVP detected: \(detectedStatus.displayName) (confidence: \(String(format: "%.0f%%", confidence * 100)))")

            // Trigger auto-acknowledgment check
            try processAutoAcknowledgment(participationID: participationID)
        }
    }

    /// Check if a confirmed RSVP should trigger an auto-acknowledgment.
    private func processAutoAcknowledgment(participationID: UUID) throws {
        let repo = EventRepository.shared

        guard let participation = try repo.fetchParticipation(id: participationID),
              let event = participation.event else { return }

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

        // Resolve placeholders
        let name = participation.person?.displayNameCache ?? "there"
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let dateStr = dateFormatter.string(from: event.startDate)

        let body = template
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{date}", with: dateStr)

        let channel = event.autoAcknowledgeChannel
            ?? participation.inviteChannel
            ?? .iMessage

        try repo.appendMessage(
            participationID: participationID,
            kind: .acknowledgment,
            channel: channel,
            body: body,
            isDraft: false // Auto-acks are marked as sent immediately
        )

        try repo.markAcknowledgmentSent(participationID: participationID, wasAuto: true)
        logger.info("Auto-acknowledgment sent to \(name) for \(event.title)")
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

        logger.info("Generated \(count) reminder drafts (\(minutesBefore) min before) for \(event.title)")
        return count
    }

    /// Generate a single reminder message.
    private func generateReminder(
        event: SamEvent,
        person: SamPerson,
        minutesBefore: Int
    ) async throws -> String {
        let name = person.displayNameCache ?? "there"

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

        logger.info("Generated \(count) follow-up drafts for \(event.title)")
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

        return try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: "You write warm, genuine follow-up messages for a financial advisor. " +
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
        let activePeople = allPeople.filter { $0.lifecycleStatus == .active && !($0.isMe ?? false) }

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
        if let link = event.joinLink { lines.append("Join Link: \(link)") }
        lines.append("Target Participants: \(event.targetParticipantCount)")

        return lines.joined(separator: "\n")
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
}

