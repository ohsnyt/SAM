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
        source: EvidenceSource = .mail
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
    }
}

enum UnknownSenderStatus: String, Codable, Sendable {
    case pending       // awaiting user action
    case added         // promoted to SamPerson
    case neverInclude  // permanently blocked
    case dismissed     // "not now" — resurfaces on next email
}
