//
//  ZoomChatParserService.swift
//  SAM
//
//  Created on April 7, 2026.
//  Parses Zoom chat export .txt files into structured DTOs.
//

import Foundation
import os.log

// MARK: - DTOs

/// A single parsed message from a Zoom chat export.
struct ParsedChatMessage: Sendable {
    let timestamp: String           // Raw HH:MM:SS string
    let secondsFromStart: TimeInterval
    let participantName: String
    let text: String
    let isReaction: Bool
    let isReply: Bool
}

/// Aggregated per-participant data from a parsed chat.
struct ParsedChatParticipant: Sendable {
    let displayName: String
    var messages: [ParsedChatMessage]
    var messageCount: Int
    var reactionCount: Int
    var questionCount: Int
    var questions: [String]
}

// MARK: - Service

actor ZoomChatParserService {

    static let shared = ZoomChatParserService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ZoomChatParser")

    private init() {}

    // MARK: - Parse

    /// Parse a Zoom chat .txt export file into structured participants and messages.
    /// Format: `HH:MM:SS\t From Name : message`
    /// Also handles: reactions ("Reacted to ... with ..."), replies ("Replying to ..."), multi-line messages.
    func parse(url: URL) throws -> (participants: [ParsedChatParticipant], messages: [ParsedChatMessage]) {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(text: content)
    }

    /// Parse raw Zoom chat text content.
    func parse(text: String) -> (participants: [ParsedChatParticipant], messages: [ParsedChatMessage]) {
        let lines = text.components(separatedBy: "\n")

        var allMessages: [ParsedChatMessage] = []
        var currentTimestamp: String?
        var currentName: String?
        var currentTextLines: [String] = []
        var firstTimestamp: TimeInterval?

        // Regex: HH:MM:SS\tFrom Name : message
        // Zoom format variations:
        //   "18:33:33\t From ! Sarah Snyder, sarah-snyder.com : message"
        //   "18:33:33\t From Brad Keim : message"
        let linePattern = #/^(\d{2}:\d{2}:\d{2})\t\s*From\s+(.+?)\s*:\s*(.*)$/#

        func flushCurrent() {
            guard let ts = currentTimestamp, let name = currentName else { return }
            let fullText = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fullText.isEmpty else { return }

            let seconds = parseTimestamp(ts)
            if firstTimestamp == nil { firstTimestamp = seconds }
            let relativeSeconds = seconds - (firstTimestamp ?? seconds)

            let isReaction = fullText.hasPrefix("Reacted to")
            let isReply = fullText.hasPrefix("Replying to")

            allMessages.append(ParsedChatMessage(
                timestamp: ts,
                secondsFromStart: relativeSeconds,
                participantName: cleanName(name),
                text: fullText,
                isReaction: isReaction,
                isReply: isReply
            ))
        }

        for line in lines {
            if let match = line.wholeMatch(of: linePattern) {
                // Flush previous message
                flushCurrent()

                currentTimestamp = String(match.1)
                currentName = String(match.2)
                currentTextLines = [String(match.3)]
            } else {
                // Continuation line of a multi-line message
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    currentTextLines.append(trimmed)
                }
            }
        }

        // Flush last message
        flushCurrent()

        // Aggregate by participant
        var participantMap: [String: ParsedChatParticipant] = [:]
        for msg in allMessages {
            let name = msg.participantName
            var participant = participantMap[name] ?? ParsedChatParticipant(
                displayName: name,
                messages: [],
                messageCount: 0,
                reactionCount: 0,
                questionCount: 0,
                questions: []
            )

            participant.messages.append(msg)

            if msg.isReaction {
                participant.reactionCount += 1
            } else {
                participant.messageCount += 1
            }

            // Detect questions (ends with ? and not a reaction)
            if !msg.isReaction && msg.text.contains("?") {
                participant.questionCount += 1
                participant.questions.append(msg.text)
            }

            participantMap[name] = participant
        }

        let participants = Array(participantMap.values).sorted { $0.messageCount > $1.messageCount }

        logger.info("Parsed Zoom chat: \(allMessages.count) messages from \(participants.count) participants")

        return (participants: participants, messages: allMessages)
    }

    // MARK: - Helpers

    /// Parse "HH:MM:SS" into seconds since midnight.
    private func parseTimestamp(_ ts: String) -> TimeInterval {
        let parts = ts.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// Clean display name: strip leading "!" markers, trim whitespace.
    private func cleanName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove leading "!" that Zoom uses for host/co-host markers
        while name.hasPrefix("!") {
            name = String(name.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Remove trailing URL/domain if present (e.g., "Sarah Snyder, sarah-snyder.com")
        if let commaIndex = name.firstIndex(of: ",") {
            let afterComma = name[name.index(after: commaIndex)...].trimmingCharacters(in: .whitespaces)
            if afterComma.contains(".") && !afterComma.contains(" ") {
                // Looks like a URL/domain, strip it
                name = String(name[..<commaIndex]).trimmingCharacters(in: .whitespaces)
            }
        }
        return name
    }
}
