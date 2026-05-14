//
//  ClipboardParsingService.swift
//  SAM
//
//  Global Clipboard Capture Hotkey
//
//  Actor that reads the system clipboard and uses AI to parse
//  copied conversation text into structured messages.
//

import AppKit
import Foundation
import os.log

// MARK: - DTOs

nonisolated struct ClipboardMessageDTO: Sendable, Identifiable {
    let id: UUID
    var senderName: String
    var text: String
    var timestamp: Date?
    var isFromMe: Bool

    init(id: UUID = UUID(), senderName: String, text: String, timestamp: Date? = nil, isFromMe: Bool = false) {
        self.id = id
        self.senderName = senderName
        self.text = text
        self.timestamp = timestamp
        self.isFromMe = isFromMe
    }
}

nonisolated struct ClipboardConversationDTO: Sendable {
    var messages: [ClipboardMessageDTO]
    var detectedPlatform: String?
    var conversationDate: Date
    /// The source URL from the pasteboard (e.g. the browser page the text was copied from).
    var sourceURL: URL?
}

/// Result type for clipboard parsing — either a conversation or non-conversation content (profile, bio, etc.)
nonisolated enum ClipboardParseResult: Sendable {
    case conversation(ClipboardConversationDTO)
    case profileContent(ClipboardProfileDTO)
}

/// Extracted profile/bio content from a web page (not a conversation).
nonisolated struct ClipboardProfileDTO: Sendable {
    var personName: String
    var headline: String?
    var details: String      // The cleaned-up profile text
    var platform: String?
    var sourceURL: URL?
}

// MARK: - Service

actor ClipboardParsingService {

    static let shared = ClipboardParsingService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ClipboardParsingService")

    // MARK: - Errors

    enum ParseError: LocalizedError {
        case emptyClipboard
        case noConversationDetected
        case aiParsingFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyClipboard:
                return "The clipboard is empty. Copy a conversation first."
            case .noConversationDetected:
                return "No conversation structure detected in the clipboard text."
            case .aiParsingFailed(let detail):
                return "AI parsing failed: \(detail)"
            }
        }
    }

    // MARK: - Public

    func parseClipboard() async throws -> ClipboardParseResult {
        // Read clipboard content on MainActor (plain text + source URL)
        let (clipboardText, sourceURL) = await MainActor.run {
            let pb = NSPasteboard.general
            let text = pb.string(forType: .string) ?? ""
            let url = readSourceURL(from: pb)
            return (text, url)
        }

        guard !clipboardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.emptyClipboard
        }

        // Detect platform from source URL before AI parsing
        let detectedPlatform = platformFromURL(sourceURL)

        // Check if this is a profile page (not a conversation) based on URL pattern
        if isProfileURL(sourceURL) {
            let profile = extractProfileContent(from: clipboardText, sourceURL: sourceURL, platform: detectedPlatform)
            logger.debug("Detected profile content: \(profile.personName), platform: \(profile.platform ?? "unknown")")
            return .profileContent(profile)
        }

        let (systemPrompt, userPrompt) = buildPrompt(text: clipboardText, sourceURL: sourceURL, detectedPlatform: detectedPlatform)
        let responseText = try await AIService.shared.generate(
            prompt: userPrompt,
            systemInstruction: systemPrompt,
            task: InferenceTask(label: "Clipboard parse", icon: "doc.on.clipboard", source: "ClipboardParsingService", priority: .interactive)
        )

        var conversation = try parseResponse(responseText)

        // Override platform with URL-detected platform if AI didn't detect one
        if conversation.detectedPlatform == nil, let detectedPlatform {
            conversation.detectedPlatform = detectedPlatform
        }

        // Attach source URL
        conversation.sourceURL = sourceURL

        // If no conversation found but we have a source URL, fall back to profile content
        if conversation.messages.isEmpty {
            if sourceURL != nil {
                let profile = extractProfileContent(from: clipboardText, sourceURL: sourceURL, platform: detectedPlatform)
                logger.debug("No conversation found, falling back to profile content: \(profile.personName)")
                return .profileContent(profile)
            }
            throw ParseError.noConversationDetected
        }

        logger.debug("Parsed clipboard: \(conversation.messages.count) messages, platform: \(conversation.detectedPlatform ?? "unknown"), sourceURL: \(sourceURL?.absoluteString ?? "none")")
        return .conversation(conversation)
    }

    /// Read the raw clipboard text (for fallback "Save as Note").
    func readClipboardText() async -> String {
        await MainActor.run {
            NSPasteboard.general.string(forType: .string) ?? ""
        }
    }

    // MARK: - Source URL Detection

    /// Read the source URL from the pasteboard. Browsers typically place this
    /// as `public.url` or within `WebURLsWithTitlesPboardType`.
    @MainActor
    private func readSourceURL(from pb: NSPasteboard) -> URL? {
        // Try public.url first (most browsers)
        if let urlString = pb.string(forType: NSPasteboard.PasteboardType("public.url")),
           let url = URL(string: urlString) {
            return url
        }

        // Try WebURLsWithTitlesPboardType (Safari)
        if let data = pb.data(forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String]],
           let urls = plist.first,
           let first = urls.first,
           let url = URL(string: first) {
            return url
        }

        return nil
    }

    /// Detect platform from the source URL domain.
    private func platformFromURL(_ url: URL?) -> String? {
        guard let host = url?.host?.lowercased() else { return nil }
        if host.contains("linkedin.com") { return "LinkedIn" }
        if host.contains("facebook.com") || host.contains("messenger.com") { return "Facebook" }
        if host.contains("whatsapp.com") || host.contains("web.whatsapp.com") { return "WhatsApp" }
        if host.contains("slack.com") { return "Slack" }
        if host.contains("teams.microsoft.com") { return "Teams" }
        return nil
    }

    /// Extract a LinkedIn profile slug from a URL like "https://www.linkedin.com/in/clark-teders-b7b462113/"
    static func linkedInProfileSlug(from url: URL?) -> String? {
        guard let url, url.host?.lowercased().contains("linkedin.com") == true else { return nil }
        let components = url.pathComponents
        // Path is like /in/slug or /in/slug/
        guard let inIndex = components.firstIndex(of: "in"),
              inIndex + 1 < components.count else { return nil }
        let slug = components[inIndex + 1]
        return slug.isEmpty ? nil : slug
    }

    // MARK: - Profile Detection

    /// Check if a URL points to a social media profile page (not a messaging/conversation page).
    private func isProfileURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""

        // LinkedIn profile: /in/slug
        if host.contains("linkedin.com") && path.contains("/in/") {
            // Exclude messaging pages
            if path.contains("/messaging/") { return false }
            return true
        }

        // Facebook profile: /profile.php or /username (no /messages)
        if host.contains("facebook.com") {
            if path.contains("/messages") { return false }
            if path.contains("/profile.php") || path.components(separatedBy: "/").filter({ !$0.isEmpty }).count <= 1 {
                return true
            }
        }

        return false
    }

    /// Extract profile content from clipboard text, stripping common UI noise.
    private func extractProfileContent(from text: String, sourceURL: URL?, platform: String?) -> ClipboardProfileDTO {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Strip common LinkedIn/Facebook UI noise
        let uiNoise: Set<String> = [
            "connect", "follow", "message", "more", "pending", "accept", "ignore",
            "add to contacts", "import", "export", "like", "comment", "share",
            "report", "block", "see all", "show more", "show less", "about",
            "experience", "education", "skills", "activity", "interests",
            "1st", "2nd", "3rd", "1st degree connection", "2nd degree connection",
            "3rd degree connection", "people also viewed", "people you may know",
            "open to work", "mutual connections", "mutual connection"
        ]

        let cleaned = lines.filter { line in
            let lower = line.lowercased()
            // Remove exact UI matches
            if uiNoise.contains(lower) { return false }
            // Remove lines that are just a bullet or very short UI fragments
            if line.count <= 2 { return false }
            // Remove "X followers" / "X connections" type lines
            if lower.hasSuffix("followers") || lower.hasSuffix("connections") || lower.hasSuffix("following") { return false }
            return true
        }

        // First non-empty line is typically the person's name
        let personName = cleaned.first ?? "Unknown"
        let headline = cleaned.count > 1 ? cleaned[1] : nil

        // Build details from remaining lines
        let detailLines = cleaned.dropFirst(headline != nil ? 2 : 1)
        let details = detailLines.joined(separator: "\n")

        return ClipboardProfileDTO(
            personName: personName,
            headline: headline,
            details: details,
            platform: platform,
            sourceURL: sourceURL
        )
    }

    // MARK: - Prompt

    private func buildPrompt(text: String, sourceURL: URL?, detectedPlatform: String?) -> (system: String, user: String) {
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withDashSeparatorInDate])

        var platformHint = ""
        if let platform = detectedPlatform {
            platformHint = "\nThe text was copied from \(platform) (source: \(sourceURL?.absoluteString ?? "unknown")).\n"
        }

        let system = """
        You are analyzing text copied from a messaging application or social media page. Extract the conversation structure.
        \(platformHint)
        IMPORTANT: Text copied from web pages often includes UI elements (buttons, navigation labels, status indicators) mixed in with actual content. You MUST ignore any UI noise such as button labels, navigation text, import/export status messages, "Like", "Comment", "Share", "Connect", "Follow", "Message", "More", etc. Extract ONLY the actual conversation messages or profile notes.

        Respond with ONLY valid JSON matching this schema (do NOT copy example values — extract real data from the input):

        Schema:
        - "platform": string or null — detected from formatting cues (LinkedIn, WhatsApp, Slack, Teams, Facebook Messenger, etc.)
        - "conversation_date": string in YYYY-MM-DD format — use "\(today)" if not determinable from the text
        - "messages": array of objects, each with:
          - "sender": string — the actual name shown in the conversation
          - "text": string — the exact message text (preserve verbatim, but exclude UI button text)
          - "timestamp": string or null — as displayed in the text, or null if not visible
          - "is_from_me": boolean — true if the message is from the person who copied (often labelled "You" or "Me")

        Rules:
        - Extract ONLY names and text that appear in the input — never invent senders or messages
        - IGNORE UI elements: button labels, navigation items, status indicators, "Import", "Connect", "Follow", etc.
        - If the text is not a conversation, return {"platform": null, "messages": []}
        - Preserve original message text exactly as written
        """

        let user = "Extract the conversation from this copied text:\n\n\(text)"

        return (system, user)
    }

    // MARK: - Response Parsing

    private func parseResponse(_ text: String) throws -> ClipboardConversationDTO {
        // Extract JSON from response (may be wrapped in markdown code blocks)
        let jsonString: String
        if let startRange = text.range(of: "{"),
           let endRange = text.range(of: "}", options: .backwards) {
            jsonString = String(text[startRange.lowerBound...endRange.upperBound])
        } else {
            throw ParseError.aiParsingFailed("No JSON found in response")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw ParseError.aiParsingFailed("Invalid UTF-8")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.aiParsingFailed("Invalid JSON structure")
        }

        let platform = json["platform"] as? String
        let dateString = json["conversation_date"] as? String
        let conversationDate = parseDateString(dateString) ?? Date()

        guard let rawMessages = json["messages"] as? [[String: Any]] else {
            return ClipboardConversationDTO(messages: [], detectedPlatform: platform, conversationDate: conversationDate)
        }

        let messages: [ClipboardMessageDTO] = rawMessages.compactMap { msg in
            guard let sender = msg["sender"] as? String,
                  let msgText = msg["text"] as? String else { return nil }

            let isFromMe = msg["is_from_me"] as? Bool ?? false
            let timestampStr = msg["timestamp"] as? String
            let timestamp = parseTimestamp(timestampStr, baseDate: conversationDate)

            return ClipboardMessageDTO(
                senderName: sender,
                text: msgText,
                timestamp: timestamp,
                isFromMe: isFromMe
            )
        }

        return ClipboardConversationDTO(
            messages: messages,
            detectedPlatform: platform,
            conversationDate: conversationDate
        )
    }

    private func parseDateString(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    private func parseTimestamp(_ string: String?, baseDate: Date) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        // Try common time formats
        for format in ["h:mm a", "HH:mm", "h:mm:ss a", "HH:mm:ss"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: string) {
                let calendar = Calendar.current
                let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: time)
                var baseComponents = calendar.dateComponents([.year, .month, .day], from: baseDate)
                baseComponents.hour = timeComponents.hour
                baseComponents.minute = timeComponents.minute
                baseComponents.second = timeComponents.second
                return calendar.date(from: baseComponents)
            }
        }
        return nil
    }
}
