//
//  SAMModels-SubstackImport.swift
//  SAM
//
//  Tracks Substack import events (RSS feed fetches and subscriber CSV imports).
//  Each import creates one SubstackImport record for audit trail and history.
//

import Foundation
import SwiftData

// MARK: - Supporting Enum

/// The lifecycle status of a Substack import.
public enum SubstackImportStatus: String, Codable, Sendable {
    case processing    = "processing"
    case awaitingReview = "awaitingReview"
    case complete      = "complete"
    case failed        = "failed"

    public var displayName: String {
        switch self {
        case .processing:     return "Processing"
        case .awaitingReview: return "Awaiting Review"
        case .complete:       return "Complete"
        case .failed:         return "Failed"
        }
    }
}

// MARK: - SubstackImport @Model

/// Records metadata about a single Substack import event (RSS feed or subscriber CSV).
@Model
public final class SubstackImport {

    @Attribute(.unique) public var id: UUID

    /// When this import was initiated.
    public var importDate: Date

    /// The source identifier ("RSS feed" or ZIP filename).
    public var archiveFileName: String

    /// Number of posts parsed from the feed.
    public var postCount: Int

    /// Number of subscribers found in CSV.
    public var subscriberCount: Int

    /// Number of subscribers matched to existing SamPerson records.
    public var matchedSubscriberCount: Int

    /// Number of unmatched subscribers routed to UnknownSender.
    public var newLeadsFound: Int

    /// Number of IntentionalTouch records created during this import.
    public var touchEventsCreated: Int

    /// Import lifecycle status (rawValue of SubstackImportStatus).
    public var statusRawValue: String

    // MARK: - Transient computed wrapper

    @Transient public var status: SubstackImportStatus {
        SubstackImportStatus(rawValue: statusRawValue) ?? .processing
    }

    // MARK: - Init

    public init(
        importDate: Date = Date(),
        archiveFileName: String = "",
        postCount: Int = 0,
        subscriberCount: Int = 0,
        matchedSubscriberCount: Int = 0,
        newLeadsFound: Int = 0,
        touchEventsCreated: Int = 0,
        status: SubstackImportStatus = .processing
    ) {
        self.id = UUID()
        self.importDate = importDate
        self.archiveFileName = archiveFileName
        self.postCount = postCount
        self.subscriberCount = subscriberCount
        self.matchedSubscriberCount = matchedSubscriberCount
        self.newLeadsFound = newLeadsFound
        self.touchEventsCreated = touchEventsCreated
        self.statusRawValue = status.rawValue
    }
}
