//
//  SAMModels-Presentation.swift
//  SAM
//
//  Created on March 11, 2026.
//  Presentation Library — reusable presentations linked to events.
//

import Foundation
import SwiftData

// MARK: - Presentation

/// A reusable presentation (workshop, seminar, training) that can be linked to multiple events.
/// Stores file references, AI-extracted content summaries, and delivery history.
@Model
public final class SamPresentation {
    @Attribute(.unique) public var id: UUID

    // MARK: Core Properties

    /// Human-readable title (e.g., "Retirement Planning 101")
    public var title: String

    /// User-written description of the presentation
    public var presentationDescription: String?

    /// Topic tags for categorization and search (e.g., ["retirement", "financial planning", "IRA"])
    public var topicTags: [String] = []

    /// Estimated duration in minutes
    public var estimatedDurationMinutes: Int?

    /// Target audience description (e.g., "Pre-retirees 55-65", "New agents")
    public var targetAudience: String?

    // MARK: File References

    /// Security-scoped bookmark data for each attached file.
    /// Each entry: ["filename": String, "bookmark": Data, "fileType": String]
    public var fileAttachments: [PresentationFile] = []

    // MARK: AI-Extracted Content

    /// AI-generated summary of the presentation content (from PDF/slide extraction).
    public var contentSummary: String?

    /// Key talking points extracted from the presentation.
    public var keyTalkingPoints: [String] = []

    /// When the content summary was last generated.
    public var contentAnalyzedAt: Date?

    // MARK: Delivery History

    /// How many times this presentation has been delivered.
    @Transient
    public var deliveryCount: Int {
        linkedEvents.filter { $0.status == .completed }.count
    }

    /// Date of most recent delivery.
    @Transient
    public var lastDeliveredAt: Date? {
        linkedEvents
            .filter { $0.status == .completed }
            .map(\.startDate)
            .max()
    }

    /// Date of next scheduled delivery.
    @Transient
    public var nextScheduledAt: Date? {
        linkedEvents
            .filter { $0.isUpcoming }
            .map(\.startDate)
            .min()
    }

    // MARK: Relationships

    /// Events that use this presentation.
    @Relationship(deleteRule: .nullify, inverse: \SamEvent.presentation)
    public var linkedEvents: [SamEvent] = []

    // MARK: Timestamps

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: Init

    public init(
        id: UUID = UUID(),
        title: String,
        presentationDescription: String? = nil,
        topicTags: [String] = [],
        estimatedDurationMinutes: Int? = nil,
        targetAudience: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.presentationDescription = presentationDescription
        self.topicTags = topicTags
        self.estimatedDurationMinutes = estimatedDurationMinutes
        self.targetAudience = targetAudience
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Presentation File (Embedded)

/// A file attached to a presentation (PDF, Keynote, PowerPoint).
public struct PresentationFile: Codable, Sendable, Identifiable {
    public var id: UUID
    public var fileName: String
    public var fileType: String          // "pdf", "key", "pptx"
    public var bookmarkData: Data        // Security-scoped bookmark for file access
    public var addedAt: Date
    public var fileSizeBytes: Int?

    public init(
        id: UUID = UUID(),
        fileName: String,
        fileType: String,
        bookmarkData: Data,
        addedAt: Date = .now,
        fileSizeBytes: Int? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.fileType = fileType
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
        self.fileSizeBytes = fileSizeBytes
    }
}
