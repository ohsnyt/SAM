//
//  TranscriptPolishService.swift
//  SAM
//
//  Post-transcription cleanup pass. Takes a speaker-attributed transcript
//  and asks Apple FoundationModels to fix mis-transcribed proper nouns,
//  broken sentences at window boundaries, punctuation, and capitalization —
//  WITHOUT rephrasing, summarizing, or changing speaker attribution.
//
//  Runs through the shared AIService facade (same pattern as
//  MeetingSummaryService and NoteAnalysisService). Designed to be called
//  in parallel with summary generation at session end.
//
//  Feeds SAM's existing context to the LLM as "known proper nouns":
//    - Business organization name from BusinessProfile
//    - Contact display names from SamPerson records
//    - User-defined vocabulary (future)
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TranscriptPolishService")

actor TranscriptPolishService {

    static let shared = TranscriptPolishService()

    private init() {}

    // MARK: - Public API

    /// Polish a speaker-attributed transcript in place.
    ///
    /// - Parameters:
    ///   - transcript: The raw transcript with speaker labels. Expected
    ///     format is the same `"Speaker: text\n\nSpeaker: text"` shape
    ///     that `MeetingSummaryService` consumes.
    ///   - knownNouns: Proper nouns + vocabulary the LLM should prefer
    ///     when correcting mis-transcriptions. Typically pulled from the
    ///     user's business profile + contacts by the caller.
    /// - Returns: The cleaned transcript in the same format.
    /// - Throws: `PolishError` if the AI backend is unavailable or the
    ///   response is invalid.
    func polish(
        transcript: String,
        knownNouns: [String] = []
    ) async throws -> String {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw PolishError.modelUnavailable
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PolishError.emptyTranscript
        }

        let systemInstruction = Self.systemInstruction()
        let prompt = Self.buildPrompt(transcript: trimmed, knownNouns: knownNouns)

        logger.info("Polishing transcript (\(trimmed.count) chars, \(knownNouns.count) known nouns)")

        // Note: we allow a generous token budget because polished output
        // is typically very close to input length. If we cut it off
        // early the user ends up with a truncated transcript.
        let responseText = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: systemInstruction,
            maxTokens: 4096
        )

        let cleaned = Self.stripWrappers(responseText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            throw PolishError.invalidResponse
        }

        // Sanity check: polished text should be roughly the same length
        // as the input (within 50-200% range). If the LLM truncated
        // aggressively or rambled, fall back to the original rather than
        // deliver broken data.
        let inputLen = trimmed.count
        let outputLen = cleaned.count
        let ratio = Double(outputLen) / Double(max(inputLen, 1))
        if ratio < 0.5 || ratio > 2.5 {
            logger.warning("Polished text length ratio suspicious (\(String(format: "%.2f", ratio))× input); falling back to raw")
            return trimmed
        }

        logger.info("Polished transcript ready: \(outputLen) chars (ratio \(String(format: "%.2f", ratio))×)")
        return cleaned
    }

    // MARK: - Known Noun Gathering (convenience)

    /// Gather known proper nouns from SAM's business profile and contacts.
    /// Called from the coordinator before `polish()` so the service itself
    /// stays independent of SwiftData.
    ///
    /// Returns up to `maxContacts` contact names in order of most recently
    /// accessed, plus the business organization name if set.
    static func gatherKnownNouns(
        from modelContainer: ModelContainer,
        maxContacts: Int = 60
    ) async -> [String] {
        var nouns: [String] = []

        // Business organization name
        let profile = await BusinessProfileService.shared.profile()
        let org = profile.organization.trimmingCharacters(in: .whitespacesAndNewlines)
        if !org.isEmpty {
            nouns.append(org)
        }

        // Contact display names — cap the list so prompt size stays
        // reasonable. A typical Apple Intelligence prompt tolerates
        // ~1000 tokens of context comfortably; 60 names ≈ 300 tokens.
        do {
            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<SamPerson>(
                sortBy: [SortDescriptor(\SamPerson.displayName)]
            )
            descriptor.fetchLimit = maxContacts
            let people = try context.fetch(descriptor)
            for person in people {
                let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !nouns.contains(name) {
                    nouns.append(name)
                }
            }
        } catch {
            logger.warning("Could not fetch contacts for polish nouns: \(error.localizedDescription)")
        }

        return nouns
    }

    // MARK: - Prompt

    /// Internal so the test harness's stage cache can hash the active prompt
    /// into its cache key — when the user edits the prompt, the cache key
    /// changes and polish re-runs without needing a manual version bump.
    static func systemInstruction() -> String {
        let custom = UserDefaults.standard.string(forKey: "sam.ai.transcriptPolishPrompt") ?? ""
        if !custom.isEmpty { return custom }

        return """
        You clean up meeting transcripts produced by automatic speech \
        recognition. Your ONLY job is to fix transcription errors while \
        preserving the exact meaning, speaker attribution, and paragraph \
        structure of the original.

        CRITICAL RULES (never violate):
        1. PRESERVE speaker attribution EXACTLY. Each paragraph begins \
           with a label (e.g. "Agent:", "Client:", "Speaker 1:") followed \
           by text. Never reassign what was said to a different speaker. \
           Never add or remove speaker labels. Never change the order of \
           paragraphs.
        2. PRESERVE meaning EXACTLY. Do not rephrase, summarize, or reword. \
           The polished text must say the same thing the original did, \
           just with correct spelling and punctuation.
        3. PRESERVE length. Your output should be roughly the same number \
           of words as the input. Do not shorten or expand.
        4. DO NOT add commentary, explanations, headers, markdown, or any \
           text that wasn't in the original transcript.

        WHAT YOU SHOULD FIX:
        - Mis-transcribed proper nouns (people names, organization names, \
          places). If a known-proper-nouns list is provided, prefer those \
          spellings when a word sounds similar.
        - Obvious sound-alike word errors (e.g. "their" vs "there", \
          "stewardship" vs "steward ship").
        - Broken sentences split across transcription-window boundaries \
          (common at ~30-second intervals). If a sentence ends abruptly \
          and the next paragraph from the same speaker starts mid-thought, \
          join them into one coherent sentence.
        - Missing or wrong punctuation at sentence boundaries.
        - Incorrect capitalization of proper nouns and sentence starts.
        - Stray single characters, partial words, or artifacts left behind \
          by ASR.

        WHAT YOU MUST NOT TOUCH:
        - Filler words ("um", "uh", "you know") — leave them in if present.
        - Colloquialisms, slang, or informal phrasing.
        - Numbers or dollar amounts as stated.
        - Anything you aren't certain is wrong.

        OUTPUT FORMAT:
        Return ONLY the cleaned transcript in the same "Speaker: text" \
        paragraph format as the input, with one blank line between \
        paragraphs. Do not wrap in quotes, markdown, code blocks, or any \
        other formatting. Do not prefix with "Here is the cleaned \
        transcript:" or similar. Just the cleaned transcript, nothing else.
        """
    }

    private static func buildPrompt(transcript: String, knownNouns: [String]) -> String {
        var blocks: [String] = []

        if !knownNouns.isEmpty {
            let nounList = knownNouns.map { "- \($0)" }.joined(separator: "\n")
            blocks.append("""
            KNOWN PROPER NOUNS (prefer these spellings when fixing similar-sounding mis-transcriptions):
            \(nounList)
            """)
        }

        blocks.append("""
        TRANSCRIPT TO CLEAN:
        \(transcript)
        """)

        blocks.append("""
        Return ONLY the cleaned transcript in the same paragraph format, \
        with no commentary, no markdown, no quotes, no code fences. Every \
        speaker label from the original must appear in the output, in the \
        same order.
        """)

        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Response Cleanup

    /// Strip common LLM response wrappers that sneak in despite
    /// "return only the transcript" instructions:
    /// - Markdown code fences (```...```)
    /// - Leading/trailing prose like "Here is the cleaned transcript:"
    /// - Wrapping quotes
    private static func stripWrappers(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip <think>...</think> blocks (reasoning-model leakage)
        if let range = cleaned.range(of: "<think>"),
           let endRange = cleaned.range(of: "</think>", range: range.upperBound..<cleaned.endIndex) {
            cleaned.removeSubrange(range.lowerBound...endRange.upperBound)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip markdown code fences
        if cleaned.hasPrefix("```") {
            var lines = cleaned.components(separatedBy: "\n")
            // Drop the opening fence line (```text or just ```)
            if !lines.isEmpty { lines.removeFirst() }
            // Drop the closing fence
            if let lastIdx = lines.indices.last, lines[lastIdx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip common leading preambles
        let preambles = [
            "Here is the cleaned transcript:",
            "Here's the cleaned transcript:",
            "Cleaned transcript:",
            "Transcript:",
            "Here is the polished transcript:",
            "Here's the polished transcript:"
        ]
        for preamble in preambles {
            if cleaned.lowercased().hasPrefix(preamble.lowercased()) {
                cleaned = String(cleaned.dropFirst(preamble.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return cleaned
    }

    // MARK: - Errors

    enum PolishError: Error, LocalizedError {
        case modelUnavailable
        case emptyTranscript
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .modelUnavailable: return "The on-device AI model is not available for polishing."
            case .emptyTranscript: return "The transcript is empty."
            case .invalidResponse: return "The AI returned an invalid response."
            }
        }
    }
}
