//
//  RegressionJudgeService.swift
//  SAM
//
//  DEBUG-only LLM-as-judge for transcription pipeline regression testing.
//
//  Traditional snapshot tests fail on cosmetic LLM drift (the polish service
//  rephrases a sentence slightly between runs). That makes them useless for
//  testing FoundationModels-backed code paths — false positives drown the
//  signal.
//
//  This service combines two tiers of comparison:
//
//    Tier 1 — DETERMINISTIC: exact-match check on segment counts, speaker
//             counts, summary item counts, language detection, transcript
//             text. These come from Whisper and the structured summary
//             extraction; they should be byte-stable across runs given the
//             stage cache. Any difference is flagged as REGRESSION.
//
//    Tier 2 — LLM JUDGE: semantic comparison of polished text and summary
//             tl;dr against the golden baseline. The on-device foundation
//             model evaluates whether the current output preserves the
//             meaning of the golden, classifying as IDENTICAL,
//             COSMETIC_DRIFT, IMPROVEMENT, REGRESSION, or NEEDS_REVIEW.
//
//  The judge prompt asks specifically for ANCHORED comparison ("did this
//  get worse than this baseline") rather than absolute quality grading
//  ("is this good"), which sidesteps the well-known LLM-judge bias of a
//  model grading its own output favorably.
//
//  Verdicts feed back into the test result JSON written by TestInboxWatcher
//  so run-test.sh / run-all.sh / metrics-report.sh can surface them.
//

#if DEBUG

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RegressionJudgeService")

@MainActor
final class RegressionJudgeService {

    static let shared = RegressionJudgeService()

    private init() {}

    // MARK: - Verdict Types

    enum VerdictKind: String, Sendable, Codable {
        /// Output matches the golden exactly. Perfect deterministic stage,
        /// or LLM judged the polished/summary text as identical.
        case identical = "IDENTICAL"

        /// Output differs only in inconsequential ways (rephrasing, word
        /// order, capitalization). Same meaning, no information loss.
        case cosmeticDrift = "COSMETIC_DRIFT"

        /// Current output is judged better than the golden. Caller should
        /// consider re-recording the golden after manual review.
        case improvement = "IMPROVEMENT"

        /// Current output dropped meaning, lost information, or
        /// introduced an error not present in the golden. The pipeline
        /// regressed and the change should be investigated.
        case regression = "REGRESSION"

        /// Judge couldn't decide. Surface for human review.
        case needsReview = "NEEDS_REVIEW"

        /// Whether this verdict should fail the test cycle.
        var isFailing: Bool {
            self == .regression
        }

        /// User-facing emoji for terminal output.
        var emoji: String {
            switch self {
            case .identical:     return "✅"
            case .cosmeticDrift: return "✅"
            case .improvement:   return "🎉"
            case .regression:    return "❌"
            case .needsReview:   return "🟡"
            }
        }
    }

    /// One field-level finding from the judge.
    struct FieldVerdict: Sendable, Codable {
        let field: String          // e.g. "polishedText", "summaryTLDR", "segmentCount"
        let kind: VerdictKind
        let reason: String         // human-readable explanation
        let golden: String?        // first 200 chars of baseline (for context)
        let current: String?       // first 200 chars of current output
    }

    /// Aggregate verdict combining all field findings.
    struct Verdict: Sendable, Codable {
        let overallKind: VerdictKind
        let summary: String        // one-sentence summary
        let fieldVerdicts: [FieldVerdict]
        let judgeDurationSeconds: TimeInterval
        let judgedAt: Date

        var isFailing: Bool { overallKind.isFailing }
    }

    // MARK: - Public API

    /// Compare a current pipeline result against a golden baseline and
    /// produce a verdict. The judge looks at counts (deterministic) and
    /// semantic content (LLM-judged) and returns the worst-case verdict
    /// across all fields.
    func judge(
        scenarioID: String,
        golden: TestResultPayload,
        current: TestResultPayload
    ) async -> Verdict {
        let startTime = Date()
        var findings: [FieldVerdict] = []

        // ─── Tier 1: deterministic field comparison ──────────────
        findings.append(contentsOf: deterministicComparisons(golden: golden, current: current))

        // ─── Tier 2: LLM judge for stochastic text fields ────────
        if let goldPolished = golden.output.polishedSample,
           let curPolished = current.output.polishedSample {
            let polishedVerdict = await judgeText(
                field: "polishedSample",
                golden: goldPolished,
                current: curPolished,
                role: .polishedTranscript
            )
            findings.append(polishedVerdict)
        } else if golden.output.polishedSample != nil && current.output.polishedSample == nil {
            findings.append(FieldVerdict(
                field: "polishedSample",
                kind: .regression,
                reason: "Golden has polished text but current run produced none.",
                golden: golden.output.polishedSample.map { String($0.prefix(200)) },
                current: nil
            ))
        }

        if let goldTLDR = golden.output.summaryTLDR,
           let curTLDR = current.output.summaryTLDR {
            let tldrVerdict = await judgeText(
                field: "summaryTLDR",
                golden: goldTLDR,
                current: curTLDR,
                role: .meetingSummary
            )
            findings.append(tldrVerdict)
        }

        // Aggregate: worst-case wins.
        let overall = worstVerdict(of: findings.map(\.kind))
        let elapsed = Date().timeIntervalSince(startTime)
        let summary = buildSummary(overall: overall, findings: findings)

        logger.notice("⚖️ Regression verdict for [\(scenarioID)]: \(overall.rawValue) (\(findings.count) field checks, \(String(format: "%.1f", elapsed))s)")

        return Verdict(
            overallKind: overall,
            summary: summary,
            fieldVerdicts: findings,
            judgeDurationSeconds: elapsed,
            judgedAt: Date()
        )
    }

    // MARK: - Tier 1: Deterministic Comparison

    private func deterministicComparisons(
        golden: TestResultPayload,
        current: TestResultPayload
    ) -> [FieldVerdict] {
        var findings: [FieldVerdict] = []

        func compareInt(_ field: String, _ goldVal: Int, _ curVal: Int) {
            if goldVal == curVal {
                findings.append(FieldVerdict(
                    field: field,
                    kind: .identical,
                    reason: "\(field) matches (\(goldVal))",
                    golden: String(goldVal),
                    current: String(curVal)
                ))
            } else {
                findings.append(FieldVerdict(
                    field: field,
                    kind: .regression,
                    reason: "\(field) changed from \(goldVal) to \(curVal)",
                    golden: String(goldVal),
                    current: String(curVal)
                ))
            }
        }

        func compareString(_ field: String, _ goldVal: String?, _ curVal: String?) {
            let g = goldVal ?? ""
            let c = curVal ?? ""
            if g == c {
                findings.append(FieldVerdict(
                    field: field,
                    kind: .identical,
                    reason: "\(field) matches",
                    golden: g.isEmpty ? nil : String(g.prefix(200)),
                    current: c.isEmpty ? nil : String(c.prefix(200))
                ))
            } else {
                findings.append(FieldVerdict(
                    field: field,
                    kind: .regression,
                    reason: "\(field) text differs (deterministic field)",
                    golden: g.isEmpty ? nil : String(g.prefix(200)),
                    current: c.isEmpty ? nil : String(c.prefix(200))
                ))
            }
        }

        compareInt("segmentCount", golden.output.segmentCount, current.output.segmentCount)
        compareInt("speakerCount", golden.output.speakerCount, current.output.speakerCount)
        compareInt("summaryActionItems", golden.output.summaryActionItems, current.output.summaryActionItems)
        compareInt("summaryDecisions", golden.output.summaryDecisions, current.output.summaryDecisions)
        compareInt("summaryFollowUps", golden.output.summaryFollowUps, current.output.summaryFollowUps)
        compareInt("summaryTopics", golden.output.summaryTopics, current.output.summaryTopics)
        compareInt("summaryLifeEvents", golden.output.summaryLifeEvents, current.output.summaryLifeEvents)
        compareInt("summaryComplianceFlags", golden.output.summaryComplianceFlags, current.output.summaryComplianceFlags)
        compareString("detectedLanguage", golden.output.detectedLanguage, current.output.detectedLanguage)
        compareString("transcriptSample", golden.output.transcriptSample, current.output.transcriptSample)

        return findings
    }

    // MARK: - Tier 2: LLM Judge

    private enum JudgedTextRole {
        case polishedTranscript
        case meetingSummary
    }

    private func judgeText(
        field: String,
        golden: String,
        current: String,
        role: JudgedTextRole
    ) async -> FieldVerdict {
        // Trivially identical — skip the LLM call.
        if golden == current {
            return FieldVerdict(
                field: field,
                kind: .identical,
                reason: "Byte-identical to golden",
                golden: String(golden.prefix(200)),
                current: String(current.prefix(200))
            )
        }

        let systemInstruction = Self.judgeSystemInstruction(role: role)
        let prompt = Self.judgePrompt(golden: golden, current: current, role: role)

        do {
            let response = try await AIService.shared.generate(
                prompt: prompt,
                systemInstruction: systemInstruction,
                maxTokens: 600
            )

            // Extract JSON, parse verdict
            let cleaned = JSONExtraction.extractJSON(from: response)
            guard let data = cleaned.data(using: .utf8) else {
                return FieldVerdict(
                    field: field,
                    kind: .needsReview,
                    reason: "Judge response wasn't UTF-8 decodable",
                    golden: String(golden.prefix(200)),
                    current: String(current.prefix(200))
                )
            }

            struct JudgeResponse: Decodable {
                let verdict: String
                let reason: String
            }

            let parsed = try JSONDecoder().decode(JudgeResponse.self, from: data)
            let kind = VerdictKind(rawValue: parsed.verdict.uppercased()) ?? .needsReview
            return FieldVerdict(
                field: field,
                kind: kind,
                reason: parsed.reason,
                golden: String(golden.prefix(200)),
                current: String(current.prefix(200))
            )
        } catch {
            logger.warning("Judge LLM call failed for [\(field)]: \(error.localizedDescription)")
            return FieldVerdict(
                field: field,
                kind: .needsReview,
                reason: "Judge call failed: \(error.localizedDescription)",
                golden: String(golden.prefix(200)),
                current: String(current.prefix(200))
            )
        }
    }

    // MARK: - Aggregation

    private func worstVerdict(of kinds: [VerdictKind]) -> VerdictKind {
        // Order from worst to best
        if kinds.contains(.regression) { return .regression }
        if kinds.contains(.needsReview) { return .needsReview }
        if kinds.contains(.improvement) { return .improvement }
        if kinds.contains(.cosmeticDrift) { return .cosmeticDrift }
        return .identical
    }

    private func buildSummary(overall: VerdictKind, findings: [FieldVerdict]) -> String {
        let regressions = findings.filter { $0.kind == .regression }
        let needsReview = findings.filter { $0.kind == .needsReview }

        switch overall {
        case .identical:
            return "All \(findings.count) field checks identical to golden."
        case .cosmeticDrift:
            let drifted = findings.filter { $0.kind == .cosmeticDrift }.map(\.field).joined(separator: ", ")
            return "Cosmetic drift in: \(drifted). No information loss."
        case .improvement:
            return "Current output judged better than golden. Consider re-recording the baseline."
        case .regression:
            let fields = regressions.map(\.field).joined(separator: ", ")
            return "Regression in: \(fields)."
        case .needsReview:
            let fields = needsReview.map(\.field).joined(separator: ", ")
            return "Manual review needed for: \(fields)."
        }
    }

    // MARK: - Judge Prompts

    private static func judgeSystemInstruction(role: JudgedTextRole) -> String {
        let roleClause: String
        switch role {
        case .polishedTranscript:
            roleClause = """
            You are comparing two POLISHED MEETING TRANSCRIPTS. The polish step \
            corrects ASR errors, fixes punctuation, and joins broken sentences \
            while preserving speaker labels and meaning. The golden was \
            human-validated. The current output came from a re-run.
            """
        case .meetingSummary:
            roleClause = """
            You are comparing two ONE-PARAGRAPH MEETING SUMMARIES (tl;dr). \
            The golden was human-validated. The current output came from a re-run.
            """
        }

        return """
        You judge whether a CURRENT pipeline output regressed compared to a \
        GOLDEN baseline. Your job is NOT to grade absolute quality — it is to \
        decide whether the current output preserves what was in the golden.

        \(roleClause)

        Classify the difference as exactly one of:

        - IDENTICAL: byte-for-byte the same, or differs only in trivial \
          whitespace.
        - COSMETIC_DRIFT: rephrasing, word order, punctuation differences, \
          but the same MEANING, the same NAMED ENTITIES, the same FACTS, \
          the same SPEAKER ATTRIBUTION. No information added, no information \
          lost.
        - IMPROVEMENT: current is genuinely BETTER than golden (clearer, \
          fixes a typo present in golden, adds correct missing context). \
          Use this sparingly — only when current is unambiguously superior.
        - REGRESSION: current LOST INFORMATION present in golden — dropped \
          a name, dropped an action item, mis-attributed a speaker, \
          fabricated content not in golden, broke punctuation that was correct \
          in golden, or otherwise made the output WORSE for downstream use.
        - NEEDS_REVIEW: you cannot decide with confidence which of the \
          above applies. Use only when neither output is obviously preferable.

        CRITICAL RULES:
        - The golden is the source of truth for what SHOULD be in the output.
        - When in doubt between COSMETIC_DRIFT and REGRESSION, prefer \
          COSMETIC_DRIFT — false alarms are worse than missed regressions \
          for prompt iteration speed.
        - Do not penalize the current output for being shorter unless it \
          dropped a specific named fact or entity from the golden.
        - Do not call something an IMPROVEMENT just because it's longer or \
          more detailed.

        Respond with ONLY a JSON object in this exact shape:

        {
          "verdict": "IDENTICAL" | "COSMETIC_DRIFT" | "IMPROVEMENT" | "REGRESSION" | "NEEDS_REVIEW",
          "reason": "<one or two sentences explaining the verdict, citing specific differences if any>"
        }

        Use only ASCII characters. No markdown fences, no prose outside the JSON.
        """
    }

    private static func judgePrompt(golden: String, current: String, role: JudgedTextRole) -> String {
        return """
        GOLDEN (baseline):
        \(golden)

        CURRENT (re-run):
        \(current)

        Classify the difference between CURRENT and GOLDEN. Return only the JSON object.
        """
    }
}

#endif
