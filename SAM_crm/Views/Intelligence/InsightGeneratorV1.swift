//
//  InsightGeneratorV1.swift
//  SAM_crm
//
//  Created by David Snyder on 2/3/26.
//

import Foundation
/// v1: deterministic, explainable signal generation.
/// Produces EvidenceSignal entries that AwarenessHost already knows how to display.
enum InsightGeneratorV1 {

    static func signals(for evidence: EvidenceItem, now: Date = .now) -> [EvidenceSignal] {
        var out: [EvidenceSignal] = []

        // Build analysis text (very conservative / explainable)
        let text = normalizedText(evidence.title, evidence.snippet, evidence.bodyText)

        // A) Unlinked calendar evidence -> Follow-up nudge
        if evidence.source == .calendar,
           evidence.linkedPeople.isEmpty,
           evidence.linkedContexts.isEmpty {
            out.append(EvidenceSignal(
                id: UUID(),
                kind: .unlinkedEvidence,
                confidence: unlinkedConfidence(for: evidence, now: now),
                reason: "Calendar event isn’t linked to a person or context yet."
            ))
        }

        // B) Keyword triggers
        // Divorce / separation
        let divorceHits = countHits(text, [
            "divorce", "separation", "separated", "custody", "alimony", "dissolution"
        ])
        if divorceHits > 0 {
            out.append(EvidenceSignal(
                id: UUID(),
                kind: .divorce,
                confidence: keywordConfidence(hits: divorceHits, date: evidence.occurredAt, now: now),
                reason: "Matched \(divorceHits) divorce/separation keyword(s) in title/notes."
            ))
        }

        // Coming of age
        let ageHits = countHits(text, [
            "turning 18", "18th birthday", "age 18", "adult child", "coming of age"
        ])
        if ageHits > 0 {
            out.append(EvidenceSignal(
                id: UUID(),
                kind: .comingOfAge,
                confidence: keywordConfidence(hits: ageHits, date: evidence.occurredAt, now: now),
                reason: "Matched \(ageHits) coming-of-age keyword(s) in title/notes."
            ))
        }

        // Partner left (business/recruiting)
        let partnerLeftHits = countHits(text, [
            "partner left", "left the firm", "resigned", "departure", "split", "buyout"
        ])
        if partnerLeftHits > 0 {
            out.append(EvidenceSignal(
                id: UUID(),
                kind: .partnerLeft,
                confidence: keywordConfidence(hits: partnerLeftHits, date: evidence.occurredAt, now: now),
                reason: "Matched \(partnerLeftHits) partner/departure keyword(s) in title/notes."
            ))
        }

        // Product opportunity
        // (includes your new product types by name)
        let oppHits = countHits(text, [
            "annuity", "long term care", "long-term care", "ltc",
            "college savings", "529", "trust", "trusts"
        ])
        if oppHits > 0 {
            out.append(EvidenceSignal(
                id: UUID(),
                kind: .productOpportunity,
                confidence: keywordConfidence(hits: oppHits, date: evidence.occurredAt, now: now),
                reason: "Matched \(oppHits) product keyword(s) (annuity/LTC/college/trust) in title/notes."
            ))
        }

        // Compliance risk
        let complianceHits = countHits(text, [
            "beneficiary", "survivorship", "consent", "signature", "sign", "underwriting",
            "policy change", "replacement", "illustration"
        ])
        if complianceHits > 0 {
            out.append(EvidenceSignal(
                id: UUID(),
                kind: .complianceRisk,
                confidence: keywordConfidence(hits: complianceHits, date: evidence.occurredAt, now: now, bumpIfSoon: true),
                reason: "Matched \(complianceHits) compliance keyword(s) in title/notes."
            ))
        }

        // De-duplicate by kind (keep max confidence)
        return collapseByKind(out)
    }

    // MARK: - Helpers

    private static func normalizedText(_ parts: String?...) -> String {
        parts
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func countHits(_ text: String, _ needles: [String]) -> Int {
        needles.reduce(0) { acc, n in
            acc + (text.contains(n) ? 1 : 0)
        }
    }

    private static func unlinkedConfidence(for e: EvidenceItem, now: Date) -> Double {
        // Unlinked is “real” but not urgent by itself.
        // Slight bump if the event is upcoming or just happened.
        let deltaDays = abs(Calendar.current.dateComponents([.day], from: e.occurredAt, to: now).day ?? 0)
        switch deltaDays {
        case 0...2: return 0.75
        case 3...7: return 0.65
        default:    return 0.55
        }
    }

    private static func keywordConfidence(hits: Int, date: Date, now: Date, bumpIfSoon: Bool = false) -> Double {
        var c: Double
        switch hits {
        case 1: c = 0.55
        case 2: c = 0.70
        default: c = 0.82
        }

        // If evidence is time-adjacent, increase urgency/credibility slightly.
        let deltaDays = abs(Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
        if deltaDays <= 7 { c += 0.05 }

        // For compliance terms, upcoming events are more time-sensitive.
        if bumpIfSoon {
            let isUpcoming = date > now && (Calendar.current.dateComponents([.day], from: now, to: date).day ?? 999) <= 7
            if isUpcoming { c += 0.05 }
        }

        return min(0.90, c)
    }

    private static func collapseByKind(_ signals: [EvidenceSignal]) -> [EvidenceSignal] {
        var best: [EvidenceSignalKind: EvidenceSignal] = [:]
        for s in signals {
            if let existing = best[s.kind] {
                if s.confidence > existing.confidence { best[s.kind] = s }
            } else {
                best[s.kind] = s
            }
        }
        return Array(best.values)
    }
}

