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
    /// Approximate character budget per chunk. Apple Intelligence has a
    /// hard 4096-token context window. The system instruction + prompt
    /// wrapper consume ~800-1000 tokens, leaving ~3000 tokens for
    /// transcript content. At ~3 chars/token (conservative for
    /// conversational English) that's ~9,000 characters. We use 6,000
    /// to leave a comfortable margin for the system instruction +
    /// prompt wrapper + JSON schema in summary prompts.
    static let maxChunkChars = 6_000

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

        // Short transcripts: single-pass (original path).
        if trimmed.count <= Self.maxChunkChars {
            return try await polishSingleChunk(trimmed, knownNouns: knownNouns)
        }

        // Long transcripts: chunk by paragraph boundaries, polish each
        // chunk independently, concatenate. This handles recordings that
        // exceed the Apple Intelligence 4096-token context window.
        let chunks = Self.chunkTranscript(trimmed, maxChars: Self.maxChunkChars)
        logger.info("Polishing long transcript in \(chunks.count) chunks (\(trimmed.count) total chars)")

        var polishedChunks: [String] = []
        for (i, chunk) in chunks.enumerated() {
            logger.info("Polishing chunk \(i + 1)/\(chunks.count) (\(chunk.count) chars)")
            let polished = try await polishSingleChunk(chunk, knownNouns: knownNouns)
            polishedChunks.append(polished)
        }

        let combined = polishedChunks.joined(separator: "\n\n")
        logger.info("Polished long transcript: \(combined.count) chars from \(chunks.count) chunks")
        return combined
    }

    /// Polish a single chunk that fits within the context window.
    private func polishSingleChunk(
        _ transcript: String,
        knownNouns: [String]
    ) async throws -> String {
        let systemInstruction = Self.systemInstruction()
        let prompt = Self.buildPrompt(transcript: transcript, knownNouns: knownNouns)

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
        let inputLen = transcript.count
        let outputLen = cleaned.count
        let ratio = Double(outputLen) / Double(max(inputLen, 1))
        if ratio < 0.5 || ratio > 2.5 {
            logger.warning("Polished text length ratio suspicious (\(String(format: "%.2f", ratio))× input); falling back to raw")
            return transcript
        }

        return cleaned
    }

    /// Split a transcript into chunks that fit within the context window.
    /// Splits on paragraph boundaries (blank lines between "Speaker: text"
    /// paragraphs) to preserve speaker turns intact. Never splits mid-turn.
    static func chunkTranscript(_ text: String, maxChars: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentLength = 0

        for paragraph in paragraphs {
            // If a single paragraph exceeds maxChars (e.g., all segments
            // assigned to one speaker), split it by sentences.
            if paragraph.count > maxChars {
                // Flush anything accumulated so far
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.joined(separator: "\n\n"))
                    currentChunk = []
                    currentLength = 0
                }
                // Split the oversized paragraph by sentence boundaries
                let sentences = paragraph.components(separatedBy: ". ")
                var sentenceChunk: [String] = []
                var sentenceLength = 0
                for sentence in sentences {
                    let sLen = sentence.count + 2
                    if sentenceLength + sLen > maxChars && !sentenceChunk.isEmpty {
                        chunks.append(sentenceChunk.joined(separator: ". "))
                        sentenceChunk = []
                        sentenceLength = 0
                    }
                    sentenceChunk.append(sentence)
                    sentenceLength += sLen
                }
                if !sentenceChunk.isEmpty {
                    chunks.append(sentenceChunk.joined(separator: ". "))
                }
                continue
            }

            let paragraphLen = paragraph.count + 2 // +2 for the "\n\n" separator
            if currentLength + paragraphLen > maxChars && !currentChunk.isEmpty {
                chunks.append(currentChunk.joined(separator: "\n\n"))
                currentChunk = []
                currentLength = 0
            }
            currentChunk.append(paragraph)
            currentLength += paragraphLen
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: "\n\n"))
        }

        return chunks
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
        recognition (ASR). Your job is to fix obvious transcription errors \
        and formatting artifacts while preserving the speaker turns, \
        meaning, and content of the original.

        CORE RULES
        1. SPEAKER LABELS: Use ONLY the speaker labels that appear in the \
           input. If the input only contains "Speaker 1", your output must \
           only contain "Speaker 1". NEVER invent additional labels. NEVER \
           add empty "Speaker 2:" or "Client:" sections at the end. NEVER \
           add a label for a speaker who has not yet spoken in the input.
        2. MEANING: Preserve the meaning of every sentence. Do not \
           rephrase, summarize, or reword.
        3. LENGTH: Your output should have roughly the same number of \
           words as the input -- within 10% on either side. Do not pad \
           with empty sections or extra speaker labels.
        4. NO COMMENTARY: Do not add headers, explanations, markdown \
           formatting, code fences, or any text that wasn't in the original \
           transcript. Do not echo these instructions.

        ASR ERRORS YOU SHOULD CONFIDENTLY FIX

        These ASR artifacts are common and you should fix them aggressively \
        without hedging:

        A. Spacing inside numbers and symbols. ASR often inserts spaces \
        that don't belong. Apply these MECHANICALLY across the entire \
        transcript -- every occurrence, every time:
           - Remove ANY space between a digit and a following "%" symbol:
               "9 %"          -> "9%"
               "25 %"         -> "25%"
               "0 %"          -> "0%"
               "1 .25 %"      -> "1.25%"
           - Remove the space inside thousand-separators in dollar amounts:
               "$12 ,000"     -> "$12,000"
               "$1 ,500 ,000" -> "$1,500,000"
           - Remove spaces around "&" inside acronyms or names:
               "S &P 500"     -> "S&P 500"
               "AT &T"        -> "AT&T"
           - Remove the space before the hyphen in number-noun compounds:
               "10 -year"     -> "10-year"
               "30 -day"      -> "30-day"
               "5 -minute"    -> "5-minute"
           - Format alphanumeric tax/account codes correctly:
               "K1"           -> "K-1"
               "401k"         -> "401(k)"

        B. Word-boundary errors where ASR splits a compound word:
           - "back stops"        -> "backstops"
           - "steward ship"      -> "stewardship"
           - "sub accounts"      -> "subaccounts"
           - "self -employment"  -> "self-employment"
           - "point -to -point"  -> "point-to-point"

        C. Sound-alike word errors in clear context:
           - "income writer"     -> "income rider"        (insurance jargon)
           - "their" vs "there"  -> context-driven
           - "incidence"         -> "incidents"           (when about events)
           - "principle" vs "principal" -> context-driven (financial \
             principal vs ethical principle)

        D. Broken sentence joins across transcription windows: if a \
        paragraph from the same speaker starts mid-thought, join it to the \
        previous sentence cleanly.

        E. Missing sentence-end punctuation and capitalization.

        F. PROPER NOUNS: If a known-proper-nouns list is provided, prefer \
        those spellings when a word sounds similar to one of them. Use the \
        supplied capitalization.

        WHAT YOU MUST NOT TOUCH
        - Filler words ("um", "uh", "you know") -- leave them in if present.
        - Colloquialisms, slang, or informal phrasing.
        - Dollar amounts, percentages, dates, and other numbers AS STATED \
          (only fix the spacing around them).
        - Industry jargon you don't recognize. Better to leave a term you \
          don't know than to "correct" it to a wrong word.
        - The order of speaker turns or the assignment of which speaker \
          said what.

        OUTPUT FORMAT
        Return ONLY the cleaned transcript in the same "Speaker N: text" \
        paragraph format as the input, with one blank line between \
        paragraphs. The number of paragraphs in your output must equal the \
        number of speaker turns in the input. Do not wrap in quotes, \
        markdown, or code blocks. Do not prefix with "Here is the cleaned \
        transcript:" or similar. Do not add a "Speaker 2:" or any other \
        label at the end if no second speaker is present. Just the cleaned \
        transcript, nothing else.
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
