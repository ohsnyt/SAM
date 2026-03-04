//
//  SAMModels-Social.swift
//  SAM
//
//  LinkedIn Integration Spec §14 — Missing SwiftData Models (schema SAM_v30)
//
//  Four new models:
//  • NotificationTypeTracker — tracks which LinkedIn notification types SAM has
//    seen, used by LinkedInNotificationSetupGuide to advise the user on
//    which notification types to enable.
//  • ProfileAnalysisRecord — persists profile analysis results in SwiftData
//    instead of UserDefaults, enabling history and backup support.
//  • EngagementSnapshot — stores engagement metrics per platform per period;
//    prerequisite for §12 EngagementBenchmarker agent.
//  • SocialProfileSnapshot — platform-agnostic social profile storage;
//    prerequisite for §11 CrossPlatformConsistencyChecker agent.
//

import Foundation
import SwiftData

// MARK: - NotificationTypeTracker

/// Tracks which LinkedIn (and future platform) notification types SAM has seen.
/// Used by `LinkedInNotificationSetupGuide` to detect missing notification types
/// and surface setup guidance tasks in the Today view.
///
/// One record per (platform, notificationType) pair.
@Model
public final class NotificationTypeTracker {

    @Attribute(.unique) public var id: UUID

    /// The social platform: "linkedin", "facebook", etc.
    public var platform: String

    /// Notification type identifier: "message", "connectionRequest",
    /// "endorsement", "commentOnPost", "reactionToPost".
    public var notificationType: String

    /// When SAM first detected this notification type.
    public var firstSeenDate: Date?

    /// Most recent time SAM detected an email of this type.
    public var lastSeenDate: Date?

    /// Cumulative count of emails of this type that SAM has processed.
    public var totalCount: Int

    /// How many times the user has dismissed the setup guidance task for
    /// this notification type. After 3 dismissals, reminders drop to monthly.
    public var setupTaskDismissCount: Int

    // MARK: - Init

    public init(
        platform: String,
        notificationType: String,
        firstSeenDate: Date? = nil,
        lastSeenDate: Date? = nil,
        totalCount: Int = 0,
        setupTaskDismissCount: Int = 0
    ) {
        self.id = UUID()
        self.platform = platform
        self.notificationType = notificationType
        self.firstSeenDate = firstSeenDate
        self.lastSeenDate = lastSeenDate
        self.totalCount = totalCount
        self.setupTaskDismissCount = setupTaskDismissCount
    }
}

// MARK: - ProfileAnalysisRecord

/// Persists a single LinkedIn (or future platform) profile analysis result.
/// Replaces the UserDefaults-based storage so results are backed up and support
/// historical comparison across imports.
///
/// One record per analysis run (platform + analysisDate uniquely identify it).
@Model
public final class ProfileAnalysisRecord {

    @Attribute(.unique) public var id: UUID

    /// The social platform: "linkedin", "facebook", etc.
    public var platform: String

    /// When this analysis was generated.
    public var analysisDate: Date

    /// Overall quality score (1–100) returned by the profile analysis agent.
    public var overallScore: Int

    /// Full `ProfileAnalysisResult` serialized as JSON string.
    public var resultJson: String

    // MARK: - Init

    public init(
        platform: String,
        analysisDate: Date = Date(),
        overallScore: Int = 0,
        resultJson: String = "{}"
    ) {
        self.id = UUID()
        self.platform = platform
        self.analysisDate = analysisDate
        self.overallScore = overallScore
        self.resultJson = resultJson
    }
}

// MARK: - EngagementSnapshot

/// Stores a snapshot of social media engagement metrics for a given platform
/// and time period. Prerequisite for §12 EngagementBenchmarker agent.
///
/// Created after each bulk import and/or on the weekly/monthly analysis schedule.
@Model
public final class EngagementSnapshot {

    @Attribute(.unique) public var id: UUID

    /// The social platform: "linkedin", "facebook", etc.
    public var platform: String

    /// Start of the measurement period.
    public var periodStart: Date

    /// End of the measurement period.
    public var periodEnd: Date

    /// Full `EngagementMetrics` serialized as JSON string.
    public var metricsJson: String

    /// Benchmarking agent output (optional — populated when the
    /// EngagementBenchmarker agent has run against this snapshot).
    public var benchmarkResultJson: String?

    // MARK: - Init

    public init(
        platform: String,
        periodStart: Date,
        periodEnd: Date,
        metricsJson: String = "{}",
        benchmarkResultJson: String? = nil
    ) {
        self.id = UUID()
        self.platform = platform
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.metricsJson = metricsJson
        self.benchmarkResultJson = benchmarkResultJson
    }
}

// MARK: - SocialProfileSnapshot

/// Platform-agnostic snapshot of a social media profile.
/// Prerequisite for §11 CrossPlatformConsistencyChecker agent.
///
/// When `samContactId` is nil, this record represents the USER's own profile.
/// When non-nil, it represents a contact's profile on the given platform.
@Model
public final class SocialProfileSnapshot {

    @Attribute(.unique) public var id: UUID

    /// nil → this is the user's own profile; non-nil → a contact's profile.
    public var samContactId: UUID?

    /// Platform identifier: "linkedin", "facebook", "twitter", etc.
    public var platform: String

    /// The platform's user identifier (vanity slug or numeric ID).
    public var platformUserId: String

    /// Full profile URL on the platform.
    public var platformProfileUrl: String

    /// When this snapshot was captured.
    public var importDate: Date

    // MARK: Normalized identity fields

    public var displayName: String
    public var headline: String?
    public var summary: String?
    public var currentCompany: String?
    public var currentTitle: String?
    public var industry: String?
    public var location: String?

    /// JSON array of website URL strings.
    public var websitesJson: String?

    /// JSON array of skill strings.
    public var skillsJson: String?

    // MARK: Network metrics (snapshot at import time)

    public var connectionCount: Int?
    public var followerCount: Int?
    public var postCount: Int?

    /// JSON blob for platform-specific extended fields
    /// (e.g., endorsements, certifications for LinkedIn;
    ///  groups, life events for Facebook).
    public var platformSpecificDataJson: String?

    // MARK: - Init

    public init(
        samContactId: UUID? = nil,
        platform: String,
        platformUserId: String = "",
        platformProfileUrl: String = "",
        importDate: Date = Date(),
        displayName: String = "",
        headline: String? = nil,
        summary: String? = nil,
        currentCompany: String? = nil,
        currentTitle: String? = nil,
        industry: String? = nil,
        location: String? = nil,
        websitesJson: String? = nil,
        skillsJson: String? = nil,
        connectionCount: Int? = nil,
        followerCount: Int? = nil,
        postCount: Int? = nil,
        platformSpecificDataJson: String? = nil
    ) {
        self.id = UUID()
        self.samContactId = samContactId
        self.platform = platform
        self.platformUserId = platformUserId
        self.platformProfileUrl = platformProfileUrl
        self.importDate = importDate
        self.displayName = displayName
        self.headline = headline
        self.summary = summary
        self.currentCompany = currentCompany
        self.currentTitle = currentTitle
        self.industry = industry
        self.location = location
        self.websitesJson = websitesJson
        self.skillsJson = skillsJson
        self.connectionCount = connectionCount
        self.followerCount = followerCount
        self.postCount = postCount
        self.platformSpecificDataJson = platformSpecificDataJson
    }
}
