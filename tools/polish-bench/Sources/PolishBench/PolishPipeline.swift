//
//  PolishPipeline.swift
//  polish-bench
//
//  Mirror of `TranscriptPolishService` from the main SAM target — copied
//  (not imported) so the bench stays decoupled from the app's SwiftData
//  container, AIService circuit breaker, and FoundationModels availability
//  gating. The bench only needs the chunking heuristics, the prompt, and
//  the response sanitizer.
//
//  Keep this file in sync with TranscriptPolishService when the production
//  prompt changes. The bench is only meaningful if its prompt matches what
//  ships in the app.
//

import Foundation

enum PolishPipeline {

    /// Chunking ceiling. Same value the production service uses (6,000
    /// chars) so the bench exercises the same chunk count per transcript.
    static let maxChunkChars = 6_000

    /// Polish a full transcript via the provided MLX backend.
    static func run(
        transcript: String,
        knownNouns: [String],
        backend: MLXBackend
    ) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw PipelineError.emptyTranscript }

        if trimmed.count <= maxChunkChars {
            return try await polishChunk(trimmed, knownNouns: knownNouns, backend: backend, original: trimmed)
        }

        let chunks = chunkTranscript(trimmed, maxChars: maxChunkChars)
        var polished: [String] = []
        for chunk in chunks {
            let cleaned = try await polishChunk(chunk, knownNouns: knownNouns, backend: backend, original: chunk)
            polished.append(cleaned)
        }
        return polished.joined(separator: "\n\n")
    }

    private static func polishChunk(
        _ chunk: String,
        knownNouns: [String],
        backend: MLXBackend,
        original: String
    ) async throws -> String {
        let system = systemInstruction()
        let prompt = buildPrompt(transcript: chunk, knownNouns: knownNouns)

        let raw = try await backend.generate(
            systemInstruction: system,
            prompt: prompt,
            maxTokens: 4096
        )
        let cleaned = stripWrappers(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { throw PipelineError.emptyResponse }

        // Same sanity check the production service uses: if the polished
        // output is suspiciously short or long, surface the raw chunk
        // instead of a truncated/rambling response. The bench still scores
        // the original as that model's output so the fallback is visible.
        let ratio = Double(cleaned.count) / Double(max(original.count, 1))
        if ratio < 0.5 || ratio > 2.5 {
            return original
        }
        return cleaned
    }

    // MARK: - Chunking

    /// Port of `TranscriptPolishService.chunkTranscript`. Splits on
    /// paragraph boundaries (speaker turns) first; if a single turn is
    /// larger than the max, falls back to sentence splits inside that
    /// turn.
    static func chunkTranscript(_ text: String, maxChars: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current: [String] = []
        var currentLen = 0

        for paragraph in paragraphs {
            if paragraph.count > maxChars {
                if !current.isEmpty {
                    chunks.append(current.joined(separator: "\n\n"))
                    current = []
                    currentLen = 0
                }
                let sentences = paragraph.components(separatedBy: ". ")
                var sChunk: [String] = []
                var sLen = 0
                for sentence in sentences {
                    let add = sentence.count + 2
                    if sLen + add > maxChars && !sChunk.isEmpty {
                        chunks.append(sChunk.joined(separator: ". "))
                        sChunk = []
                        sLen = 0
                    }
                    sChunk.append(sentence)
                    sLen += add
                }
                if !sChunk.isEmpty { chunks.append(sChunk.joined(separator: ". ")) }
                continue
            }

            let add = paragraph.count + 2
            if currentLen + add > maxChars && !current.isEmpty {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                currentLen = 0
            }
            current.append(paragraph)
            currentLen += add
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
    }

    // MARK: - Prompt (copy of TranscriptPolishService.systemInstruction)

    static func systemInstruction() -> String {
        """
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

    static func buildPrompt(transcript: String, knownNouns: [String]) -> String {
        var blocks: [String] = []
        if !knownNouns.isEmpty {
            let list = knownNouns.map { "- \($0)" }.joined(separator: "\n")
            blocks.append("""
            KNOWN PROPER NOUNS (prefer these spellings when fixing similar-sounding mis-transcriptions):
            \(list)
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

    // MARK: - Response sanitizer (copy of TranscriptPolishService.stripWrappers)

    static func stripWrappers(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let open = cleaned.range(of: "<think>"),
           let close = cleaned.range(of: "</think>", range: open.upperBound..<cleaned.endIndex) {
            cleaned.removeSubrange(open.lowerBound...close.upperBound)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if cleaned.hasPrefix("```") {
            var lines = cleaned.components(separatedBy: "\n")
            if !lines.isEmpty { lines.removeFirst() }
            if let last = lines.indices.last,
               lines[last].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let preambles = [
            "Here is the cleaned transcript:",
            "Here's the cleaned transcript:",
            "Cleaned transcript:",
            "Transcript:",
            "Here is the polished transcript:",
            "Here's the polished transcript:"
        ]
        for p in preambles {
            if cleaned.lowercased().hasPrefix(p.lowercased()) {
                cleaned = String(cleaned.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return cleaned
    }

    enum PipelineError: LocalizedError {
        case emptyTranscript
        case emptyResponse
        var errorDescription: String? {
            switch self {
            case .emptyTranscript: return "transcript is empty"
            case .emptyResponse:   return "model returned empty response"
            }
        }
    }
}
