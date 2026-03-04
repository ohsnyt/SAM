//
//  SAMModels-FacebookImport.swift
//  SAM
//
//  Phase FB-1: Tracks Facebook data archive import events.
//  Each time the user imports a Facebook export folder, one FacebookImport
//  record is created. This provides an audit trail and enables the coordinator
//  to scope IntentionalTouch records to a specific import for deduplication.
//
//  Mirrors SAMModels-LinkedInImport.swift architecture.
//

import Foundation
import SwiftData

// MARK: - Supporting Enum

/// The lifecycle status of a Facebook archive import.
public enum FacebookImportStatus: String, Codable, Sendable {
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

// MARK: - FacebookImport @Model

/// Records metadata about a single Facebook archive import event.
@Model
public final class FacebookImport {

    @Attribute(.unique) public var id: UUID

    /// When this import was initiated.
    public var importDate: Date

    /// The filename of the archive folder/ZIP (for display in history).
    public var archiveFileName: String

    /// Total friends found in your_friends.json.
    public var friendCount: Int

    /// Number of friends that matched existing SAM contacts.
    public var matchedContactCount: Int

    /// Number of friends that were new (not previously in SAM).
    public var newContactsFound: Int

    /// Number of IntentionalTouch records created during this import.
    public var touchEventsFound: Int

    /// Number of Messenger threads parsed.
    public var messageThreadsParsed: Int

    /// Import lifecycle status (rawValue of FacebookImportStatus).
    public var statusRawValue: String

    // MARK: - Transient computed wrapper

    @Transient public var status: FacebookImportStatus {
        FacebookImportStatus(rawValue: statusRawValue) ?? .processing
    }

    // MARK: - Init

    public init(
        importDate: Date = Date(),
        archiveFileName: String = "",
        friendCount: Int = 0,
        matchedContactCount: Int = 0,
        newContactsFound: Int = 0,
        touchEventsFound: Int = 0,
        messageThreadsParsed: Int = 0,
        status: FacebookImportStatus = .processing
    ) {
        self.id = UUID()
        self.importDate = importDate
        self.archiveFileName = archiveFileName
        self.friendCount = friendCount
        self.matchedContactCount = matchedContactCount
        self.newContactsFound = newContactsFound
        self.touchEventsFound = touchEventsFound
        self.messageThreadsParsed = messageThreadsParsed
        self.statusRawValue = status.rawValue
    }
}
