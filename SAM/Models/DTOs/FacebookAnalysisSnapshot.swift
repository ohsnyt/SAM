// FacebookAnalysisSnapshot.swift
// SAM
//
// Phase FB-3: Lightweight snapshot of import-time Facebook activity data.
// Cached in UserDefaults at import time so re-analysis never requires folder access.
// Mirrors ProfileAnalysisSnapshot (LinkedIn) with Facebook-specific metrics.

import Foundation

/// Snapshot of Facebook activity data captured at import time.
/// Used by FacebookProfileAnalystService for on-demand re-analysis
/// without needing access to the original export folder.
nonisolated public struct FacebookAnalysisSnapshot: Codable, Sendable {

    // MARK: - Friend Network

    /// Total number of Facebook friends in the export.
    public var friendCount: Int

    /// Friends added by year: "2024" → count (String keys for Codable).
    public var friendsByYear: [String: Int]

    // MARK: - Messaging Activity

    /// Total number of Messenger threads parsed.
    public var messageThreadCount: Int

    /// Total messages across all threads.
    public var totalMessageCount: Int

    /// Number of threads with messages in the last 90 days.
    public var activeThreadCount90Days: Int

    /// Top 10 most-messaged friends by message count.
    public var topMessaged: [TopContact]

    // MARK: - Engagement Activity

    /// Number of comments the user made on others' content.
    public var commentsGivenCount: Int

    /// Number of reactions the user gave to others' content.
    public var reactionsGivenCount: Int

    /// Number of friend requests the user sent.
    public var friendRequestsSentCount: Int

    /// Number of friend requests received.
    public var friendRequestsReceivedCount: Int

    // MARK: - Profile Completeness Flags

    /// Whether the user's profile has a current city set.
    public var hasCurrentCity: Bool

    /// Whether the user's profile has a hometown set.
    public var hasHometown: Bool

    /// Whether the user's profile has work experiences.
    public var hasWorkExperience: Bool

    /// Whether the user's profile has education entries.
    public var hasEducation: Bool

    /// Whether the user's profile has websites listed.
    public var hasWebsites: Bool

    /// Whether the user's profile has a profile URI.
    public var hasProfileUri: Bool

    // MARK: - User Posts

    /// Total number of text posts parsed from the export.
    public var postCount: Int = 0

    /// Top 5 post texts (up to 500 chars each) for voice re-analysis.
    public var recentPostSnippets: [String] = []

    /// Cached voice analysis result from post content.
    public var writingVoiceSummary: String = ""

    // MARK: - Timestamp

    /// When this snapshot was captured.
    public var snapshotDate: Date

    // MARK: - Nested Types

    public struct TopContact: Codable, Sendable {
        public var name: String
        public var messageCount: Int
        public var lastMessageDate: Date?
    }
}
