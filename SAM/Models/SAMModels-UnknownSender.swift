//
//  SAMModels-UnknownSender.swift
//  SAM
//
//  Persists unknown email senders encountered during import for user triage.
//

import Foundation
import SwiftData

@Model
public final class UnknownSender {
    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) var email: String       // canonical (lowercased, trimmed)
    var displayName: String?                     // from "From" header
    var statusRawValue: String                   // pending|added|neverInclude|dismissed
    var firstSeenAt: Date
    var lastTriagedAt: Date?
    var emailCount: Int                          // incremented each import
    var latestSubject: String?                   // for triage context
    var latestEmailDate: Date?
    var sourceRawValue: String                   // "Mail"|"Calendar"
    var isLikelyMarketing: Bool                  // detected from List-Unsubscribe / List-ID / Precedence headers

    // LinkedIn-specific metadata (only set for source == .linkedIn)
    var intentionalTouchScore: Int               // computed touch score; 0 = no interactions found
    var linkedInCompany: String?                 // company from Connections.csv at time of import
    var linkedInPosition: String?                // job title from Connections.csv at time of import
    var linkedInConnectedOn: Date?               // connection date from Connections.csv

    // Facebook-specific metadata (only set for source == .facebook)
    var facebookFriendedOn: Date?                // when friendship was established
    var facebookMessageCount: Int                // total Messenger messages in export; 0 = none
    var facebookLastMessageDate: Date?           // most recent Messenger message timestamp

    // Substack-specific metadata (only set for source == .substack)
    var substackSubscribedAt: Date?              // when they subscribed
    var substackPlanType: String?                // "free" or "paid"
    var substackIsActive: Bool                   // still subscribed?

    // Sent-recipient metadata (only set for source == .sentMail)
    var sentEmailCount: Int = 0                  // number of sent emails to this address
    var earliestSentDate: Date?                  // for targeted watermark reset on approval

    @Transient
    var status: UnknownSenderStatus {
        get { UnknownSenderStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    @Transient
    var source: EvidenceSource {
        get { EvidenceSource(rawValue: sourceRawValue) ?? .mail }
        set { sourceRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        email: String,
        displayName: String? = nil,
        status: UnknownSenderStatus = .pending,
        firstSeenAt: Date = Date(),
        emailCount: Int = 1,
        latestSubject: String? = nil,
        latestEmailDate: Date? = nil,
        source: EvidenceSource = .mail,
        isLikelyMarketing: Bool = false,
        intentionalTouchScore: Int = 0,
        linkedInCompany: String? = nil,
        linkedInPosition: String? = nil,
        linkedInConnectedOn: Date? = nil,
        facebookFriendedOn: Date? = nil,
        facebookMessageCount: Int = 0,
        facebookLastMessageDate: Date? = nil,
        substackSubscribedAt: Date? = nil,
        substackPlanType: String? = nil,
        substackIsActive: Bool = true
    ) {
        self.id = id
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.displayName = displayName
        self.statusRawValue = status.rawValue
        self.firstSeenAt = firstSeenAt
        self.emailCount = emailCount
        self.latestSubject = latestSubject
        self.latestEmailDate = latestEmailDate
        self.sourceRawValue = source.rawValue
        self.isLikelyMarketing = isLikelyMarketing
        self.intentionalTouchScore = intentionalTouchScore
        self.linkedInCompany = linkedInCompany
        self.linkedInPosition = linkedInPosition
        self.linkedInConnectedOn = linkedInConnectedOn
        self.facebookFriendedOn = facebookFriendedOn
        self.facebookMessageCount = facebookMessageCount
        self.facebookLastMessageDate = facebookLastMessageDate
        self.substackSubscribedAt = substackSubscribedAt
        self.substackPlanType = substackPlanType
        self.substackIsActive = substackIsActive
    }
}

enum UnknownSenderStatus: String, Codable, Sendable {
    case pending       // awaiting user action
    case added         // promoted to SamPerson
    case neverInclude  // permanently blocked
    case dismissed     // "not now" — resurfaces on next email
}
