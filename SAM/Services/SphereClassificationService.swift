//
//  SphereClassificationService.swift
//  SAM
//
//  Phase C2 of the multi-sphere classification work (May 2026).
//
//  Given an evidence item and the person it relates to, picks the most
//  likely Sphere the interaction belongs to and returns a confidence
//  score. Used by ingestion to auto-apply high-confidence picks, by the
//  EOD review batch to surface mid-confidence picks, and by the lens
//  picker to back-fill historical evidence.
//
//  Pipeline:
//    1. Trivial-case short-circuits:
//       • Person has 0 active memberships → return nil (no decision).
//       • Person has exactly 1 sphere     → return that sphere at 1.0
//         (cold-start cap does not apply — there's nothing else to
//         compare against, so accepting at 1.0 keeps health math right).
//    2. LLM call with focused context: evidence title/snippet/source/
//       direction + each candidate sphere's name, purpose, and
//       classification profile. Returns sphereID + confidence + reason.
//    3. Cold-start cap: confidence is clamped to ≤0.6 until each
//       candidate sphere has at least 3 already-classified examples in
//       the store. This prevents the very first auto-applies from
//       cascading the classifier into a wrong rut.
//
//  Caller responsibility (see SphereClassificationCoordinator in C3):
//    • confidence >= 0.75  → auto-apply: set evidence.contextSphere.
//    • confidence 0.5–0.75 → queue for the EOD review batch (UI in C4).
//    • confidence <  0.5   → leave nil; the lens fallback uses the
//                            person's default sphere automatically.
//

import Foundation
import os.log

// MARK: - Result DTO

public struct SphereClassificationResult: Sendable {
    public let sphereID: UUID?
    public let confidence: Double
    public let reason: String?
    public let wasColdStartCapped: Bool

    public init(sphereID: UUID?, confidence: Double, reason: String?, wasColdStartCapped: Bool) {
        self.sphereID = sphereID
        self.confidence = confidence
        self.reason = reason
        self.wasColdStartCapped = wasColdStartCapped
    }

    /// Sentinel for "no decision possible" — person has no spheres, or
    /// the model declined to choose.
    public static let undecided = SphereClassificationResult(
        sphereID: nil, confidence: 0.0, reason: nil, wasColdStartCapped: false
    )

    /// True if this result should auto-apply during ingestion.
    public var shouldAutoApply: Bool { sphereID != nil && confidence >= 0.75 }

    /// True if this result should be surfaced in the EOD review batch
    /// for explicit user confirmation.
    public var shouldQueueForReview: Bool { sphereID != nil && confidence >= 0.5 && confidence < 0.75 }
}

// MARK: - Input snapshots
//
// Plain-value snapshots so callers can resolve SwiftData on the main
// actor and hand a Sendable bundle to this background actor.

public struct SphereClassificationEvidenceSnapshot: Sendable {
    public let id: UUID
    public let title: String
    public let snippet: String
    public let bodyExcerpt: String?
    public let sourceLabel: String
    public let directionLabel: String?
    public let occurredAt: Date

    public init(
        id: UUID,
        title: String,
        snippet: String,
        bodyExcerpt: String?,
        sourceLabel: String,
        directionLabel: String?,
        occurredAt: Date
    ) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.bodyExcerpt = bodyExcerpt
        self.sourceLabel = sourceLabel
        self.directionLabel = directionLabel
        self.occurredAt = occurredAt
    }
}

public struct SphereClassificationCandidate: Sendable {
    public let sphereID: UUID
    public let name: String
    public let purpose: String
    public let classificationProfile: String
    /// User-editable keyword hints surfaced alongside the profile.
    public let keywordHints: [String]
    /// User-confirmed example snippets in this sphere's pool. Drives the
    /// cold-start cap and is appended to the classifier prompt.
    public let confirmedExamples: [String]

    public init(
        sphereID: UUID,
        name: String,
        purpose: String,
        classificationProfile: String,
        keywordHints: [String] = [],
        confirmedExamples: [String] = []
    ) {
        self.sphereID = sphereID
        self.name = name
        self.purpose = purpose
        self.classificationProfile = classificationProfile
        self.keywordHints = keywordHints
        self.confirmedExamples = confirmedExamples
    }

    /// Count used by the cold-start cap.
    public var confirmedExampleCount: Int { confirmedExamples.count }
}

public struct SphereClassificationInput: Sendable {
    public let evidence: SphereClassificationEvidenceSnapshot
    public let personDisplayName: String
    public let personRoleBadges: [String]
    public let candidates: [SphereClassificationCandidate]

    public init(
        evidence: SphereClassificationEvidenceSnapshot,
        personDisplayName: String,
        personRoleBadges: [String],
        candidates: [SphereClassificationCandidate]
    ) {
        self.evidence = evidence
        self.personDisplayName = personDisplayName
        self.personRoleBadges = personRoleBadges
        self.candidates = candidates
    }
}

// MARK: - LLM response DTO

private struct LLMSphereChoice: Codable, Sendable {
    let chosen_index: Int?
    let confidence: Double?
    let reason: String?
}

// MARK: - Service

public actor SphereClassificationService {

    public static let shared = SphereClassificationService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SphereClassificationService")

    /// Cold-start threshold: a sphere needs at least this many confirmed
    /// examples before classifier confidence is allowed to exceed
    /// `coldStartCap`. Tuned empirically: 3 is enough for the classifier
    /// to have a real prior; below that, any "high confidence" is mostly
    /// the model anchoring on the sphere's name.
    public let coldStartExamplesNeeded: Int = 3

    /// Confidence ceiling applied when any candidate sphere is in
    /// cold-start. Sits below the 0.75 auto-apply gate so nothing
    /// auto-classifies until the user has hand-confirmed a few examples.
    public let coldStartCap: Double = 0.6

    private init() {}

    /// Classify an evidence item against the candidate spheres.
    /// - Returns: A decision with sphereID + confidence, or
    ///   `.undecided` if no candidates were supplied or the model
    ///   declined.
    public func classify(_ input: SphereClassificationInput) async -> SphereClassificationResult {
        // Trivial: no spheres → nothing to decide.
        guard !input.candidates.isEmpty else {
            return .undecided
        }

        // Trivial: one sphere → that's the answer, full confidence.
        // Cold-start cap doesn't apply: there's no alternative to confuse.
        if input.candidates.count == 1 {
            return SphereClassificationResult(
                sphereID: input.candidates[0].sphereID,
                confidence: 1.0,
                reason: "Only one sphere — fallback default.",
                wasColdStartCapped: false
            )
        }

        // Guard: AI must be available.
        guard case .available = await AIService.shared.checkAvailability() else {
            logger.debug("Sphere classifier skipped — AI unavailable")
            return .undecided
        }

        // Build prompt + system instruction.
        let candidateBlock = input.candidates.enumerated().map { idx, c in
            var lines: [String] = ["\(idx). \(c.name)"]
            if !c.purpose.isEmpty {
                lines.append("   Purpose: \(c.purpose)")
            }
            if !c.classificationProfile.isEmpty {
                lines.append("   Belongs here when: \(c.classificationProfile)")
            }
            if !c.keywordHints.isEmpty {
                lines.append("   Keyword hints: \(c.keywordHints.joined(separator: ", "))")
            }
            if !c.confirmedExamples.isEmpty {
                lines.append("   User-confirmed examples:")
                for ex in c.confirmedExamples.prefix(Sphere.maxExamples) {
                    // One line each, snippet trimmed so the prompt stays
                    // within the focused budget the service is built for.
                    let trimmed = String(ex.prefix(140))
                    lines.append("   - \(trimmed)")
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")

        var evidenceLines: [String] = [
            "Source: \(input.evidence.sourceLabel)",
            "Title: \(input.evidence.title)"
        ]
        if let dir = input.evidence.directionLabel { evidenceLines.append("Direction: \(dir)") }
        if !input.evidence.snippet.isEmpty {
            evidenceLines.append("Snippet: \(input.evidence.snippet)")
        }
        if let body = input.evidence.bodyExcerpt, !body.isEmpty {
            evidenceLines.append("Body excerpt: \(body)")
        }
        let evidenceBlock = evidenceLines.joined(separator: "\n")

        let roleLine = input.personRoleBadges.isEmpty
            ? ""
            : " (\(input.personRoleBadges.joined(separator: ", ")))"

        let systemInstruction = """
            Classify which life-sphere this interaction belongs to.
            Respond ONLY with valid JSON, no markdown, no commentary.

            Person: \(input.personDisplayName)\(roleLine)

            Candidate spheres (pick by index):
            \(candidateBlock)

            Rules:
            - Pick the single best match.
            - If the evidence is genuinely ambiguous between two spheres, return chosen_index=-1.
            - Confidence is your honest probability that this is the right sphere — calibrate, do not inflate.

            {"chosen_index": <integer or -1>, "confidence": <0.0-1.0>, "reason": "<one short sentence>"}
            """

        let prompt = "Classify this interaction:\n\n\(evidenceBlock)"

        let raw: String
        do {
            raw = try await AIService.shared.generate(
                prompt: prompt,
                systemInstruction: systemInstruction,
                maxTokens: 256,
                task: InferenceTask(label: "Sphere classification", icon: "circle.grid.3x3", source: "SphereClassificationService")
            )
        } catch {
            logger.warning("Classifier inference failed: \(error.localizedDescription)")
            return .undecided
        }

        return parse(raw, candidates: input.candidates)
    }

    // MARK: - Parsing & gating

    private func parse(_ raw: String, candidates: [SphereClassificationCandidate]) -> SphereClassificationResult {
        let cleaned = JSONExtraction.extractJSON(from: raw)
        guard let data = cleaned.data(using: .utf8),
              let choice = try? JSONDecoder().decode(LLMSphereChoice.self, from: data) else {
            logger.warning("Classifier returned unparseable response")
            return .undecided
        }

        guard let index = choice.chosen_index, index >= 0, index < candidates.count else {
            // -1 or out-of-range = model declined.
            return .undecided
        }

        let picked = candidates[index]
        let rawConfidence = max(0.0, min(1.0, choice.confidence ?? 0.0))

        // Cold-start cap applies whenever *any* candidate sphere is below
        // the example threshold. This avoids "trained on Work, classifies
        // everything as Work" before Church/Hobby have had a chance to
        // accumulate examples.
        let anyColdStart = candidates.contains { $0.confirmedExampleCount < coldStartExamplesNeeded }
        let capped: Double
        let wasCapped: Bool
        if anyColdStart && rawConfidence > coldStartCap {
            capped = coldStartCap
            wasCapped = true
        } else {
            capped = rawConfidence
            wasCapped = false
        }

        return SphereClassificationResult(
            sphereID: picked.sphereID,
            confidence: capped,
            reason: choice.reason,
            wasColdStartCapped: wasCapped
        )
    }
}
