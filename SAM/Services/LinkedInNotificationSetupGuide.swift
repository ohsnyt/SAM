//
//  LinkedInNotificationSetupGuide.swift
//  SAM
//
//  Static guidance content for LinkedIn notification setup (Phase 6).
//  Defines which notification types SAM monitors, detection thresholds,
//  and the step-by-step instructions surfaced in the Today view when
//  a notification type has never been observed.
//
//  All content mirrors Spec Section 9.1–9.3.
//

import Foundation

// MARK: - Setup Guide Payload DTO

/// Encodes setup guidance instructions into a SamOutcome's sourceInsightSummary field.
/// Follows the same JSON-in-sourceInsightSummary pattern as ContentTopic for contentCreation outcomes.
public struct SetupGuidePayload: Codable, Sendable {
    /// TouchType.rawValue for the monitored notification type (or "global" for the all-types case).
    public let touchTypeRawValue: String
    /// UserDefaults key prefix for dismiss/acknowledge state (e.g. "sam.linkedin.setup.message").
    public let userDefaultsKey: String
    /// Numbered step-by-step instructions shown in the guide sheet.
    public let instructions: [String]
    /// "Why this matters" explanation for relationship management context.
    public let whyItMatters: String
    /// The direct LinkedIn settings URL string.
    public let settingsURL: String

    public init(
        touchTypeRawValue: String,
        userDefaultsKey: String,
        instructions: [String],
        whyItMatters: String,
        settingsURL: String
    ) {
        self.touchTypeRawValue = touchTypeRawValue
        self.userDefaultsKey = userDefaultsKey
        self.instructions = instructions
        self.whyItMatters = whyItMatters
        self.settingsURL = settingsURL
    }
}

// MARK: - Guidance Definitions

/// Static setup guidance content for LinkedIn notification types.
/// Stateless — no stored properties or dependencies.
public enum LinkedInNotificationSetupGuide {

    // MARK: - Settings URL

    /// Direct link to LinkedIn email notification settings.
    /// No login navigation required when already signed in.
    public static let settingsURL = URL(string: "https://www.linkedin.com/psettings/communications")!

    // MARK: - Monitored Type Definition

    /// Definition of a LinkedIn notification type that SAM monitors.
    public struct MonitoredType: Sendable {
        /// The IntentionalTouch TouchType this notification generates.
        public let touchType: TouchType
        /// Human-readable display name for this notification category.
        public let displayName: String
        /// Days after mail monitoring starts before suggesting setup, if this type is missing.
        public let suggestionThresholdDays: Int
        /// Whether this notification type only matters if the user has posted content.
        /// If true, the setup outcome is suppressed when no ContentPost records exist.
        public let requiresUserPosts: Bool
        /// Priority score for the generated SamOutcome (0.0–1.0).
        public let priority: Double
        /// Title of the setup guidance SamOutcome.
        public let title: String
        /// Step-by-step instructions shown in the setup guide sheet.
        public let instructions: [String]
        /// "Why this matters" explanation for relationship management context.
        public let whyItMatters: String
        /// UserDefaults key prefix for this type's dismiss/acknowledge state.
        public var userDefaultsKey: String {
            "sam.linkedin.setup.\(touchType.rawValue)"
        }
    }

    // MARK: - Monitored Types (from Spec Section 9.1/9.3)

    /// All notification types SAM monitors, in priority order.
    public static let monitoredTypes: [MonitoredType] = [
        MonitoredType(
            touchType: .message,
            displayName: "Messages",
            suggestionThresholdDays: 30,
            requiresUserPosts: false,
            priority: 0.7,
            title: "Enable LinkedIn message notifications",
            instructions: [
                "Open LinkedIn Settings (link below)",
                "Select \"Email\" in the left sidebar",
                "Under the \"Messages\" category, click the edit icon",
                "Set frequency to \"Individual email\" (not \"Weekly digest\" or \"Off\")",
                "Your changes save automatically"
            ],
            whyItMatters: "Message notifications let SAM detect when contacts reach out to you on LinkedIn, keeping your relationship timeline complete and ensuring you never miss an important conversation."
        ),
        MonitoredType(
            touchType: .invitationPersonalized,
            displayName: "Connection Requests",
            suggestionThresholdDays: 14,
            requiresUserPosts: false,
            priority: 0.65,
            title: "Enable LinkedIn connection request notifications",
            instructions: [
                "Open LinkedIn Settings (link below)",
                "Select \"Email\" in the left sidebar",
                "Under \"Invitations and messages\" or \"Network\", click the edit icon",
                "Enable email notifications for \"Invitations to connect\"",
                "Your changes save automatically"
            ],
            whyItMatters: "Connection request notifications help SAM identify new professional relationships forming in your network, which may represent leads or referral opportunities worth acting on."
        ),
        MonitoredType(
            touchType: .endorsementReceived,
            displayName: "Endorsements",
            suggestionThresholdDays: 30,
            requiresUserPosts: false,
            priority: 0.5,
            title: "Enable LinkedIn endorsement notifications",
            instructions: [
                "Open LinkedIn Settings (link below)",
                "Select \"Email\" in the left sidebar",
                "Find \"Activity that involves you\" or \"Profile\" category",
                "Enable email notifications for \"Endorsements\"",
                "Individual email or Weekly digest both work"
            ],
            whyItMatters: "When someone endorses your skills, they're actively thinking about your professional capabilities. SAM tracks endorsements as relationship signals that indicate warm contacts worth engaging."
        ),
        MonitoredType(
            touchType: .comment,
            displayName: "Comments on Posts",
            suggestionThresholdDays: 30,
            requiresUserPosts: true,
            priority: 0.45,
            title: "Enable LinkedIn comment notifications",
            instructions: [
                "Open LinkedIn Settings (link below)",
                "Select \"Email\" in the left sidebar",
                "Find \"Posting and commenting\" category",
                "Enable email notifications for \"Comments on your posts\"",
                "Set to \"Individual email\" for real-time tracking"
            ],
            whyItMatters: "Comments on your posts indicate genuine engagement — people who comment are significantly more likely to respond to outreach. This data is absent from LinkedIn's CSV export, so email notifications are the ONLY way SAM can capture it."
        ),
        MonitoredType(
            touchType: .reaction,
            displayName: "Reactions to Posts",
            suggestionThresholdDays: 60,
            requiresUserPosts: true,
            priority: 0.35,
            title: "Enable LinkedIn reaction notifications",
            instructions: [
                "Open LinkedIn Settings (link below)",
                "Select \"Email\" in the left sidebar",
                "Find \"Posting and commenting\" category",
                "Enable email notifications for \"Reactions to your posts\"",
                "Like comments, reactions are absent from LinkedIn data exports"
            ],
            whyItMatters: "Reactions provide lightweight engagement signals that help SAM identify warm contacts who may not message directly but are paying attention to your content — a valuable prospecting signal."
        ),
    ]

    // MARK: - Global "No LinkedIn Emails" Guidance

    /// Guidance for when SAM has received NO LinkedIn notification emails at all.
    /// This is higher priority than per-type guidance and surfaces first.
    public static let noEmailsGuidance = MonitoredType(
        touchType: .message,  // placeholder TouchType; not used for detection matching
        displayName: "LinkedIn Notifications",
        suggestionThresholdDays: 7,
        requiresUserPosts: false,
        priority: 0.8,
        title: "Enable LinkedIn email notifications on linkedin.com",
        instructions: [
            "Open LinkedIn.com Settings (link below) — this is a LinkedIn setting, not a SAM setting",
            "Select \"Email\" in the left sidebar",
            "Review each notification category and ensure \"Email\" delivery is enabled",
            "At minimum, enable: Messages, Invitations, and Endorsements",
            "If you post content, also enable: Comments and Reactions on your posts",
            "Make sure LinkedIn sends notifications to the email account SAM monitors"
        ],
        whyItMatters: "SAM hasn't detected any LinkedIn notification emails in your monitored mailbox yet. When LinkedIn sends notification emails to your work email, SAM can track professional interactions (messages, connection requests, endorsements) between LinkedIn data exports. This is configured on linkedin.com, not inside SAM."
    )

    /// UserDefaults key for the global "no LinkedIn emails" guidance state.
    public static let noEmailsUserDefaultsKey = "sam.linkedin.setup.global"
}
