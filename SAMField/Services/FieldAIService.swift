//
//  FieldAIService.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F2: Voice Capture
//
//  Lightweight AI service for iOS using Apple FoundationModels.
//  Handles transcription polish and note summarization.
//  No MLX — FoundationModels only for on-device inference.
//

import Foundation
import FoundationModels
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "FieldAIService")

@MainActor
@Observable
final class FieldAIService {

    static let shared = FieldAIService()

    private(set) var isAvailable = false

    private init() {
        checkAvailability()
    }

    private func checkAvailability() {
        isAvailable = SystemLanguageModel.default.isAvailable
    }

    // MARK: - Transcription Polish

    /// Clean up raw speech-to-text output: fix punctuation, capitalize properly,
    /// remove filler words, and structure into paragraphs.
    func polishTranscript(_ rawText: String) async -> String {
        guard isAvailable, !rawText.isEmpty else { return rawText }

        let prompt = """
        Clean up this voice transcription. Fix punctuation, capitalization, and grammar. \
        Remove filler words (um, uh, like, you know). Break into paragraphs where topic changes. \
        Preserve the speaker's meaning exactly — do not add, remove, or change any substantive content. \
        Return only the polished text with no preamble.

        Transcription:
        \(rawText)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let polished = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("Polished transcript: \(polished.prefix(100))...")
            return polished.isEmpty ? rawText : polished
        } catch {
            logger.warning("Polish failed, returning raw transcript: \(error.localizedDescription)")
            return rawText
        }
    }

    // MARK: - Note Summarization

    /// Generate a 1-2 sentence summary of a note for list display.
    func summarize(_ text: String) async -> String? {
        guard isAvailable, !text.isEmpty else { return nil }

        let prompt = """
        Summarize this note in 1-2 sentences. Focus on the key takeaway or action item. \
        Be specific — name people and topics mentioned. Return only the summary.

        Note:
        \(text)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : summary
        } catch {
            logger.warning("Summarization failed: \(error.localizedDescription)")
            return nil
        }
    }
}
