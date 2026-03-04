//
//  LinkedInEmailParser.swift
//  SAM
//
//  Stateless HTML/subject parser for LinkedIn notification emails.
//  Produces LinkedInNotificationEvent DTOs consumed by LinkedInImportCoordinator.
//
//  LinkedIn notification emails contain profile links and interaction snippets
//  only in the HTML body — the plain-text body strips all <a href> tags.
//  MailService.fetchMIMESource() + extractHTMLFromMIMESource() are used
//  upstream to produce the HTML string that this parser receives.
//

import Foundation

// MARK: - Event Type

/// Classification of a LinkedIn notification email.
public enum LinkedInEventType: String, Sendable, Codable, CaseIterable {
    case directMessage           = "directMessage"
    case connectionRequest       = "connectionRequest"
    case connectionAccepted      = "connectionAccepted"
    case endorsement             = "endorsement"
    case recommendation          = "recommendation"
    case commentOnPost           = "commentOnPost"
    case reactionToPost          = "reactionToPost"
    case mention                 = "mention"
    case newsletterSubscription  = "newsletterSubscription"
    case jobChange               = "jobChange"
    case birthday                = "birthday"
    case profileView             = "profileView"
    case other                   = "other"

    // MARK: TouchType mapping

    /// The corresponding TouchType for recording this event as an IntentionalTouch.
    /// Returns nil for event types that don't generate a touch record (job changes, birthdays, profile views).
    public var touchType: TouchType? {
        switch self {
        case .directMessage:          return .message
        case .connectionRequest:      return .invitationPersonalized
        case .connectionAccepted:     return .invitationGeneric
        case .endorsement:            return .endorsementReceived
        case .recommendation:         return .recommendationReceived
        case .commentOnPost:          return .comment
        case .reactionToPost:         return .reaction
        case .mention:                return .mention
        case .newsletterSubscription: return .newsletterSubscription
        case .jobChange, .birthday, .profileView, .other:
            return nil
        }
    }

    /// Whether the contact initiated this interaction (vs. the user, or mutual).
    public var touchDirection: TouchDirection {
        switch self {
        case .directMessage:          return .inbound
        case .connectionRequest:      return .inbound
        case .connectionAccepted:     return .mutual
        case .endorsement:            return .inbound
        case .recommendation:         return .inbound
        case .commentOnPost:          return .inbound
        case .reactionToPost:         return .inbound
        case .mention:                return .inbound
        case .newsletterSubscription: return .inbound
        case .jobChange, .birthday, .profileView, .other:
            return .inbound
        }
    }

    /// True for event types that fill the LinkedIn CSV export gap
    /// (comments, reactions, and newsletter subscriptions are absent from the CSV).
    public var fillsExportGap: Bool {
        switch self {
        case .commentOnPost, .reactionToPost, .newsletterSubscription:
            return true
        default:
            return false
        }
    }
}

// MARK: - Event DTO

/// A single parsed LinkedIn notification event, produced by LinkedInEmailParser.
/// Sendable: all properties are value types.
public struct LinkedInNotificationEvent: Sendable, Identifiable {
    public let id: UUID
    public let eventType: LinkedInEventType
    /// Extracted contact display name (from HTML or subject line fallback).
    public let contactName: String
    /// Normalized linkedin.com/in/slug URL, lowercased. Nil if not extractable.
    public let contactProfileUrl: String?
    /// Up to 200 characters of message/comment content, skill name, etc.
    public let snippet: String?
    /// Date from email headers.
    public let date: Date
    /// Raw email subject, for debugging.
    public let rawSubject: String
    /// Mail.app message ID (from MessageMeta.mailID), used as dedup key.
    public let sourceEmailId: String

    public init(
        id: UUID = UUID(),
        eventType: LinkedInEventType,
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

/// Stateless parser for LinkedIn notification email HTML bodies and subject lines.
///
/// Usage:
/// ```swift
/// let html = MailService.extractHTMLFromMIMESource(mimeSource)
/// let event = LinkedInEmailParser.parse(
///     htmlBody: html,
///     subject: meta.subject,
///     date: meta.date,
///     sourceEmailId: String(meta.mailID)
/// )
/// ```
public enum LinkedInEmailParser {

    // MARK: - Public entry point

    /// Parse a LinkedIn notification email into a structured event.
    ///
    /// - Parameters:
    ///   - htmlBody: Decoded HTML from the MIME source. May be nil if extraction failed.
    ///   - subject: Email subject line.
    ///   - date: Email date (from MessageMeta).
    ///   - sourceEmailId: Mail.app numeric message ID as a String (for dedup).
    ///   - userProfileSlug: The user's own LinkedIn slug (to exclude from link extraction).
    ///
    /// - Returns: A parsed event, or nil if the subject is non-actionable noise.
    public static func parse(
        htmlBody: String?,
        subject: String,
        date: Date,
        sourceEmailId: String,
        userProfileSlug: String? = nil
    ) -> LinkedInNotificationEvent? {

        // Step 1: Classify the event from the subject line.
        // Returns nil for known non-actionable subjects (digest, jobs, tips, etc.)
        guard let eventType = classifySubject(subject) else { return nil }

        // Step 2: Extract contact info from HTML (preferred) or fall back to subject.
        let profileUrl: String?
        let contactName: String
        let snippet: String?

        if let html = htmlBody, !html.isEmpty {
            profileUrl = extractProfileURL(from: html, excludingSlug: userProfileSlug)
            contactName = extractContactName(from: html, profileUrl: profileUrl)
                ?? extractNameFromSubject(subject, eventType: eventType)
                ?? "Unknown"
            snippet = extractSnippet(from: html, eventType: eventType, subject: subject)
        } else {
            profileUrl = nil
            contactName = extractNameFromSubject(subject, eventType: eventType) ?? "Unknown"
            snippet = extractSnippetFromSubject(subject, eventType: eventType)
        }

        return LinkedInNotificationEvent(
            eventType: eventType,
            contactName: contactName,
            contactProfileUrl: profileUrl,
            snippet: snippet,
            date: date,
            rawSubject: subject,
            sourceEmailId: sourceEmailId
        )
    }

    // MARK: - Subject Classification

    /// Maps a subject line to a LinkedInEventType.
    /// Returns nil for non-actionable bulk/digest/noise emails.
    static func classifySubject(_ subject: String) -> LinkedInEventType? {
        let lower = subject.lowercased()

        // Non-actionable noise — return nil to skip entirely
        let noisePatterns: [String] = [
            "trending", "top stories", "daily rundown", "weekly top",
            "jobs you may", "job alert", "people you may know",
            "tips for", "suggestions for", "who to follow",
            "newsletter from", "catch up on",
            "linkedin news", "top job picks",
            "your weekly", "your daily",
        ]
        for noise in noisePatterns {
            if lower.contains(noise) { return nil }
        }

        // Direct messages
        if lower.contains("sent you a message") || lower.contains("new message from") {
            return .directMessage
        }

        // Connection requests
        if lower.contains("wants to connect") || lower.contains("invitation to connect") {
            return .connectionRequest
        }

        // Connection accepted
        if lower.contains("accepted your invitation") || lower.contains("accepted your connection") {
            return .connectionAccepted
        }

        // Endorsements
        if lower.contains("endorsed you for") {
            return .endorsement
        }

        // Recommendations
        if lower.contains("has recommended you") || lower.contains("wrote you a recommendation")
            || lower.contains("wrote a recommendation") {
            return .recommendation
        }

        // Comments on posts
        if lower.contains("commented on your") {
            return .commentOnPost
        }

        // Reactions to posts
        if lower.contains("reacted to your") || lower.contains("likes your post")
            || lower.contains("loved your post") || lower.contains("celebrated your")
            || lower.contains("found your post insightful") || lower.contains("supports your post") {
            return .reactionToPost
        }

        // Mentions
        if lower.contains("mentioned you") {
            return .mention
        }

        // Newsletter subscriptions
        if lower.contains("subscribed to your newsletter") || lower.contains("subscribed to your article") {
            return .newsletterSubscription
        }

        // Job changes
        if lower.contains("started a new position") || lower.contains("work anniversary")
            || lower.contains("new role at") || lower.contains("congratulate") && lower.contains("new job") {
            return .jobChange
        }

        // Birthdays
        if lower.contains("birthday") {
            return .birthday
        }

        // Profile views
        if lower.contains("viewed your profile") || (lower.contains("appeared in") && lower.contains("search")) {
            return .profileView
        }

        // Anything else from LinkedIn that we haven't classified is still actionable
        return .other
    }

    // MARK: - HTML Extraction: Profile URL

    /// Extracts the first LinkedIn profile URL from an HTML body, excluding the user's own profile.
    ///
    /// Matches: `https://www.linkedin.com/in/slug`, `https://linkedin.com/comm/in/slug`
    /// Returns a normalized `https://www.linkedin.com/in/slug` string.
    static func extractProfileURL(from html: String, excludingSlug: String?) -> String? {
        // Pattern: href="...linkedin.com[/comm]/in/SLUG[?optional-query]"
        let pattern = #"href="https?://(?:www\.)?linkedin\.com/(?:comm/)?in/([A-Za-z0-9\-_%]+)[^"]*""#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)

        for match in matches {
            guard let slugRange = Range(match.range(at: 1), in: html) else { continue }
            let slug = String(html[slugRange]).lowercased()

            // Skip the user's own profile
            if let userSlug = excludingSlug?.lowercased(), slug == userSlug { continue }

            // Skip common non-person path segments
            if ["company", "school", "groups", "feed", "jobs", "pulse"].contains(slug) { continue }

            return "https://www.linkedin.com/in/\(slug)"
        }
        return nil
    }

    // MARK: - HTML Extraction: Contact Name

    /// Extracts the display name from the <a> tag that contains the profile URL.
    ///
    /// E.g.: `<a href="https://www.linkedin.com/in/john-smith">John Smith</a>` → "John Smith"
    static func extractContactName(from html: String, profileUrl: String?) -> String? {
        guard let url = profileUrl,
              let slug = url.components(separatedBy: "/in/").last,
              !slug.isEmpty else { return nil }

        // Match an anchor whose href contains the slug, capturing inner text
        // The inner text may contain whitespace/newlines around the name
        let escapedSlug = NSRegularExpression.escapedPattern(for: slug)
        let pattern = #"<a[^>]+linkedin\.com/(?:comm/)?in/"# + escapedSlug + #"[^"]*"[^>]*>\s*([^<]{1,100}?)\s*</a>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(html.startIndex..., in: html)
        if let match = regex.firstMatch(in: html, range: range),
           let nameRange = Range(match.range(at: 1), in: html) {
            let raw = String(html[nameRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Decode common HTML entities
            return decodeHTMLEntities(raw)
        }
        return nil
    }

    // MARK: - HTML Extraction: Snippet

    /// Extracts a content snippet from the HTML body, truncated to 200 characters.
    ///
    /// Strategy by event type:
    /// - `.directMessage`: Look for message preview div after the profile link
    /// - `.endorsement`: Extract skill name from subject line
    /// - Others: First meaningful paragraph text after the profile anchor
    static func extractSnippet(from html: String, eventType: LinkedInEventType, subject: String) -> String? {
        switch eventType {
        case .endorsement:
            return extractSnippetFromSubject(subject, eventType: eventType)

        case .directMessage, .commentOnPost, .mention:
            // Look for a message-body or preview div containing the snippet
            let snippetPatterns = [
                // Common LinkedIn notification message preview container patterns
                #"<(?:p|div)[^>]*(?:class|id)="[^"]*(?:message|preview|body|content|text)[^"]*"[^>]*>\s*([^<]{10,500}?)\s*</(?:p|div)>"#,
                // Fallback: any paragraph with enough text
                #"<p[^>]*>\s*([^<]{20,500}?)\s*</p>"#,
            ]
            for pattern in snippetPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                    let range = NSRange(html.startIndex..., in: html)
                    let matches = regex.matches(in: html, range: range)
                    // Take the first match with meaningful content (not just whitespace/punctuation)
                    for m in matches {
                        if let r = Range(m.range(at: 1), in: html) {
                            let text = decodeHTMLEntities(String(html[r]))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if text.count >= 10 {
                                return String(text.prefix(200))
                            }
                        }
                    }
                }
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Subject-Line Fallbacks

    /// Extract a contact name from the subject line using event-type-specific patterns.
    ///
    /// E.g.: "John Smith sent you a message" → "John Smith"
    static func extractNameFromSubject(_ subject: String, eventType: LinkedInEventType) -> String? {
        let patterns: [String]
        switch eventType {
        case .directMessage:
            patterns = [
                #"^(.+?)\s+sent you a message"#,
                #"^New message from\s+(.+?)$"#,
            ]
        case .connectionRequest:
            patterns = [
                #"^(.+?)\s+wants to connect"#,
                #"^(.+?)\s+invitation to connect"#,
            ]
        case .connectionAccepted:
            patterns = [
                #"^(.+?)\s+accepted your invitation"#,
                #"^(.+?)\s+accepted your connection"#,
            ]
        case .endorsement:
            patterns = [
                #"^(.+?)\s+endorsed you for"#,
            ]
        case .recommendation:
            patterns = [
                #"^(.+?)\s+has recommended you"#,
                #"^(.+?)\s+wrote you a recommendation"#,
                #"^(.+?)\s+wrote a recommendation"#,
            ]
        case .commentOnPost:
            patterns = [
                #"^(.+?)\s+commented on your"#,
            ]
        case .reactionToPost:
            patterns = [
                #"^(.+?)\s+reacted to your"#,
                #"^(.+?)\s+likes your post"#,
                #"^(.+?)\s+loved your post"#,
            ]
        case .mention:
            patterns = [
                #"^(.+?)\s+mentioned you"#,
            ]
        case .newsletterSubscription:
            patterns = [
                #"^(.+?)\s+subscribed to your"#,
            ]
        default:
            return nil
        }

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(subject.startIndex..., in: subject)
                if let match = regex.firstMatch(in: subject, range: range),
                   let nameRange = Range(match.range(at: 1), in: subject) {
                    let name = String(subject[nameRange])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty && name.count < 80 {
                        return name
                    }
                }
            }
        }
        return nil
    }

    /// Extract a snippet from the subject line (used when no HTML is available).
    static func extractSnippetFromSubject(_ subject: String, eventType: LinkedInEventType) -> String? {
        switch eventType {
        case .endorsement:
            // "Jane Smith endorsed you for Swift" → "Swift"
            if let regex = try? NSRegularExpression(pattern: #"endorsed you for\s+(.+?)$"#, options: .caseInsensitive) {
                let range = NSRange(subject.startIndex..., in: subject)
                if let match = regex.firstMatch(in: subject, range: range),
                   let r = Range(match.range(at: 1), in: subject) {
                    return String(subject[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - HTML Entity Decoding

    /// Decodes common HTML entities in extracted text strings.
    static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&amp;",  with: "&")
        result = result.replacingOccurrences(of: "&lt;",   with: "<")
        result = result.replacingOccurrences(of: "&gt;",   with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;",  with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&#160;", with: " ")
        return result
    }
}
