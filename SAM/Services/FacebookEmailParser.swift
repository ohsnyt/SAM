//
//  FacebookEmailParser.swift
//  SAM
//
//  Stateless subject-line parser for Facebook notification emails.
//  Produces FacebookNotificationEvent DTOs consumed by a social import coordinator.
//
//  Facebook notification emails arrive from @facebookmail.com with subjects
//  that follow a consistent "Name verbed your thing" pattern. Unlike LinkedIn,
//  the subject line alone is sufficient to extract the contact name and event
//  type — no MIME/HTML body parsing is needed, keeping this lightweight.
//

import Foundation

// MARK: - Event Type

/// Classification of a Facebook notification email.
public enum FacebookEventType: String, Sendable, Codable, CaseIterable {
    case commentOnPost   = "commentOnPost"
    case reactionToPost  = "reactionToPost"
    case mention         = "mention"
    case directMessage   = "directMessage"
    case friendRequest   = "friendRequest"
    case friendAccepted  = "friendAccepted"
    case share           = "share"
    case tag             = "tag"
    case birthday        = "birthday"
    case eventInvite     = "eventInvite"
    case other           = "other"

    // MARK: TouchType mapping

    /// The corresponding TouchType for recording this event as an IntentionalTouch.
    /// Returns nil for event types that don't generate a touch record (birthdays, event invites).
    public var touchType: TouchType? {
        switch self {
        case .commentOnPost:  return .comment
        case .reactionToPost: return .reaction
        case .mention:        return .mention
        case .directMessage:  return .message
        case .friendRequest:  return .invitationPersonalized
        case .friendAccepted: return .invitationGeneric
        case .share:          return .reaction       // closest fit — they engaged with your content
        case .tag:            return .mention         // closest fit — they referenced you
        case .birthday, .eventInvite, .other:
            return nil
        }
    }

    /// Whether the contact initiated this interaction (vs. the user, or mutual).
    public var touchDirection: TouchDirection {
        switch self {
        case .commentOnPost:  return .inbound
        case .reactionToPost: return .inbound
        case .mention:        return .inbound
        case .directMessage:  return .inbound
        case .friendRequest:  return .inbound
        case .friendAccepted: return .mutual
        case .share:          return .inbound
        case .tag:            return .inbound
        case .birthday, .eventInvite, .other:
            return .inbound
        }
    }
}

// MARK: - Event DTO

/// A single parsed Facebook notification event, produced by FacebookEmailParser.
/// Sendable: all properties are value types.
public struct FacebookNotificationEvent: Sendable, Identifiable {
    public let id: UUID
    public let eventType: FacebookEventType
    /// Extracted contact display name from the subject line.
    public let contactName: String
    /// Facebook profile URL if extractable. Typically nil for subject-only parsing.
    public let contactProfileUrl: String?
    /// Brief content snippet extracted from the subject, if available.
    public let snippet: String?
    /// Date from email headers.
    public let date: Date
    /// Raw email subject, for debugging.
    public let rawSubject: String
    /// Mail.app message ID (from MessageMeta.mailID), used as dedup key.
    public let sourceEmailId: String

    public init(
        id: UUID = UUID(),
        eventType: FacebookEventType,
        contactName: String,
        contactProfileUrl: String?,
        snippet: String?,
        date: Date,
        rawSubject: String,
        sourceEmailId: String
    ) {
        self.id = id
        self.eventType = eventType
        self.contactName = contactName
        self.contactProfileUrl = contactProfileUrl
        self.snippet = snippet
        self.date = date
        self.rawSubject = rawSubject
        self.sourceEmailId = sourceEmailId
    }
}

// MARK: - Parser

/// Stateless parser for Facebook notification email subject lines.
///
/// Usage:
/// ```swift
/// let event = FacebookEmailParser.parse(
///     subject: meta.subject,
///     date: meta.date,
///     sourceEmailId: String(meta.mailID)
/// )
/// ```
///
/// Subject-only parsing keeps this lightweight — no MIME source fetch or HTML
/// extraction is required. The contact name is the text before the verb phrase
/// in the subject line.
public enum FacebookEmailParser {

    // MARK: - Public entry point

    /// Parse a Facebook notification email into a structured event.
    ///
    /// - Parameters:
    ///   - subject: Email subject line.
    ///   - date: Email date (from MessageMeta).
    ///   - sourceEmailId: Mail.app numeric message ID as a String (for dedup).
    ///
    /// - Returns: A parsed event, or nil if the subject is non-actionable noise.
    public static func parse(
        subject: String,
        date: Date,
        sourceEmailId: String
    ) -> FacebookNotificationEvent? {

        // Step 1: Classify the event from the subject line.
        // Returns nil for known non-actionable subjects (memories, marketplace, security, etc.)
        guard let eventType = classifySubject(subject) else { return nil }

        // Step 2: Extract contact name from the subject.
        let contactName = extractNameFromSubject(subject, eventType: eventType) ?? "Unknown"

        // Step 3: Extract snippet if available.
        let snippet = extractSnippetFromSubject(subject, eventType: eventType)

        return FacebookNotificationEvent(
            eventType: eventType,
            contactName: contactName,
            contactProfileUrl: nil,  // Not extractable from subject alone
            snippet: snippet,
            date: date,
            rawSubject: subject,
            sourceEmailId: sourceEmailId
        )
    }

    // MARK: - Subject Classification

    /// Maps a subject line to a FacebookEventType.
    /// Returns nil for non-actionable bulk/noise emails.
    static func classifySubject(_ subject: String) -> FacebookEventType? {
        let lower = subject.lowercased()

        // Non-actionable noise — return nil to skip entirely
        let noisePatterns: [String] = [
            "memories to look back on",
            "memories from",
            "on this day",
            "marketplace",
            "suggested for you",
            "people you may know",
            "security alert",
            "login",
            "password",
            "confirm your",
            "verify your",
            "code is",
            "update your",
            "ad report",
            "page insights",
            "boost your",
            "trending",
            "news feed",
            "stories you missed",
            "notification settings",
        ]
        for noise in noisePatterns {
            if lower.contains(noise) { return nil }
        }

        // Comments on posts
        if lower.contains("commented on your") || lower.contains("replied to your comment") {
            return .commentOnPost
        }

        // Reactions to posts
        if lower.contains("reacted to your") || lower.contains("likes your")
            || lower.contains("loved your") {
            return .reactionToPost
        }

        // Mentions
        if lower.contains("mentioned you") {
            return .mention
        }

        // Direct messages
        if lower.contains("sent you a message") || lower.contains("new message from") {
            return .directMessage
        }

        // Friend requests
        if lower.contains("sent you a friend request") || lower.contains("wants to be your friend") {
            return .friendRequest
        }

        // Friend accepted
        if lower.contains("accepted your friend request") {
            return .friendAccepted
        }

        // Shares
        if lower.contains("shared your") {
            return .share
        }

        // Tags
        if lower.contains("tagged you") {
            return .tag
        }

        // Birthdays — no touch, but could trigger a life event
        if lower.contains("birthday") {
            return .birthday
        }

        // Event invites
        if lower.contains("invited you to") || (lower.contains("event") && lower.contains("invite")) {
            return .eventInvite
        }

        // Defensive fallback — better to return .other than misclassify
        return .other
    }

    // MARK: - Subject-Line Name Extraction

    /// Extract a contact name from the subject line using event-type-specific patterns.
    ///
    /// Facebook subjects typically follow "Name verb-phrase rest" — the name is
    /// everything before the first recognized verb phrase.
    ///
    /// E.g.: "John Smith commented on your post" → "John Smith"
    static func extractNameFromSubject(_ subject: String, eventType: FacebookEventType) -> String? {
        let patterns: [String]
        switch eventType {
        case .commentOnPost:
            patterns = [
                #"^(.+?)\s+commented on your"#,
                #"^(.+?)\s+replied to your comment"#,
            ]
        case .reactionToPost:
            patterns = [
                #"^(.+?)\s+reacted to your"#,
                #"^(.+?)\s+likes your"#,
                #"^(.+?)\s+loved your"#,
            ]
        case .mention:
            patterns = [
                #"^(.+?)\s+mentioned you"#,
            ]
        case .directMessage:
            patterns = [
                #"^(.+?)\s+sent you a message"#,
                #"^New message from\s+(.+?)$"#,
            ]
        case .friendRequest:
            patterns = [
                #"^(.+?)\s+sent you a friend request"#,
                #"^(.+?)\s+wants to be your friend"#,
            ]
        case .friendAccepted:
            patterns = [
                #"^(.+?)\s+accepted your friend request"#,
            ]
        case .share:
            patterns = [
                #"^(.+?)\s+shared your"#,
            ]
        case .tag:
            patterns = [
                #"^(.+?)\s+tagged you"#,
            ]
        case .eventInvite:
            patterns = [
                #"^(.+?)\s+invited you to"#,
            ]
        case .birthday, .other:
            return nil
        }

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(subject.startIndex..., in: subject)
                if let match = regex.firstMatch(in: subject, range: range) {
                    // Some patterns have the name in group 1 regardless of position
                    if let nameRange = Range(match.range(at: 1), in: subject) {
                        let name = String(subject[nameRange])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty && name.count < 80 {
                            return name
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Subject-Line Snippet Extraction

    /// Extract a brief content snippet from the subject line, if available.
    ///
    /// Most Facebook notification subjects don't include content snippets, but
    /// some (comments, tags) include trailing context after the verb phrase.
    static func extractSnippetFromSubject(_ subject: String, eventType: FacebookEventType) -> String? {
        let patterns: [(eventType: FacebookEventType, pattern: String)]  = [
            // "John Smith commented on your post: Great article!" → "Great article!"
            (.commentOnPost, #"commented on your (?:post|photo|video|status):\s*(.+?)$"#),
            // "John Smith tagged you in a post" → "a post"
            (.tag, #"tagged you in\s+(.+?)$"#),
            // "John Smith invited you to Event Name" → "Event Name"
            (.eventInvite, #"invited you to\s+(.+?)$"#),
        ]

        for entry in patterns where entry.eventType == eventType {
            if let regex = try? NSRegularExpression(pattern: entry.pattern, options: .caseInsensitive) {
                let range = NSRange(subject.startIndex..., in: subject)
                if let match = regex.firstMatch(in: subject, range: range),
                   let snippetRange = Range(match.range(at: 1), in: subject) {
                    let text = String(subject[snippetRange])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        return String(text.prefix(200))
                    }
                }
            }
        }
        return nil
    }
}
