//
//  EventRepository.swift
//  SAM
//
//  Created on March 11, 2026.
//  SwiftData CRUD for SamEvent and EventParticipation records.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EventRepository")

@MainActor
@Observable
final class EventRepository {

    // MARK: - Singleton

    static let shared = EventRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Event CRUD

    /// Create a new event.
    @discardableResult
    func createEvent(
        title: String,
        eventDescription: String? = nil,
        format: EventFormat,
        startDate: Date,
        endDate: Date,
        venue: String? = nil,
        address: String? = nil,
        joinLink: String? = nil,
        targetParticipantCount: Int = 20
    ) throws -> SamEvent {
        guard let context else { throw RepositoryError.notConfigured }

        let event = SamEvent(
            title: title,
            eventDescription: eventDescription,
            format: format,
            startDate: startDate,
            endDate: endDate,
            venue: venue,
            address: address,
            joinLink: joinLink,
            targetParticipantCount: targetParticipantCount
        )
        context.insert(event)
        try context.save()
        logger.debug("Created event: \(title) on \(startDate)")
        return event
    }

    /// Fetch upcoming events (start date in the future, not cancelled), sorted by start date.
    func fetchUpcoming() throws -> [SamEvent] {
        guard let context else { throw RepositoryError.notConfigured }

        let now = Date.now
        let descriptor = FetchDescriptor<SamEvent>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.startDate > now && $0.status != .cancelled }
    }

    /// Fetch the next upcoming event (soonest start date).
    func fetchNext() throws -> SamEvent? {
        try fetchUpcoming().first
    }

    /// Fetch past events (completed or start date passed), sorted by most recent first.
    func fetchPast() throws -> [SamEvent] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamEvent>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let all = try context.fetch(descriptor)
        return all.filter { $0.status == .completed || ($0.startDate <= .now && $0.status != .cancelled) }
    }

    /// Fetch all events.
    func fetchAll() throws -> [SamEvent] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamEvent>(
            sortBy: [SortDescriptor(\.startDate, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetch a single event by ID.
    func fetch(id: UUID) throws -> SamEvent? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamEvent>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    /// Update event properties.
    func updateEvent(
        id: UUID,
        title: String? = nil,
        eventDescription: String? = nil,
        format: EventFormat? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        venue: String? = nil,
        address: String? = nil,
        joinLink: String? = nil,
        targetParticipantCount: Int? = nil,
        status: EventStatus? = nil
    ) throws {
        guard let event = try fetch(id: id) else { throw RepositoryError.notFound }

        if let title { event.title = title }
        if let eventDescription { event.eventDescription = eventDescription }
        if let format { event.format = format }
        if let startDate { event.startDate = startDate }
        if let endDate { event.endDate = endDate }
        if let venue { event.venue = venue }
        if let address { event.address = address }
        if let joinLink { event.joinLink = joinLink }
        if let targetParticipantCount { event.targetParticipantCount = targetParticipantCount }
        if let status { event.status = status }
        event.updatedAt = .now

        try context?.save()
        logger.debug("Updated event \(id): \(event.title)")
    }

    /// Update auto-acknowledgment settings for an event.
    func updateAutoAcknowledge(
        eventID: UUID,
        enabled: Bool,
        channel: CommunicationChannel? = nil,
        acceptTemplate: String? = nil,
        declineTemplate: String? = nil
    ) throws {
        guard let event = try fetch(id: eventID) else { throw RepositoryError.notFound }

        event.autoAcknowledgeEnabled = enabled
        event.autoAcknowledgeChannel = channel
        if let acceptTemplate { event.ackAcceptTemplate = acceptTemplate }
        event.ackDeclineTemplate = declineTemplate
        event.updatedAt = .now

        try context?.save()
        logger.debug("Updated auto-ack settings for event \(eventID): enabled=\(enabled)")
    }

    /// Delete an event and cascade-delete its participations. Captures undo snapshot.
    func deleteEvent(id: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }
        guard let event = try fetch(id: id) else { return }

        // Capture snapshot before deletion
        let snapshot = EventSnapshot(
            id: event.id,
            title: event.title,
            eventDescription: event.eventDescription,
            formatRawValue: event.formatRawValue,
            statusRawValue: event.statusRawValue,
            startDate: event.startDate,
            endDate: event.endDate,
            venue: event.venue,
            joinLink: event.joinLink,
            targetParticipantCount: event.targetParticipantCount,
            autoAcknowledgeEnabled: event.autoAcknowledgeEnabled,
            ackAcceptTemplate: event.ackAcceptTemplate,
            ackDeclineTemplate: event.ackDeclineTemplate,
            participantPersonIDs: fetchParticipations(for: event).compactMap { $0.person?.id }
        )

        let displayName = event.title

        context.delete(event)
        try context.save()

        if let entry = try? UndoRepository.shared.capture(
            operation: .deleted,
            entityType: .event,
            entityID: snapshot.id,
            entityDisplayName: displayName,
            snapshot: snapshot
        ) {
            UndoCoordinator.shared.showToast(for: entry)
        }

        logger.debug("Deleted event \(id)")
    }

    // MARK: - Social Promotion

    /// Add or update a social promotion draft for an event.
    func upsertSocialPromotion(
        eventID: UUID,
        platform: String,
        draftText: String
    ) throws {
        guard let event = try fetch(id: eventID) else { throw RepositoryError.notFound }

        if let idx = event.socialPromotions.firstIndex(where: { $0.platform == platform }) {
            event.socialPromotions[idx].draftText = draftText
            event.socialPromotions[idx].isPosted = false
            event.socialPromotions[idx].postedAt = nil
        } else {
            let promo = EventSocialPromotion(platform: platform, draftText: draftText)
            event.socialPromotions.append(promo)
        }
        event.updatedAt = .now
        try context?.save()
    }

    /// Mark a social promotion as posted.
    func markSocialPromotionPosted(eventID: UUID, platform: String) throws {
        guard let event = try fetch(id: eventID) else { throw RepositoryError.notFound }

        if let idx = event.socialPromotions.firstIndex(where: { $0.platform == platform }) {
            event.socialPromotions[idx].isPosted = true
            event.socialPromotions[idx].postedAt = .now
        }

        // Auto-transition draft → inviting when a promotion is posted
        if event.status == .draft {
            event.status = .inviting
        }

        event.updatedAt = .now
        try context?.save()
    }

    // MARK: - Participation CRUD

    /// Add a participant to an event.
    @discardableResult
    func addParticipant(
        event: SamEvent,
        person: SamPerson,
        priority: ParticipantPriority = .standard,
        eventRole: String = "Attendee"
    ) throws -> EventParticipation {
        guard let context else { throw RepositoryError.notConfigured }

        // Prevent duplicate participation
        let existing = fetchParticipations(for: event).first { $0.person?.id == person.id }
        if let existing { return existing }

        let participation = EventParticipation(
            person: person,
            event: event,
            priority: priority,
            eventRole: eventRole
        )
        context.insert(participation)
        try context.save()
        logger.debug("Added \(person.displayNameCache ?? "participant") to event \(event.title)")
        return participation
    }

    /// Remove a participant from an event.
    func removeParticipant(participationID: UUID, from event: SamEvent) throws {
        guard let context else { throw RepositoryError.notConfigured }

        guard let participation = fetchParticipations(for: event).first(where: { $0.id == participationID }) else {
            return
        }
        context.delete(participation)
        try context.save()
        logger.debug("Removed participant \(participationID) from event \(event.title)")
    }

    /// Fetch all participations for an event, sorted by priority (VIP first) then name.
    /// Uses a FetchDescriptor query instead of traversing event.participations to avoid
    /// SwiftData assertion crashes from corrupted relationship data.
    func fetchParticipations(for event: SamEvent) -> [EventParticipation] {
        guard let context else { return [] }
        let eventID = event.id
        do {
            let descriptor = FetchDescriptor<EventParticipation>(
                predicate: #Predicate { $0.event?.id == eventID }
            )
            let results = try context.fetch(descriptor)
            return results.sorted { lhs, rhs in
                let lhsPriority = lhs.priority.sortOrder
                let rhsPriority = rhs.priority.sortOrder
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                let lhsName = lhs.person?.displayNameCache ?? ""
                let rhsName = rhs.person?.displayNameCache ?? ""
                return lhsName < rhsName
            }
        } catch {
            logger.error("Failed to fetch participations for event \(event.title): \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch participations filtered by RSVP status.
    func fetchParticipations(for event: SamEvent, rsvpStatus: RSVPStatus) -> [EventParticipation] {
        fetchParticipations(for: event).filter { $0.rsvpStatus == rsvpStatus }
    }

    /// Fetch participations needing user confirmation (low-confidence RSVP detections).
    func fetchUnconfirmedRSVPs(for event: SamEvent) -> [EventParticipation] {
        fetchParticipations(for: event).filter { participation in
            participation.rsvpDetectionConfidence != nil
            && !participation.rsvpUserConfirmed
            && !participation.rsvpDismissed
            && (participation.rsvpDetectionConfidence ?? 1.0) < 0.8
        }
    }

    // MARK: - RSVP Dismiss / Undo

    /// Dismiss a SAM-detected RSVP as incorrect. Preserves the original detection for undo.
    func dismissRSVP(participationID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        // Preserve original detected status
        participation.rsvpOriginalDetectedStatusRawValue = participation.rsvpStatusRawValue

        // Reset to appropriate base status
        participation.rsvpStatus = participation.inviteStatus == .invited ? .invited : .pending
        participation.rsvpDetectionConfidence = nil
        participation.rsvpUserConfirmed = false
        participation.rsvpDismissed = true
        participation.rsvpDismissedAt = .now

        try context.save()
        let name = participation.person?.displayNameCache ?? participationID.uuidString
        logger.debug("Dismissed RSVP for \(name)")
    }

    /// Undo a dismissed RSVP — restore the original detected status.
    func undoDismissRSVP(participationID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        if let originalStatus = participation.rsvpOriginalDetectedStatus {
            participation.rsvpStatus = originalStatus
        }
        participation.rsvpDismissed = false
        participation.rsvpDismissedAt = nil
        participation.rsvpOriginalDetectedStatusRawValue = nil

        try context.save()
        let name = participation.person?.displayNameCache ?? participationID.uuidString
        logger.debug("Undid RSVP dismiss for \(name)")
    }

    /// Batch dismiss multiple RSVP detections in a single save.
    func bulkDismissRSVPs(participationIDs: [UUID]) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        let idSet = Set(participationIDs)

        for participation in all where idSet.contains(participation.id) {
            participation.rsvpOriginalDetectedStatusRawValue = participation.rsvpStatusRawValue
            participation.rsvpStatus = participation.inviteStatus == .invited ? .invited : .pending
            participation.rsvpDetectionConfidence = nil
            participation.rsvpUserConfirmed = false
            participation.rsvpDismissed = true
            participation.rsvpDismissedAt = .now
        }

        try context.save()
        logger.debug("Bulk dismissed \(participationIDs.count) RSVPs")
    }

    /// Fetch participations eligible for auto-acknowledgment.
    func fetchPendingAutoAcks(for event: SamEvent) -> [EventParticipation] {
        guard event.autoAcknowledgeEnabled else { return [] }
        return fetchParticipations(for: event).filter { participation in
            !participation.acknowledgmentSent
            && participation.priority.allowsAutoAcknowledge
            && (participation.rsvpStatus == .accepted || participation.rsvpStatus == .declined)
            && participation.rsvpUserConfirmed
        }
    }

    /// Fetch a single participation by ID.
    func fetchParticipation(id: UUID) throws -> EventParticipation? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        return all.first { $0.id == id }
    }

    // MARK: - RSVP Updates

    /// Update RSVP status for a participation, optionally with detected response quote.
    func updateRSVP(
        participationID: UUID,
        status: RSVPStatus,
        responseQuote: String? = nil,
        detectionConfidence: Double? = nil,
        userConfirmed: Bool = false
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        participation.rsvpStatus = status
        if let responseQuote { participation.rsvpResponseQuote = responseQuote }
        if let detectionConfidence { participation.rsvpDetectionConfidence = detectionConfidence }
        participation.rsvpUserConfirmed = userConfirmed

        try context.save()
        let name = participation.person?.displayNameCache ?? participationID.uuidString
        logger.debug("RSVP update: \(name) → \(status.displayName)")
    }

    /// Confirm a SAM-detected RSVP classification.
    func confirmRSVP(participationID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        participation.rsvpUserConfirmed = true
        try context.save()
    }

    /// Mark an invitation as sent for a participation.
    func markInviteSent(
        participationID: UUID,
        channel: CommunicationChannel
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        participation.inviteStatus = .invited
        participation.inviteChannel = channel
        participation.rsvpStatus = .invited
        try context.save()
    }

    /// Mark acknowledgment sent for a participation.
    func markAcknowledgmentSent(
        participationID: UUID,
        wasAuto: Bool
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        participation.acknowledgmentSent = true
        participation.acknowledgmentSentAt = .now
        participation.acknowledgmentWasAuto = wasAuto
        try context.save()
    }

    /// Record attendance post-event.
    func markAttendance(participationID: UUID, attended: Bool) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        participation.attended = attended
        try context.save()
    }

    // MARK: - Message Log

    /// Append a message to a participation's message log.
    func appendMessage(
        participationID: UUID,
        kind: EventMessage.EventMessageKind,
        channel: CommunicationChannel,
        body: String,
        isDraft: Bool = true
    ) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        let message = EventMessage(kind: kind, channel: channel, body: body, isDraft: isDraft)
        participation.messageLog.append(message)
        try context.save()
    }

    /// Mark a draft message as sent.
    func markMessageSent(participationID: UUID, messageID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        guard let participation = all.first(where: { $0.id == participationID }) else {
            throw RepositoryError.notFound
        }

        if let idx = participation.messageLog.firstIndex(where: { $0.id == messageID }) {
            participation.messageLog[idx].isDraft = false
            participation.messageLog[idx].sentAt = .now
        }
        try context.save()
    }

    // MARK: - Cross-Event Queries

    /// Check if a person is already invited to any upcoming event (for deduplication).
    func activeEventParticipations(for personID: UUID) throws -> [EventParticipation] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        return all.filter { participation in
            participation.person?.id == personID
            && participation.event?.isUpcoming == true
            && participation.inviteStatus != .notInvited
        }
    }

    /// Fetch all events a person is participating in.
    func events(for personID: UUID) throws -> [SamEvent] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<EventParticipation>()
        let all = try context.fetch(descriptor)
        return all
            .filter { $0.person?.id == personID }
            .compactMap { $0.event }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Errors

    enum RepositoryError: Error, LocalizedError {
        case notConfigured
        case notFound

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "EventRepository not configured. Call configure(container:) first."
            case .notFound:
                return "Event or participation not found."
            }
        }
    }

    // MARK: - Data Integrity Check

    /// Run at app startup to detect and repair corrupted SwiftData relationships.
    /// Deletes orphaned EventParticipation records that cause SIGTRAP crashes
    /// when SwiftData tries to resolve relationship backing data.
    ///
    /// Uses predicate-based queries (translated to SQL) to avoid materializing
    /// relationships in Swift, which is exactly what triggers the crash.
    func repairIntegrity() {
        guard let context else {
            logger.warning("repairIntegrity: not configured")
            return
        }

        do {
            // Step 1: Collect all valid event IDs
            let eventDescriptor = FetchDescriptor<SamEvent>()
            let allEvents = try context.fetch(eventDescriptor)
            let validEventIDs = Set(allEvents.map(\.id))

            // Step 2: Find orphaned participations (event is nil) via predicate
            // The predicate is evaluated at the SQL level, not by materializing
            // the relationship in Swift — so this is safe even with corrupted data.
            let orphanDescriptor = FetchDescriptor<EventParticipation>(
                predicate: #Predicate { $0.event == nil }
            )
            let orphanedNil = try context.fetch(orphanDescriptor)

            // Step 3: Find participations referencing non-existent events.
            // For each valid event, collect its participation IDs.
            var validParticipationIDs = Set<UUID>()
            for eventID in validEventIDs {
                let desc = FetchDescriptor<EventParticipation>(
                    predicate: #Predicate { $0.event?.id == eventID }
                )
                let parts = try context.fetch(desc)
                for p in parts {
                    validParticipationIDs.insert(p.id)
                }
            }

            // Fetch ALL participation IDs. Any not in validParticipationIDs
            // and not in orphanedNil are referencing nonexistent events.
            let allDescriptor = FetchDescriptor<EventParticipation>()
            let allParticipations = try context.fetch(allDescriptor)
            let orphanedNilIDs = Set(orphanedNil.map(\.id))
            let orphanedDangling = allParticipations.filter {
                !validParticipationIDs.contains($0.id) && !orphanedNilIDs.contains($0.id)
            }

            let toDelete = orphanedNil + orphanedDangling
            if !toDelete.isEmpty {
                for participation in toDelete {
                    context.delete(participation)
                }
                try context.save()
                logger.notice("repairIntegrity: deleted \(toDelete.count) orphaned EventParticipation record(s) (\(orphanedNil.count) nil-event, \(orphanedDangling.count) dangling)")
            } else {
                logger.debug("repairIntegrity: no orphaned participations found")
            }
        } catch {
            logger.error("repairIntegrity failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ParticipantPriority Sort Support

extension ParticipantPriority {
    /// Sort order — VIP first, then key, then standard.
    var sortOrder: Int {
        switch self {
        case .vip:      return 0
        case .key:      return 1
        case .standard: return 2
        }
    }
}
