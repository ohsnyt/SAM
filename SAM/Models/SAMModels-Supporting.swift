//
//  SAMModels-Supporting.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//
//  Supporting types for SAMModels.swift
//  - Enums: ContextKind, EvidenceSource, InsightKind, ProductType, etc.
//  - Value types: ParticipantHint, EvidenceSignal, ProposedLink, etc.
//

import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Contact Lifecycle
// ─────────────────────────────────────────────────────────────────────

public enum ContactLifecycleStatus: String, Codable, Sendable, CaseIterable {
    case active
    case archived
    case dnc          // Do Not Contact
    case deceased
}

extension ContactLifecycleStatus {
    public var displayName: String {
        switch self {
        case .active:   return "Active"
        case .archived: return "Archived"
        case .dnc:      return "Do Not Contact"
        case .deceased: return "Deceased"
        }
    }

    public var icon: String {
        switch self {
        case .active:   return "person.fill"
        case .archived: return "archivebox"
        case .dnc:      return "hand.raised"
        case .deceased: return "heart.slash"
        }
    }

    public var bannerColor: (foreground: String, background: String) {
        switch self {
        case .active:   return ("green", "green")
        case .archived: return ("orange", "orange")
        case .dnc:      return ("red", "red")
        case .deceased: return ("gray", "gray")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Context Types
// ─────────────────────────────────────────────────────────────────────

public enum ContextKind: String, Codable, Sendable {
    case household = "Household"
    case business = "Business"
    case recruiting = "Recruiting"
    case personalPlanning = "Personal Planning"
    case agentTeam = "Agent Team"
    case agentExternal = "External Agent"
    case referralPartner = "Referral Partner"
    case vendor = "Vendor"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Deduced Relation Types
// ─────────────────────────────────────────────────────────────────────

public enum DeducedRelationType: String, Codable, Sendable, CaseIterable {
    case spouse
    case parent
    case child
    case sibling
    case other
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Evidence Types
// ─────────────────────────────────────────────────────────────────────

public enum EvidenceSource: String, Codable, Sendable {
    case calendar = "Calendar"
    case mail = "Mail"
    case contacts = "Contacts"
    case note = "Note"
    case manual = "Manual"
    case iMessage = "iMessage"
    case phoneCall = "PhoneCall"
    case faceTime = "FaceTime"
    case linkedIn = "LinkedIn"
    case facebook = "Facebook"
    case substack = "Substack"
    case clipboardCapture = "ClipboardCapture"
    case whatsApp = "WhatsApp"
    case whatsAppCall = "WhatsAppCall"
}

extension EvidenceSource {
    /// Quality weight for relationship health scoring.
    public var qualityWeight: Double {
        switch self {
        case .calendar:  return 3.0   // In-person meetings highest
        case .phoneCall: return 2.5
        case .faceTime:  return 2.5
        case .mail:      return 1.5
        case .iMessage:  return 1.0
        case .linkedIn:  return 1.0
        case .facebook:  return 1.0
        case .note:      return 0.5   // Passive (user notes about person)
        case .substack:  return 0.5   // Passive (subscribing isn't direct interaction)
        case .contacts:  return 0.0   // Not an interaction
        case .manual:    return 1.0
        case .clipboardCapture: return 1.5  // Direct conversation evidence
        case .whatsApp:  return 1.0   // Same as iMessage
        case .whatsAppCall: return 2.5 // Same as phoneCall
        }
    }

    /// Whether this source represents a direct interaction (not passive data).
    public var isInteraction: Bool {
        switch self {
        case .contacts, .note, .substack:   return false
        default:                            return true
        }
    }

    /// SF Symbol name for use in UI.
    public var iconName: String {
        switch self {
        case .calendar:  return "calendar"
        case .mail:      return "envelope"
        case .contacts:  return "person.crop.circle"
        case .note:      return "square.and.pencil"
        case .manual:    return "pencil"
        case .iMessage:  return "message"
        case .phoneCall: return "phone"
        case .faceTime:  return "video"
        case .linkedIn:  return "network"
        case .facebook:  return "person.2.fill"
        case .substack:  return "newspaper.fill"
        case .clipboardCapture: return "doc.on.clipboard"
        case .whatsApp:  return "text.bubble"
        case .whatsAppCall: return "phone.bubble"
        }
    }

    /// Display label for use in UI.
    public var displayName: String {
        switch self {
        case .whatsAppCall: return "WhatsApp Call"
        default: return rawValue
        }
    }
}

public enum EvidenceTriageState: String, Codable, Sendable {
    case needsReview = "needsReview"
    case done = "done"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Product Types
// ─────────────────────────────────────────────────────────────────────

public enum ProductType: String, Codable, Sendable {
    case lifeInsurance = "Life Insurance"
    case annuity = "Annuity"
    case retirement401k = "401(k)"
    case retirementIRA = "IRA"
    case disability = "Disability Insurance"
    case longTermCare = "Long-Term Care"
    case other = "Other"
}

public enum CoverageRole: String, Codable, Sendable {
    case primaryInsured = "Primary Insured"
    case beneficiary = "Beneficiary"
    case contingentBeneficiary = "Contingent Beneficiary"
    case owner = "Owner"
    case payor = "Payor"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Consent & Compliance
// ─────────────────────────────────────────────────────────────────────

public enum ConsentStatus: String, Codable, Sendable {
    case required = "Required"
    case pending = "Pending"
    case satisfied = "Satisfied"
    case revoked = "Revoked"
    case notRequired = "Not Required"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Joint Interest
// ─────────────────────────────────────────────────────────────────────

public enum JointInterestType: String, Codable, Sendable {
    case jointTenancy = "Joint Tenancy"
    case tenancyInCommon = "Tenancy in Common"
    case communityProperty = "Community Property"
    case trust = "Trust"
    case other = "Other"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Insight Types
// ─────────────────────────────────────────────────────────────────────

public enum InsightKind: String, Codable, Sendable {
    case relationshipAtRisk = "Relationship at Risk"
    case consentMissing = "Consent Missing"
    case complianceWarning = "Compliance Warning"
    case opportunity = "Opportunity"
    case followUpNeeded = "Follow-Up Needed"
    case informational = "Informational"
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Value Types (Embedded in Models)
// ─────────────────────────────────────────────────────────────────────

/// Participant information extracted from calendar events or messages
public struct ParticipantHint: Codable, Sendable {
    public var displayName: String
    public var isOrganizer: Bool
    public var isVerified: Bool      // True if matched to CNContact
    public var rawEmail: String?

    public init(displayName: String, isOrganizer: Bool = false, isVerified: Bool = false, rawEmail: String? = nil) {
        self.displayName = displayName
        self.isOrganizer = isOrganizer
        self.isVerified = isVerified
        self.rawEmail = rawEmail
    }

    /// Live status computed from the current People list.
    /// - `isKnown`: email matches any SamPerson (green checkmark in UI)
    /// - `hasAppleContact`: matched SamPerson has a contactIdentifier (no "Not in Contacts" capsule)
    public struct Status {
        public let isKnown: Bool
        public let hasAppleContact: Bool
        public let matchedPerson: SamPerson?
    }

    /// Compute participant status against a given set of people.
    public func status(against people: [SamPerson]) -> Status {
        guard let raw = rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return Status(isKnown: false, hasAppleContact: false, matchedPerson: nil)
        }

        let matched = people.first { person in
            if let primary = person.emailCache?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               primary == raw { return true }
            return person.emailAliases.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == raw
            }
        }

        if let matched {
            return Status(isKnown: true, hasAppleContact: matched.contactIdentifier != nil, matchedPerson: matched)
        }
        return Status(isKnown: false, hasAppleContact: false, matchedPerson: nil)
    }
}

/// Deterministic signal extracted from evidence
public struct EvidenceSignal: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: SignalType
    public var message: String
    public var confidence: Double
    
    public init(id: UUID = UUID(), type: SignalType, message: String, confidence: Double) {
        self.id = id
        self.type = type
        self.message = message
        self.confidence = confidence
    }
    
    public enum SignalType: String, Codable, Sendable {
        case relationshipChange = "Relationship Change"
        case financialEvent = "Financial Event"
        case lifeEvent = "Life Event"
        case contactFrequency = "Contact Frequency"
        case complianceRisk = "Compliance Risk"
        case opportunity = "Opportunity"
        case eventRSVP = "Event RSVP"
    }
}

/// AI-proposed link between evidence and entity
public struct ProposedLink: Codable, Sendable, Identifiable {
    public var id: UUID
    public var targetType: TargetType
    public var targetID: UUID
    public var targetName: String
    public var reason: String
    public var confidence: Double
    public var status: LinkStatus
    
    public init(
        id: UUID = UUID(),
        targetType: TargetType,
        targetID: UUID,
        targetName: String,
        reason: String,
        confidence: Double,
        status: LinkStatus = .pending
    ) {
        self.id = id
        self.targetType = targetType
        self.targetID = targetID
        self.targetName = targetName
        self.reason = reason
        self.confidence = confidence
        self.status = status
    }
    
    public enum TargetType: String, Codable, Sendable {
        case person = "Person"
        case context = "Context"
    }
    
    public enum LinkStatus: String, Codable, Sendable {
        case pending = "Pending"
        case accepted = "Accepted"
        case declined = "Declined"
    }
}

/// Lightweight context chip for person list view
public struct ContextChip: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ContextKind
    public var icon: String
    
    public init(id: UUID, name: String, kind: ContextKind, icon: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.icon = icon
    }
    
    public var kindDisplay: String {
        kind.rawValue
    }
}

/// Recent interaction chip for person detail view
public struct InteractionChip: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: String
    public var icon: String
    public var timestamp: Date
    public var title: String
    
    public init(id: UUID = UUID(), type: String, icon: String, timestamp: Date, title: String) {
        self.id = id
        self.type = type
        self.icon = icon
        self.timestamp = timestamp
        self.title = title
    }
}

/// Product card for context detail view
public struct ContextProductModel: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: ProductType
    public var name: String
    public var subtitle: String?
    public var statusDisplay: String
    public var icon: String
    
    public init(
        id: UUID,
        type: ProductType,
        name: String,
        subtitle: String? = nil,
        statusDisplay: String,
        icon: String
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.subtitle = subtitle
        self.statusDisplay = statusDisplay
        self.icon = icon
    }
}

/// Recent interaction model for context detail view
public struct InteractionModel: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: String
    public var icon: String
    public var timestamp: Date
    public var title: String
    public var participants: [String]
    
    public init(
        id: UUID = UUID(),
        type: String,
        icon: String,
        timestamp: Date,
        title: String,
        participants: [String] = []
    ) {
        self.id = id
        self.type = type
        self.icon = icon
        self.timestamp = timestamp
        self.title = title
        self.participants = participants
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Note Analysis Types (Phase H)
// ─────────────────────────────────────────────────────────────────────

/// A person mentioned in a note, extracted by LLM
public struct ExtractedPersonMention: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String                         // As written in the note
    public var role: String?                        // "client", "spouse", "child", "referral source", etc.
    public var relationshipTo: String?              // "spouse of John Smith", "referred by Tom Davis"
    public var contactUpdates: [ContactFieldUpdate] // New info to apply to their Contact record
    public var matchedPersonID: UUID?               // Auto-matched SamPerson (nil = unresolved)
    public var confidence: Double
    
    public init(
        id: UUID = UUID(),
        name: String,
        role: String? = nil,
        relationshipTo: String? = nil,
        contactUpdates: [ContactFieldUpdate] = [],
        matchedPersonID: UUID? = nil,
        confidence: Double
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.relationshipTo = relationshipTo
        self.contactUpdates = contactUpdates
        self.matchedPersonID = matchedPersonID
        self.confidence = confidence
    }
}

/// A single contact field that the LLM says should be added/updated
public struct ContactFieldUpdate: Codable, Sendable {
    public var field: ContactUpdateField
    public var value: String
    public var confidence: Double
    
    public init(field: ContactUpdateField, value: String, confidence: Double) {
        self.field = field
        self.value = value
        self.confidence = confidence
    }
    
    public enum ContactUpdateField: String, Codable, Sendable {
        case birthday, anniversary
        case spouse, child, parent, sibling
        case company, jobTitle
        case phone, email, address
        case nickname
    }
}

/// An actionable item extracted from a note
public struct NoteActionItem: Codable, Sendable, Identifiable {
    public var id: UUID
    public var type: ActionType
    public var description: String                  // What needs to be done
    public var suggestedText: String?               // For messages: draft text
    public var suggestedChannel: MessageChannel?    // SMS, email, phone
    public var urgency: Urgency
    public var linkedPersonName: String?
    public var linkedPersonID: UUID?
    public var status: ActionStatus
    
    public init(
        id: UUID = UUID(),
        type: ActionType,
        description: String,
        suggestedText: String? = nil,
        suggestedChannel: MessageChannel? = nil,
        urgency: Urgency = .standard,
        linkedPersonName: String? = nil,
        linkedPersonID: UUID? = nil,
        status: ActionStatus = .pending
    ) {
        self.id = id
        self.type = type
        self.description = description
        self.suggestedText = suggestedText
        self.suggestedChannel = suggestedChannel
        self.urgency = urgency
        self.linkedPersonName = linkedPersonName
        self.linkedPersonID = linkedPersonID
        self.status = status
    }
    
    public enum ActionType: String, Codable, Sendable {
        case updateContact          // Add/change contact fields
        case sendCongratulations    // Birth, wedding, promotion, etc.
        case sendReminder           // Book meeting, renewal, review, etc.
        case scheduleMeeting        // Follow-up, annual review, etc.
        case createProposal         // Product recommendation
        case updateBeneficiary      // Beneficiary changes needed
        case generalFollowUp        // Generic "circle back on X"
    }
    
    public enum Urgency: String, Codable, Sendable {
        case immediate              // Today
        case soon                   // This week
        case standard               // This month
        case low                    // When convenient
    }
    
    public enum ActionStatus: String, Codable, Sendable {
        case pending
        case completed
        case dismissed
    }
    
    public enum MessageChannel: String, Codable, Sendable {
        case sms, email, phone
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Discovered Relationships (Phase: Role-Aware AI)
// ─────────────────────────────────────────────────────────────────────

/// A relationship between two people discovered by LLM analysis of a note.
/// Stored on SamNote for later review.
public struct DiscoveredRelationship: Codable, Sendable, Identifiable {
    public var id: UUID
    public var personName: String
    public var relationshipType: RelationshipType
    public var relatedTo: String
    public var confidence: Double
    public var status: ReviewStatus

    public init(
        id: UUID = UUID(),
        personName: String,
        relationshipType: RelationshipType,
        relatedTo: String,
        confidence: Double,
        status: ReviewStatus = .pending
    ) {
        self.id = id
        self.personName = personName
        self.relationshipType = relationshipType
        self.relatedTo = relatedTo
        self.confidence = confidence
        self.status = status
    }

    public enum RelationshipType: String, Codable, Sendable {
        case spouseOf = "spouse_of"
        case parentOf = "parent_of"
        case childOf = "child_of"
        case siblingOf = "sibling_of"
        case referralBy = "referral_by"
        case referredTo = "referred_to"
        case businessPartner = "business_partner"

        /// Human-readable label for display
        var displayLabel: String {
            switch self {
            case .spouseOf: return "spouse"
            case .parentOf: return "parent"
            case .childOf: return "child"
            case .siblingOf: return "sibling"
            case .referralBy: return "referred by"
            case .referredTo: return "referred to"
            case .businessPartner: return "business partner"
            }
        }
    }

    public enum ReviewStatus: String, Codable, Sendable {
        case pending
        case accepted
        case dismissed
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Family References (note-discovered relationships)
// ─────────────────────────────────────────────────────────────────────

/// A family or personal relationship reference discovered from notes.
/// Stored on SamPerson to capture relationships with people who may or
/// may not have their own contact record (e.g. "John's brother Mike").
/// When `linkedPersonID` is nil, the graph shows a ghost node.
public struct FamilyReference: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String                     // Name of the related person
    public var relationship: String             // Free-text: "brother", "daughter", "spouse", etc.
    public var linkedPersonID: UUID?            // SamPerson.id if matched, nil for ghost
    public var discoveredAt: Date               // When this reference was first discovered
    public var sourceNoteID: UUID?              // The note that surfaced this relationship

    public init(
        id: UUID = UUID(),
        name: String,
        relationship: String,
        linkedPersonID: UUID? = nil,
        discoveredAt: Date = .now,
        sourceNoteID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.relationship = relationship
        self.linkedPersonID = linkedPersonID
        self.discoveredAt = discoveredAt
        self.sourceNoteID = sourceNoteID
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Life Events (detected in notes)
// ─────────────────────────────────────────────────────────────────────

/// A life event mentioned in a note, detected by LLM analysis.
/// Stored on SamNote for surfacing outreach suggestions.
public struct LifeEvent: Codable, Sendable, Identifiable {
    public var id: UUID
    public var personName: String
    public var eventType: String          // "new_baby", "marriage", "graduation", etc.
    public var eventDescription: String   // Human-readable description
    public var approximateDate: String?   // e.g. "2026-06", "next month"
    public var outreachSuggestion: String?
    public var status: EventStatus

    public init(
        id: UUID = UUID(),
        personName: String,
        eventType: String,
        eventDescription: String,
        approximateDate: String? = nil,
        outreachSuggestion: String? = nil,
        status: EventStatus = .pending
    ) {
        self.id = id
        self.personName = personName
        self.eventType = eventType
        self.eventDescription = eventDescription
        self.approximateDate = approximateDate
        self.outreachSuggestion = outreachSuggestion
        self.status = status
    }

    public enum EventStatus: String, Codable, Sendable {
        case pending
        case actedOn
    }

    /// Known life event type labels for display
    public static let knownTypes: [String: String] = [
        "new_baby": "New Baby",
        "marriage": "Marriage",
        "graduation": "Graduation",
        "job_change": "Job Change",
        "retirement": "Retirement",
        "moving": "Moving",
        "health_issue": "Health Issue",
        "promotion": "Promotion",
        "anniversary": "Anniversary",
        "loss": "Loss",
        "other": "Other"
    ]

    /// Display-friendly event type label
    public var eventTypeLabel: String {
        Self.knownTypes[eventType] ?? eventType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Action Lanes & Communication (Phase O)
// ─────────────────────────────────────────────────────────────────────

/// Which UI flow an outcome should route to when acted on.
public enum ActionLane: String, Codable, Sendable {
    case communicate    // Open compose window (iMessage, email, phone)
    case deepWork       // Block calendar time + open context
    case record         // Open QuickNoteWindowView (existing)
    case call           // Initiate call, offer post-call note
    case schedule       // Create calendar event with attendees
    case reviewGraph    // Navigate to Relationship Graph in focus mode
    case openURL        // Open an external URL + show step-by-step instructions (Phase 6)
}

extension ActionLane {
    public var actionLabel: String {
        switch self {
        case .communicate: return "Send Message"
        case .deepWork:    return "Schedule Work"
        case .record:      return "Write Note"
        case .call:        return "Call"
        case .schedule:    return "Schedule"
        case .reviewGraph: return "Review in Graph"
        case .openURL:     return "Open Settings"
        }
    }

    public var actionIcon: String {
        switch self {
        case .communicate: return "paperplane"
        case .deepWork:    return "calendar.badge.clock"
        case .record:      return "square.and.pencil"
        case .call:        return "phone.arrow.up.right"
        case .schedule:    return "calendar.badge.plus"
        case .reviewGraph: return "circle.grid.cross"
        case .openURL:     return "safari"
        }
    }

    public var displayName: String {
        switch self {
        case .communicate: return "Communicate"
        case .deepWork:    return "Deep Work"
        case .record:      return "Record"
        case .call:        return "Call"
        case .schedule:    return "Schedule"
        case .reviewGraph: return "Review Graph"
        case .openURL:     return "Open URL"
        }
    }
}

/// Communication channel for sending messages.
public enum CommunicationChannel: String, Codable, Sendable, CaseIterable {
    case iMessage, email, phone, faceTime, linkedIn, whatsApp

    public var displayName: String {
        switch self {
        case .iMessage: return "iMessage"
        case .email:    return "Email"
        case .phone:    return "Phone"
        case .faceTime: return "FaceTime"
        case .linkedIn: return "LinkedIn"
        case .whatsApp: return "WhatsApp"
        }
    }

    public var icon: String {
        switch self {
        case .iMessage: return "message"
        case .email:    return "envelope"
        case .phone:    return "phone"
        case .faceTime: return "video"
        case .linkedIn: return "network"
        case .whatsApp: return "text.bubble"
        }
    }
}

// MARK: - MessageCategory

/// Classifies the intent of a communication for channel routing.
public enum MessageCategory: String, Codable, Sendable, CaseIterable {
    case quick      // Short/informal: texts, check-ins, congrats, reminders
    case detailed   // Complex/formal: proposals, documents, analyses
    case social     // Professional networking: LinkedIn, growth outreach

    public var displayName: String {
        switch self {
        case .quick:    return "Quick"
        case .detailed: return "Detailed"
        case .social:   return "Social"
        }
    }

    public var icon: String {
        switch self {
        case .quick:    return "bolt.message"
        case .detailed: return "doc.text"
        case .social:   return "person.2"
        }
    }
}

// MARK: - ContactAddresses

/// Carries all known addresses for a person, enabling channel switching.
public struct ContactAddresses: Codable, Hashable, Sendable {
    public let email: String?
    public let phone: String?
    public let linkedInProfileURL: String?
    public let hasWhatsApp: Bool

    public init(email: String? = nil, phone: String? = nil, linkedInProfileURL: String? = nil, hasWhatsApp: Bool = false) {
        self.email = email
        self.phone = phone
        self.linkedInProfileURL = linkedInProfileURL
        self.hasWhatsApp = hasWhatsApp
    }

    /// Resolve the best address for a given channel.
    public func address(for channel: CommunicationChannel) -> String? {
        switch channel {
        case .iMessage:  return phone ?? email
        case .email:     return email
        case .phone:     return phone
        case .faceTime:  return phone
        case .linkedIn:  return linkedInProfileURL
        case .whatsApp:  return phone
        }
    }

    /// Channels for which this person has a usable address.
    public var availableChannels: [CommunicationChannel] {
        var channels: [CommunicationChannel] = []
        if phone != nil || email != nil { channels.append(.iMessage) }
        if email != nil { channels.append(.email) }
        if phone != nil { channels.append(.phone); channels.append(.faceTime) }
        if linkedInProfileURL != nil { channels.append(.linkedIn) }
        if hasWhatsApp && phone != nil { channels.append(.whatsApp) }
        return channels
    }
}

/// Payload for opening the compose auxiliary window.
public struct ComposePayload: Codable, Hashable, Sendable {
    public let outcomeID: UUID
    public let personID: UUID?
    public let personName: String?
    public let recipientAddress: String
    public let channel: CommunicationChannel
    public let subject: String?
    public let draftBody: String
    public let contextTitle: String
    public let linkedInProfileURL: String?
    public let contactAddresses: ContactAddresses?

    public init(
        outcomeID: UUID,
        personID: UUID?,
        personName: String?,
        recipientAddress: String,
        channel: CommunicationChannel,
        subject: String? = nil,
        draftBody: String,
        contextTitle: String,
        linkedInProfileURL: String? = nil,
        contactAddresses: ContactAddresses? = nil
    ) {
        self.outcomeID = outcomeID
        self.personID = personID
        self.personName = personName
        self.recipientAddress = recipientAddress
        self.channel = channel
        self.subject = subject
        self.draftBody = draftBody
        self.contextTitle = contextTitle
        self.linkedInProfileURL = linkedInProfileURL
        self.contactAddresses = contactAddresses
    }
}

/// Payload for the deep work scheduling sheet.
public struct DeepWorkPayload: Codable, Hashable, Sendable {
    public let outcomeID: UUID
    public let personID: UUID?
    public let personName: String?
    public let title: String
    public let rationale: String
    public let suggestedDurationMinutes: Int

    public init(
        outcomeID: UUID,
        personID: UUID?,
        personName: String?,
        title: String,
        rationale: String,
        suggestedDurationMinutes: Int = 60
    ) {
        self.outcomeID = outcomeID
        self.personID = personID
        self.personName = personName
        self.title = title
        self.rationale = rationale
        self.suggestedDurationMinutes = suggestedDurationMinutes
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Sequence Trigger Conditions (Multi-Step Sequences)
// ─────────────────────────────────────────────────────────────────────

/// Condition that must be met before a sequence step activates.
public enum SequenceTriggerCondition: String, Codable, Sendable {
    case always       // Activate unconditionally after delay
    case noResponse   // Activate only if no communication from person
}

extension SequenceTriggerCondition {
    public var displayName: String {
        switch self {
        case .always:     return "Always"
        case .noResponse: return "If no response"
        }
    }

    public var displayIcon: String {
        switch self {
        case .always:     return "arrow.right.circle"
        case .noResponse: return "clock.badge.questionmark"
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Outcome Types (Phase N)
// ─────────────────────────────────────────────────────────────────────

public enum OutcomeKind: String, Codable, Sendable, CaseIterable {
    case preparation    // Prepare for upcoming meeting/event
    case followUp       // Follow up after interaction
    case proposal       // Build/send a proposal or recommendation
    case outreach       // Reach out to someone going cold
    case growth         // Business growth activity (prospecting, networking)
    case training          // Learning/development activity
    case compliance        // Regulatory or compliance action
    case contentCreation   // Social media / educational content
    case setup             // Platform notification setup guidance (Phase 6)
}

public enum OutcomeStatus: String, Codable, Sendable {
    case pending        // Active, should be shown
    case inProgress     // User acknowledged, working on it
    case completed      // Done
    case dismissed      // User explicitly dismissed
    case expired        // Past deadline, auto-expired
}

/// Action type that maps an outcome to a concrete user action.
public enum OutcomeAction: String, Sendable {
    case captureNote      // Open quick note window
    case openPerson       // Navigate to person detail
    case openEvidence     // Navigate to evidence item
}

extension OutcomeKind {
    /// Default message category for channel routing.
    var messageCategory: MessageCategory {
        switch self {
        case .followUp, .outreach:        return .quick
        case .proposal, .preparation, .training, .compliance, .setup: return .detailed
        case .growth, .contentCreation:   return .social
        }
    }

    var defaultAction: OutcomeAction {
        switch self {
        case .followUp, .preparation: return .captureNote
        case .proposal, .outreach, .growth, .training, .compliance, .contentCreation, .setup: return .openPerson
        }
    }

    var actionLabel: String {
        switch self {
        case .followUp, .preparation: return "Write Note"
        case .contentCreation: return "Draft"
        case .setup: return "Open Settings"
        case .proposal, .outreach, .growth, .training, .compliance: return "View"
        }
    }

    var actionIcon: String {
        switch self {
        case .followUp, .preparation: return "square.and.pencil"
        case .contentCreation: return "text.badge.star"
        case .setup: return "safari"
        case .proposal, .outreach, .growth, .training, .compliance: return "arrow.right.circle"
        }
    }
}

/// Lightweight payload for opening the quick note auxiliary window.
public struct QuickNotePayload: Codable, Hashable, Sendable {
    public let outcomeID: UUID
    public let personID: UUID?
    public let personName: String?
    public let contextTitle: String
    public let evidenceID: UUID?
    public let prefillText: String?

    public init(
        outcomeID: UUID,
        personID: UUID?,
        personName: String?,
        contextTitle: String,
        evidenceID: UUID? = nil,
        prefillText: String? = nil
    ) {
        self.outcomeID = outcomeID
        self.personID = personID
        self.personName = personName
        self.contextTitle = contextTitle
        self.evidenceID = evidenceID
        self.prefillText = prefillText
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Protocols
// ─────────────────────────────────────────────────────────────────────

/// Protocol for types that can be displayed as insights in the UI
public protocol InsightDisplayable {
    var kind: InsightKind { get }
    var message: String { get }
    var confidence: Double { get }
    var interactionsCount: Int { get }
    var consentsCount: Int { get }
}
