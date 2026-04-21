//
//  SAMModels-ImpromptuReview.swift
//  SAM
//
//  Block 4: lightweight DTO carried on the `.samOpenImpromptuReview`
//  notification so the shell can open the review sheet without reaching
//  into SwiftData directly. The sheet itself fetches the TranscriptSession
//  by id once it appears, keeping the payload cheap and Sendable.
//

import Foundation

public struct ImpromptuReviewPayload: Codable, Hashable, Sendable, Identifiable {
    /// `Identifiable` conformance so the shell can present the sheet via
    /// `.sheet(item:)`. The session id is already unique so it doubles here.
    public var id: UUID { sessionID }

    /// The session needing review.
    public let sessionID: UUID

    /// Short TLDR pulled from the summary, so the sheet can show a one-
    /// liner before the user taps in. Optional — falls back to the session
    /// title when absent.
    public let summaryTLDR: String?

    /// Auto-generated title (2-5 words) from the summary, if any.
    public let suggestedTitle: String?

    /// When the recording was made — used for display ("this morning",
    /// "yesterday afternoon") and for resolving default due dates on any
    /// commitments Sarah confirms.
    public let recordedAt: Date

    /// Duration in seconds; shown compactly ("12 min") in the sheet header.
    public let durationSeconds: TimeInterval

    public init(
        sessionID: UUID,
        summaryTLDR: String? = nil,
        suggestedTitle: String? = nil,
        recordedAt: Date,
        durationSeconds: TimeInterval
    ) {
        self.sessionID = sessionID
        self.summaryTLDR = summaryTLDR
        self.suggestedTitle = suggestedTitle
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
    }
}
