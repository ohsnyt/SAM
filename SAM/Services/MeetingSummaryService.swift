//
//  MeetingSummaryService.swift
//  SAM
//
//  Generates a structured meeting summary from a speaker-attributed
//  transcript. Runs through the shared AIService facade (FoundationModels
//  on-device) following the same JSON-extraction pattern as
//  NoteAnalysisService / PipelineAnalystService.
//
//  The DTO is Codable so it can be persisted as JSON on TranscriptSession
//  AND transported back to the iPhone over the audio streaming protocol.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MeetingSummaryService")

// `MeetingSummary` is defined in SAMModels-Transcription.swift so both the
// Mac and iPhone targets can share the wire format.

// MARK: - Service

actor MeetingSummaryService {

    static let shared = MeetingSummaryService()

    private init() {}

    // MARK: - Availability

    /// Check whether the underlying AI backend can generate a summary right now.
    func checkAvailability() async -> AIService.ModelAvailability {
        await AIService.shared.checkAvailability()
    }

    // MARK: - Summary Generation

    /// Generate a structured summary from a transcript.
    ///
    /// - Parameter transcript: Formatted transcript with speaker labels
    ///   (e.g. `"Agent: ...\n\nClient: ...\n\nAgent: ..."`).
    /// - Parameter metadata: Optional meta info to include in the prompt
    ///   (duration, number of speakers, etc).
    /// - Returns: A `MeetingSummary` DTO.
    func summarize(
        transcript: String,
        metadata: Metadata = .init()
    ) async throws -> MeetingSummary {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw SummaryError.modelUnavailable
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummaryError.emptyTranscript
        }

        let systemInstruction = Self.systemInstruction()
        let prompt = Self.buildPrompt(transcript: trimmed, metadata: metadata)

        logger.info("Generating meeting summary (\(trimmed.count) chars)")

        let responseText = try await AIService.shared.generate(
            prompt: prompt,
            systemInstruction: systemInstruction,
            maxTokens: 1500
        )

        // Extract and parse JSON using the shared utility (handles <think> blocks,
        // markdown fences, unicode normalization).
        let cleaned = JSONExtraction.extractJSON(from: responseText)
        guard let data = cleaned.data(using: .utf8) else {
            throw SummaryError.invalidResponse
        }

        do {
            let decoded = try JSONDecoder().decode(MeetingSummary.self, from: data)
            logger.info("Meeting summary generated: \(decoded.decisions.count) decisions, \(decoded.actionItems.count) action items, \(decoded.followUps.count) follow-ups")
            return decoded
        } catch {
            // Fallback: if JSON decode fails but we got non-empty text,
            // treat the whole response as the tl;dr so users at least see something.
            let plainText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                logger.warning("Meeting summary JSON decode failed; using plain-text fallback: \(error.localizedDescription)")
                var fallback = MeetingSummary.empty
                fallback.tldr = String(plainText.prefix(500))
                return fallback
            }
            throw SummaryError.invalidResponse
        }
    }

    // MARK: - Metadata

    struct Metadata: Sendable {
        var durationSeconds: TimeInterval = 0
        var speakerCount: Int = 0
        var detectedLanguage: String? = nil
        var recordedAt: Date? = nil

        func promptLines() -> String {
            var lines: [String] = []
            if durationSeconds > 0 {
                let mins = Int(durationSeconds) / 60
                let secs = Int(durationSeconds) % 60
                lines.append("Duration: \(mins)m \(secs)s")
            }
            if speakerCount > 0 {
                lines.append("Speakers detected: \(speakerCount)")
            }
            if let lang = detectedLanguage, !lang.isEmpty {
                lines.append("Language: \(lang)")
            }
            if let recordedAt {
                lines.append("Recorded: \(recordedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Prompt

    /// Internal so the test harness's stage cache can hash the active prompt
    /// into its cache key — edits to the prompt invalidate the summary cache
    /// automatically without needing a manual version bump.
    static func systemInstruction() -> String {
        // Allow user override via Settings
        let custom = UserDefaults.standard.string(forKey: "sam.ai.meetingSummaryPrompt") ?? ""
        if !custom.isEmpty { return custom }

        return """
        You summarize meeting transcripts for a financial advisor. Output \
        ONLY a JSON object matching the exact schema below. Every value you \
        emit must come from the transcript -- NEVER invent people, tasks, \
        topics, dates, or any other content.

        CRITICAL OUTPUT RULES
        - Respond with ONLY a raw JSON object starting with { and ending with }.
        - Do NOT wrap the JSON in markdown code blocks or prose.
        - Use ONLY ASCII characters (no smart quotes, no em-dashes).
        - If the transcript does not mention something for a field, use an \
          empty string or empty array for that field. NEVER fill fields with \
          invented content.
        - If the meeting is short, the summary should also be short.
        - If there is no decision, actionItems is still an array but may be empty.

        GROUNDING RULES
        - Every task, name, topic, date, and quote must be explicitly \
          present in the transcript. Do not paraphrase in ways that add \
          information.
        - Do not use any placeholder names. Use only names that literally \
          appear in the transcript.
        - When in doubt, leave fields empty.

        FIELD DEFINITIONS

        - tldr: 1-3 plain-language sentences summarizing what was actually \
          said. If two or more named individuals appear in the transcript \
          (other than the agent), mention them by name in the tldr. Always \
          include the most concrete commitment or decision if there is one. \
          Do not write a generic statement like "participants discussed \
          paperwork" -- name the people and the specific things they decided.

        - decisions: Concrete commitments or choices made during the \
          meeting (e.g. "Karen will move forward with the indexed annuity", \
          "Margaret postponed retitling Robert's accounts until April"). \
          NOT plans to discuss or explore -- only commitments that were made.

        - actionItems: Concrete tasks. Each has { task, owner, dueDate }. \
          owner is who will do it ("Agent", "Client", or a name from the \
          transcript). dueDate is free text -- "by Friday", "next week", \
          "before our next meeting on the 18th". Include EVERY task \
          assigned in the meeting, even if the same person owns several. \
          Omit owner/dueDate if not stated.

        - openQuestions: Things that still need answering.

        - followUps: Relationship-maintenance touches (checking in with \
          someone), NOT work tasks. Each has { person, reason }. Use this \
          for empathetic check-ins after life events, social courtesy \
          calls, or holiday outreach.

        - lifeEvents: Births, deaths, marriages, divorces, job changes, \
          retirements, moves, health events, college transitions, military \
          deployments. Include if explicitly mentioned in the transcript.

        - topics: Short topic tags (1-4 words each) describing what was \
          discussed. Include 2-6 topics for any meeting longer than a quick \
          reminder. Examples: "retirement planning", "indexed annuity", \
          "estate planning", "529 college savings", "rollover paperwork", \
          "beneficiary designations", "trust documents", "tax planning". \
          This field should rarely be empty -- if anything substantive was \
          discussed, name the topics.

        - complianceFlags: STATEMENTS that could trigger a regulatory \
          review. This is the MOST IMPORTANT field. The advisor's livelihood \
          depends on catching every potential violation. Be aggressive: if \
          you see any of the patterns below, you MUST add an entry. Empty \
          array is only correct if NONE of these patterns appear in the \
          transcript. NEVER invent a name to refer to "the advisor" -- use \
          only names that literally appear in the transcript.

           Patterns to flag (extract the offending phrase or close paraphrase):
           * GUARANTEES of investment performance: "guaranteed", \
             "risk-free", "zero risk", "can't lose", "principal protected", \
             "no downside"
           * COMPARATIVE PERFORMANCE claims: "outperformed the S&P", \
             "beats the market", "more reliable than bonds", "best in the \
             industry"
           * PROJECTED RETURNS with specific numbers: "8% annually", \
             "double your money in ten years", "averages 11% per year"
           * REBATING (illegal in most states): "agent rebate", "kickback", \
             "I'll cover your first premium", "cash back"
           * UNSUITABLE products mismatched to stated risk tolerance or \
             time horizon
           * PROHIBITED CLAIMS: "FDIC insured" on non-FDIC products, \
             "tax-free" on taxable products, "no fees" when fees exist

           Worked example. Suppose the transcript contains:

               Agent: This product has guaranteed eight percent annual \
               returns through the income rider, and there is zero risk of \
               losing your principal. This fund has outperformed the S&P \
               500 every year since 2015. As a thank you, I can offer you \
               an agent rebate of two hundred dollars on the first year \
               premium.

           Then complianceFlags MUST be:

               [
                 "Claimed guaranteed 8% annual returns through the income rider",
                 "Claimed zero risk of losing principal",
                 "Claimed fund has outperformed the S&P 500 every year since 2015",
                 "Offered $200 agent rebate on first year premium (rebating)"
               ]

           Do NOT mention these things only in the tldr -- they must \
           appear in complianceFlags as well, even if you cover them in \
           the tldr.

        - sentiment: Optional brief phrase describing the tone (e.g. "warm \
          and trusting", "cautious", "grieving").

        JSON SCHEMA (structure only)
        {
          "tldr": "<string>",
          "decisions": ["<string>", ...],
          "actionItems": [{"task": "<string>", "owner": "<string or null>", "dueDate": "<string or null>"}, ...],
          "openQuestions": ["<string>", ...],
          "followUps": [{"person": "<string>", "reason": "<string>"}, ...],
          "lifeEvents": ["<string>", ...],
          "topics": ["<string>", ...],
          "complianceFlags": ["<string>", ...],
          "sentiment": "<string or null>"
        }
        """
    }

    private static func buildPrompt(transcript: String, metadata: Metadata) -> String {
        let metaLines = metadata.promptLines()
        let metaBlock = metaLines.isEmpty ? "" : "METADATA:\n\(metaLines)\n\n"

        return """
        \(metaBlock)TRANSCRIPT:
        \(transcript)

        Summarize ONLY the transcript above. Every field in your JSON output \
        must be grounded in this transcript. If a field has no relevant \
        content, use an empty string or empty array. Do NOT invent content. \
        Do NOT reference any prior example. Return ONLY the JSON object.
        """
    }

    // MARK: - Errors

    enum SummaryError: Error, LocalizedError {
        case modelUnavailable
        case emptyTranscript
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .modelUnavailable: return "The on-device AI model is not available."
            case .emptyTranscript: return "The transcript is empty."
            case .invalidResponse: return "The AI returned an invalid response."
            }
        }
    }
}

// Persistence/wire helpers live on the shared `MeetingSummary` struct in
// SAMModels-Transcription.swift so both targets can use them.
