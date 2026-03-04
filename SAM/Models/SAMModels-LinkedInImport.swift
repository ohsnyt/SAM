//
//  SAMModels-LinkedInImport.swift
//  SAM
//
//  Tracks LinkedIn data archive import events.
//  Each time the user imports a LinkedIn export folder, one LinkedInImport
//  record is created. This provides an audit trail and enables the coordinator
//  to scope IntentionalTouch records to a specific import for deduplication.
//

import Foundation
import SwiftData

// MARK: - Supporting Enum

/// The lifecycle status of a LinkedIn archive import.
public enum LinkedInImportStatus: String, Codable, Sendable {
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

// MARK: - LinkedInImport @Model

/// Records metadata about a single LinkedIn archive import event.
@Model
public final class LinkedInImport {

    @Attribute(.unique) public var id: UUID

    /// When this import was initiated.
    public var importDate: Date

    /// The filename of the archive folder/ZIP (for display in history).
    public var archiveFileName: String

    /// Total connections found in Connections.csv.
    public var connectionCount: Int

    /// Number of connections that matched existing SAM contacts.
    public var matchedContactCount: Int

    /// Number of connections that were new (not previously in SAM).
    public var newContactsFound: Int

    /// Number of IntentionalTouch records created during this import.
    public var touchEventsFound: Int

    /// Number of new messages imported as SamEvidenceItem records.
    public var messagesImported: Int

    /// Import lifecycle status (rawValue of LinkedInImportStatus).
    public var statusRawValue: String

    // MARK: - Transient computed wrapper

    @Transient public var status: LinkedInImportStatus {
        LinkedInImportStatus(rawValue: statusRawValue) ?? .processing
    }

    // MARK: - Init

    public init(
        importDate: Date = Date(),
        archiveFileName: String = "",
        connectionCount: Int = 0,
        matchedContactCount: Int = 0,
        newContactsFound: Int = 0,
        touchEventsFound: Int = 0,
        messagesImported: Int = 0,
        status: LinkedInImportStatus = .processing
    ) {
        self.id = UUID()
        self.importDate = importDate
        self.archiveFileName = archiveFileName
        self.connectionCount = connectionCount
        self.matchedContactCount = matchedContactCount
        self.newContactsFound = newContactsFound
        self.touchEventsFound = touchEventsFound
        self.messagesImported = messagesImported
        self.statusRawValue = status.rawValue
    }
}
