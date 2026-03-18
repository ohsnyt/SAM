//
//  SAMModels-Event.swift
//  SAM
//
//  Created on March 11, 2026.
//  Event model for workshops, seminars, and group events with RSVP tracking.
//

import Foundation
import SwiftData

// MARK: - SamEvent

/// A user-organized event (workshop, seminar, webinar) with participant tracking,
/// RSVP observation, and personalized invitation/follow-up management.
@Model
public final class SamEvent {
    @Attribute(.unique) public var id: UUID

    // MARK: Core Properties

    public var title: String
    public var eventDescription: String?
    public var startDate: Date
    public var endDate: Date
    public var venue: String?
    public var address: String?
    public var joinLink: String?

    /// "inPerson", "virtual", "hybrid"
    public var formatRawValue: String

    @Transient
    public var format: EventFormat {
        get { EventFormat(rawValue: formatRawValue) ?? .inPerson }
        set { formatRawValue = newValue.rawValue }
    }

    /// "draft", "inviting", "confirmed", "inProgress", "completed", "cancelled"
    public var statusRawValue: String

    @Transient
    public var status: EventStatus {
        get { EventStatus(rawValue: statusRawValue) ?? .draft }
        set {
            statusRawValue = newValue.rawValue
            updatedAt = .now
        }
    }

    public var targetParticipantCount: Int

    // MARK: Auto-Acknowledgment Settings

    /// Whether SAM may auto-send brief RSVP acknowledgments for this event.
    public var autoAcknowledgeEnabled: Bool = false

    /// Channel for auto-acknowledgments. Nil means use the channel the RSVP arrived on.
    public var autoAcknowledgeChannelRawValue: String?

    @Transient
    public var autoAcknowledgeChannel: CommunicationChannel? {
        get { autoAcknowledgeChannelRawValue.flatMap { CommunicationChannel(rawValue: $0) } }
        set { autoAcknowledgeChannelRawValue = newValue?.rawValue }
    }

    /// User-approved template for acceptance acks. Supports {name} and {date} placeholders.
    public var ackAcceptTemplate: String = "Thanks {name}! See you at {date}."

    /// User-approved template for decline acks. Nil means don't auto-ack declines.
    public var ackDeclineTemplate: String?

    /// Whether SAM may auto-reply to unknown senders whose message matches this event.
    /// Independent of `autoAcknowledgeEnabled` (which handles known-contact RSVPs).
    public var autoReplyUnknownSenders: Bool = false

    // MARK: Social Promotion

    /// Per-platform promotion tracking.
    public var socialPromotions: [EventSocialPromotion] = []

    // MARK: Relationships

    @Relationship(deleteRule: .cascade)
    public var participations: [EventParticipation] = []

    /// The presentation used for this event (optional).
    public var presentation: SamPresentation?

    /// Evidence items associated with this event (calendar events, emails, messages).
    @Relationship(deleteRule: .nullify, inverse: \SamEvidenceItem.linkedEvent)
    public var linkedEvidence: [SamEvidenceItem] = []

    /// Notes captured about this event (pre-event prep, post-event debrief).
    @Relationship(deleteRule: .nullify, inverse: \SamNote.linkedEvent)
    public var linkedNotes: [SamNote] = []

    /// Outcomes generated for this event (invitations, reminders, follow-ups).
    @Relationship(deleteRule: .nullify, inverse: \SamOutcome.linkedEvent)
    public var linkedOutcomes: [SamOutcome] = []

    // MARK: Timestamps

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: Computed

    @Transient
    public var isUpcoming: Bool {
        startDate > .now && status != .cancelled
    }

    @Transient
    public var minutesUntilStart: Double? {
        guard isUpcoming else { return nil }
        return startDate.timeIntervalSinceNow / 60.0
    }

    // MARK: Init

    public init(
        id: UUID = UUID(),
        title: String,
        eventDescription: String? = nil,
        format: EventFormat,
        startDate: Date,
        endDate: Date,
        venue: String? = nil,
        address: String? = nil,
        joinLink: String? = nil,
        targetParticipantCount: Int = 20,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.eventDescription = eventDescription
        self.formatRawValue = format.rawValue
        self.statusRawValue = EventStatus.draft.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.venue = venue
        self.address = address
        self.joinLink = joinLink
        self.targetParticipantCount = targetParticipantCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - EventParticipation

/// Join table linking a person to an event with invitation/RSVP state.
@Model
public final class EventParticipation {
    @Attribute(.unique) public var id: UUID

    // MARK: Relationships

    public var person: SamPerson?
    public var event: SamEvent?

    // MARK: Priority & Role

    /// "standard", "key", "vip"
    public var priorityRawValue: String

    @Transient
    public var priority: ParticipantPriority {
        get { ParticipantPriority(rawValue: priorityRawValue) ?? .standard }
        set { priorityRawValue = newValue.rawValue }
    }

    /// Freeform role within the event: "Attendee", "Speaker", "Co-host", "Panelist"
    public var eventRole: String

    // MARK: Invitation State

    /// "notInvited", "draftReady", "invited", "reminderSent"
    public var inviteStatusRawValue: String

    @Transient
    public var inviteStatus: InviteStatus {
        get { InviteStatus(rawValue: inviteStatusRawValue) ?? .notInvited }
        set {
            inviteStatusRawValue = newValue.rawValue
            if newValue == .invited { inviteSentAt = .now }
        }
    }

    /// Channel used to send the invitation.
    public var inviteChannelRawValue: String?

    @Transient
    public var inviteChannel: CommunicationChannel? {
        get { inviteChannelRawValue.flatMap { CommunicationChannel(rawValue: $0) } }
        set { inviteChannelRawValue = newValue?.rawValue }
    }

    public var inviteSentAt: Date?

    // MARK: RSVP State

    /// "pending", "invited", "accepted", "declined", "tentative", "noResponse"
    public var rsvpStatusRawValue: String

    @Transient
    public var rsvpStatus: RSVPStatus {
        get { RSVPStatus(rawValue: rsvpStatusRawValue) ?? .pending }
        set {
            rsvpStatusRawValue = newValue.rawValue
            rsvpUpdatedAt = .now
        }
    }

    /// The raw message text that SAM detected as an RSVP response.
    public var rsvpResponseQuote: String?

    /// Confidence of the RSVP detection (0.0–1.0). Low confidence requires user confirmation.
    public var rsvpDetectionConfidence: Double?

    /// Whether the user has confirmed SAM's RSVP classification.
    public var rsvpUserConfirmed: Bool = false

    // MARK: RSVP Dismiss Tracking

    /// Whether the user dismissed SAM's RSVP detection as incorrect.
    public var rsvpDismissed: Bool = false
    public var rsvpDismissedAt: Date?

    /// Preserves the original AI-detected status so Dismissed rows can show what SAM inferred.
    public var rsvpOriginalDetectedStatusRawValue: String?

    @Transient
    public var rsvpOriginalDetectedStatus: RSVPStatus? {
        get { rsvpOriginalDetectedStatusRawValue.flatMap { RSVPStatus(rawValue: $0) } }
        set { rsvpOriginalDetectedStatusRawValue = newValue?.rawValue }
    }

    public var rsvpUpdatedAt: Date?

    // MARK: Acknowledgment Tracking

    /// Whether an ack was sent (auto or manual) for this person's RSVP.
    public var acknowledgmentSent: Bool = false
    public var acknowledgmentSentAt: Date?
    public var acknowledgmentWasAuto: Bool = false

    // MARK: Message Log

    /// Chronological log of all messages sent/received for this participant regarding this event.
    public var messageLog: [EventMessage] = []

    // MARK: Attendance

    /// Set post-event: did they actually show up?
    public var attended: Bool?

    // MARK: Timestamps

    public var createdAt: Date

    // MARK: Init

    public init(
        id: UUID = UUID(),
        person: SamPerson,
        event: SamEvent,
        priority: ParticipantPriority = .standard,
        eventRole: String = "Attendee",
        createdAt: Date = .now
    ) {
        self.id = id
        self.person = person
        self.event = event
        self.priorityRawValue = priority.rawValue
        self.eventRole = eventRole
        self.inviteStatusRawValue = InviteStatus.notInvited.rawValue
        self.rsvpStatusRawValue = RSVPStatus.pending.rawValue
        self.createdAt = createdAt
    }
}

// MARK: - Embedded Value Types

/// A logged message related to an event participation (invitation, reminder, ack, follow-up).
public struct EventMessage: Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: EventMessageKind
    public var channelRawValue: String
    public var body: String
    public var sentAt: Date?
    public var isDraft: Bool

    public var channel: CommunicationChannel? {
        CommunicationChannel(rawValue: channelRawValue)
    }

    public enum EventMessageKind: String, Codable, Sendable {
        case invitation
        case reminder
        case acknowledgment
        case followUp
        case update
        case rsvpResponse
        case custom
    }

    public init(
        id: UUID = UUID(),
        kind: EventMessageKind,
        channel: CommunicationChannel,
        body: String,
        sentAt: Date? = nil,
        isDraft: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.channelRawValue = channel.rawValue
        self.body = body
        self.sentAt = sentAt
        self.isDraft = isDraft
    }
}

/// Tracks social media promotion activity per platform for an event.
public struct EventSocialPromotion: Codable, Sendable, Identifiable {
    public var id: UUID
    public var platform: String           // "linkedin", "facebook", "substack", "instagram"
    public var draftText: String?
    public var postedAt: Date?
    public var isPosted: Bool

    public init(
        id: UUID = UUID(),
        platform: String,
        draftText: String? = nil,
        postedAt: Date? = nil,
        isPosted: Bool = false
    ) {
        self.id = id
        self.platform = platform
        self.draftText = draftText
        self.postedAt = postedAt
        self.isPosted = isPosted
    }
}

// MARK: - Enums

public enum EventFormat: String, Codable, Sendable, CaseIterable {
    case inPerson
    case virtual
    case hybrid

    public nonisolated var displayName: String {
        switch self {
        case .inPerson: return "In Person"
        case .virtual:  return "Virtual"
        case .hybrid:   return "Hybrid"
        }
    }

    public var icon: String {
        switch self {
        case .inPerson: return "building.2"
        case .virtual:  return "video"
        case .hybrid:   return "rectangle.inset.filled.and.person.filled"
        }
    }
}

public enum EventStatus: String, Codable, Sendable, CaseIterable {
    case draft              // Event created, not yet inviting
    case inviting           // Actively sending invitations
    case confirmed          // Invitations sent, awaiting event date
    case inProgress         // Event is happening now
    case completed          // Event finished
    case cancelled          // Event cancelled

    public var displayName: String {
        switch self {
        case .draft:      return "Draft"
        case .inviting:   return "Inviting"
        case .confirmed:  return "Confirmed"
        case .inProgress: return "In Progress"
        case .completed:  return "Completed"
        case .cancelled:  return "Cancelled"
        }
    }

    public var icon: String {
        switch self {
        case .draft:      return "doc.badge.ellipsis"
        case .inviting:   return "paperplane"
        case .confirmed:  return "checkmark.circle"
        case .inProgress: return "play.circle"
        case .completed:  return "flag.checkered"
        case .cancelled:  return "xmark.circle"
        }
    }
}

public enum ParticipantPriority: String, Codable, Sendable, CaseIterable {
    case standard       // General attendees — auto-ack eligible
    case key            // Referral partners, high-value prospects — personal ack preferred
    case vip            // Speakers, co-hosts — always personal, never auto-ack

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .key:      return "Key"
        case .vip:      return "VIP"
        }
    }

    public var icon: String {
        switch self {
        case .standard: return "person"
        case .key:      return "star"
        case .vip:      return "star.fill"
        }
    }

    /// Whether auto-acknowledgment is permitted for this priority level.
    public var allowsAutoAcknowledge: Bool {
        switch self {
        case .standard: return true
        case .key:      return false    // Personal ack preferred
        case .vip:      return false    // Always personal
        }
    }
}

public enum InviteStatus: String, Codable, Sendable, CaseIterable {
    case notInvited     // Not yet in invitation queue
    case draftReady     // SAM has generated the invitation draft
    case invited        // User marked as sent
    case reminderSent   // Pre-event reminder has been sent

    public var displayName: String {
        switch self {
        case .notInvited:   return "Not Invited"
        case .draftReady:   return "Draft Ready"
        case .invited:      return "Invited"
        case .reminderSent: return "Reminder Sent"
        }
    }
}

public enum RSVPStatus: String, Codable, Sendable, CaseIterable {
    case pending        // Not yet invited (pre-invitation)
    case invited        // Invitation sent, awaiting response
    case accepted       // Confirmed attending
    case declined       // Cannot attend
    case tentative      // Maybe / checking schedule
    case noResponse     // Invitation sent, follow-up sequence exhausted

    public var displayName: String {
        switch self {
        case .pending:    return "Pending"
        case .invited:    return "Invited"
        case .accepted:   return "Accepted"
        case .declined:   return "Declined"
        case .tentative:  return "Tentative"
        case .noResponse: return "No Response"
        }
    }

    public var icon: String {
        switch self {
        case .pending:    return "clock"
        case .invited:    return "paperplane"
        case .accepted:   return "checkmark.circle.fill"
        case .declined:   return "xmark.circle"
        case .tentative:  return "questionmark.circle"
        case .noResponse: return "minus.circle"
        }
    }

    public var color: String {
        switch self {
        case .pending:    return "secondary"
        case .invited:    return "blue"
        case .accepted:   return "green"
        case .declined:   return "red"
        case .tentative:  return "orange"
        case .noResponse: return "gray"
        }
    }
}
