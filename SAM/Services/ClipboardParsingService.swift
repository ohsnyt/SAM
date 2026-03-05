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

struct ClipboardMessageDTO: Sendable, Identifiable {
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

struct ClipboardConversationDTO: Sendable {
    var messages: [ClipboardMessageDTO]
    var detectedPlatform: String?
    var conversationDate: Date
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

    func parseClipboard() async throws -> ClipboardConversationDTO {
        // Read clipboard on MainActor
        let clipboardText: String = await MainActor.run {
            NSPasteboard.general.string(forType: .string) ?? ""
        }

        guard !clipboardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.emptyClipboard
        }

        let (systemPrompt, userPrompt) = buildPrompt(text: clipboardText)
        let responseText = try await AIService.shared.generate(prompt: userPrompt, systemInstruction: systemPrompt)

        let conversation = try parseResponse(responseText)

        if conversation.messages.isEmpty {
            throw ParseError.noConversationDetected
        }

        logger.info("Parsed clipboard: \(conversation.messages.count) messages, platform: \(conversation.detectedPlatform ?? "unknown")")
        return conversation
    }

    /// Read the raw clipboard text (for fallback "Save as Note").
    func readClipboardText() async -> String {
        await MainActor.run {
            NSPasteboard.general.string(forType: .string) ?? ""
        }
    }

    // MARK: - Prompt

    private func buildPrompt(text: String) -> (system: String, user: String) {
        let system = """
        You are analyzing text copied from a messaging application. Extract the conversation structure.

        Respond with ONLY valid JSON:
        {
          "platform": "LinkedIn",
          "conversation_date": "2026-03-05",
          "messages": [
            {"sender": "Jane Smith", "text": "Hi, I wanted to follow up on our call.", "timestamp": "2:30 PM", "is_from_me": false},
            {"sender": "You", "text": "Thanks for reaching out!", "timestamp": "2:35 PM", "is_from_me": true}
          ]
        }

        Rules:
        - Detect platform from formatting cues (LinkedIn, WhatsApp, Slack, Teams, Facebook Messenger, etc.)
        - "is_from_me" = true if the message appears to be from the person who copied (often "You", "Me", or right-aligned messages)
        - "timestamp" as displayed in the text, or null if not visible
        - If the text is not a conversation, return {"platform": null, "messages": []}
        - Preserve original message text exactly
        - "conversation_date" should be today's date if not determinable from the text
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
