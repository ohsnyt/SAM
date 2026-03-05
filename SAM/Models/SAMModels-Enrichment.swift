//
//  SAMModels-Enrichment.swift
//  SAM
//
//  Contact enrichment queue — stores proposed field updates sourced from
//  social media imports (LinkedIn, etc.) awaiting user review and Apple
//  Contacts write-back approval.
//

import Foundation
import SwiftData

// MARK: - Supporting enums

/// The contact field being proposed for update.
public enum EnrichmentField: String, Codable, Sendable, CaseIterable {
    case company      = "company"
    case jobTitle     = "jobTitle"
    case email        = "email"
    case phone        = "phone"
    case linkedInURL  = "linkedInURL"
    case facebookURL  = "facebookURL"

    public var displayName: String {
        switch self {
        case .company:     return "Company"
        case .jobTitle:    return "Job Title"
        case .email:       return "Email Address"
        case .phone:       return "Phone Number"
        case .linkedInURL: return "LinkedIn Profile"
        case .facebookURL: return "Facebook Profile"
        }
    }
}

/// Where the enrichment data originated.
public enum EnrichmentSource: String, Codable, Sendable {
    case linkedInConnections           = "linkedInConnections"
    case linkedInEndorsementsReceived  = "linkedInEndorsementsReceived"
    case linkedInEndorsementsGiven     = "linkedInEndorsementsGiven"
    case linkedInRecommendationsGiven  = "linkedInRecommendationsGiven"
    case linkedInInvitations           = "linkedInInvitations"
    case callHistory                   = "callHistory"
    case mailHeaders                   = "mailHeaders"
    case calendarAttendees             = "calendarAttendees"
    case linkedInNotification          = "linkedInNotification"
    case whatsAppMessages              = "whatsAppMessages"

    public var displayName: String {
        switch self {
        case .linkedInConnections:          return "LinkedIn Connections"
        case .linkedInEndorsementsReceived: return "LinkedIn Endorsements"
        case .linkedInEndorsementsGiven:    return "LinkedIn Endorsements"
        case .linkedInRecommendationsGiven: return "LinkedIn Recommendations"
        case .linkedInInvitations:          return "LinkedIn Invitations"
        case .callHistory:                  return "Call History"
        case .mailHeaders:                  return "Mail"
        case .calendarAttendees:            return "Calendar"
        case .linkedInNotification:         return "LinkedIn Notification"
        case .whatsAppMessages:             return "WhatsApp"
        }
    }
}

/// Review status of an enrichment candidate.
public enum EnrichmentStatus: String, Codable, Sendable {
    case pending   = "pending"
    case approved  = "approved"
    case dismissed = "dismissed"
}

// MARK: - PendingEnrichment model

/// A proposed update to one field on one Apple Contact, awaiting user approval.
///
/// Dedup key: (personID + fieldRawValue + proposedValue) — checked by
/// EnrichmentRepository.bulkRecord() before inserting.
@Model
public final class PendingEnrichment {

    @Attribute(.unique) public var id: UUID

    /// ID of the SamPerson this enrichment targets.
    /// Stored as plain UUID (not @Relationship) to avoid cascade complexity.
    public var personID: UUID

    /// The field being proposed.
    public var fieldRawValue: String      // EnrichmentField.rawValue

    /// The new value to write to Apple Contacts.
    public var proposedValue: String

    /// The current value already in Apple Contacts (captured at import time for comparison).
    public var currentValue: String?

    /// Where this data came from.
    public var sourceRawValue: String     // EnrichmentSource.rawValue

    /// Optional extra detail (e.g. "From endorsement of 'Strategic Planning'").
    public var sourceDetail: String?

    /// Review status.
    public var statusRawValue: String     // EnrichmentStatus.rawValue

    public var createdAt: Date
    public var resolvedAt: Date?

    // MARK: Computed transient wrappers

    @Transient public var field: EnrichmentField {
        EnrichmentField(rawValue: fieldRawValue) ?? .company
    }

    @Transient public var source: EnrichmentSource {
        EnrichmentSource(rawValue: sourceRawValue) ?? .linkedInConnections
    }

    @Transient public var status: EnrichmentStatus {
        EnrichmentStatus(rawValue: statusRawValue) ?? .pending
    }

    // MARK: Init

    public init(
        personID: UUID,
        field: EnrichmentField,
        proposedValue: String,
        currentValue: String? = nil,
        source: EnrichmentSource,
        sourceDetail: String? = nil
    ) {
        self.id = UUID()
        self.personID = personID
        self.fieldRawValue = field.rawValue
        self.proposedValue = proposedValue
        self.currentValue = currentValue
        self.sourceRawValue = source.rawValue
        self.sourceDetail = sourceDetail
        self.statusRawValue = EnrichmentStatus.pending.rawValue
        self.createdAt = Date()
        self.resolvedAt = nil
    }
}
