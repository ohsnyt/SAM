//
//  AwarenessHost.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import Foundation

struct AwarenessHost: View {

    // mock-first evidence store
    private let evidenceStore = MockEvidenceRuntimeStore.shared

    @State private var whySheet: WhySheetItem? = nil

    var body: some View {
        AwarenessView(
            insights: awarenessInsights,
            onInsightTapped: { insight in
                let e = insight.evidenceIDs
                guard !e.isEmpty else { return }

                whySheet = WhySheetItem(
                    title: insight.message,
                    evidenceIDs: e
                )
            }
        )
        .sheet(item: $whySheet) { item in
            EvidenceDrillInSheet(title: item.title, evidenceIDs: item.evidenceIDs)
        }
    }

    // MARK: - Build insights from evidence

    private var awarenessInsights: [EvidenceBackedInsight] {
        // “Needs review” should be your triage list (not archived/done).
        let items = evidenceStore.needsReview

        // Group by the strongest signal “bucket” so we produce a few high-quality cards,
        // rather than dozens of tiny ones.
        var buckets: [SignalBucket: [EvidenceItem]] = [:]

        for item in items {
            // choose the highest-confidence signal in this item
            if let best = item.signals.max(by: { $0.confidence < $1.confidence }) {
                let bucket = bucketFor(signal: best)
                buckets[bucket, default: []].append(item)
            }
        }

        // Convert buckets to insights
        var out: [EvidenceBackedInsight] = []

        for (bucket, evidence) in buckets {
            // Sort evidence newest-first for “why”
            let sorted = evidence.sorted { $0.occurredAt > $1.occurredAt }

            // Compute confidence: max signal confidence across the supporting evidence
            let confidence = sorted
                .flatMap { $0.signals }
                .map(\.confidence)
                .max() ?? 0.65

            // Evidence count = interactionsCount
            let interactionsCount = sorted.count

            // Pick a label target (context/person) from links if available
            let target = bestTargetName(from: sorted)

            // Message text: short, actionable, trust-first
            let message = bucket.message(target: target)

            out.append(
                EvidenceBackedInsight(
                    kind: bucket.kind,
                    typeDisplayName: bucket.displayName,
                    message: message,
                    confidence: confidence,
                    interactionsCount: interactionsCount,
                    consentsCount: bucket.consentsCountHint,
                    evidenceIDs: sorted.map(\.id)
                )
            )
        }

        // Sort: priority then confidence
        out.sort {
            let pa = priority(for: $0.kind)
            let pb = priority(for: $1.kind)
            if pa != pb { return pa < pb }
            return $0.confidence > $1.confidence
        }

        return out
    }

    private func bestTargetName(from evidence: [EvidenceItem]) -> String? {
        // Prefer confirmed links (user action) over proposed links.
        let contextStore = MockContextRuntimeStore.shared
        let peopleStore  = MockPeopleRuntimeStore.shared

        // 1) Confirmed context/person links
        for item in evidence {
            if let ctxID = item.linkedContexts.first,
               let ctx = contextStore.byID[ctxID] {
                return ctx.name
            }
            if let personID = item.linkedPeople.first,
               let person = peopleStore.byID[personID] {
                return person.displayName
            }
        }

        // 2) Proposed links (system suggestions)
        for item in evidence {
            if let proposed = item.proposedLinks
                .sorted(by: { $0.confidence > $1.confidence })
                .first {
                return proposed.displayName
            }
        }

        return nil
    }

    private func priority(for kind: InsightKind) -> Int {
        switch kind {
        case .complianceWarning:   return 0
        case .consentMissing:      return 1
        case .relationshipAtRisk:  return 2
        case .followUp:            return 3
        case .opportunity:         return 4
        }
    }

    private func bucketFor(signal: EvidenceSignal) -> SignalBucket {
        switch signal.kind {
        case .complianceRisk:
            return .compliance
        case .divorce:
            return .relationshipRisk
        case .comingOfAge:
            return .followUp
        case .partnerLeft, .productOpportunity:
            return .opportunity
        case .unlinkedEvidence:
            return .followUp
        }
    }
}

// MARK: - Evidence-backed Insight Type

/// Concrete insight model that carries evidence IDs for drill-in.
/// If you already have a similar type, keep yours and delete this one.
struct EvidenceBackedInsight: InsightDisplayable, Hashable {
    var kind: InsightKind
    var typeDisplayName: String
    var message: String
    var confidence: Double
    var interactionsCount: Int
    var consentsCount: Int
    var evidenceIDs: [UUID]
}

// MARK: - Why sheet plumbing

private struct WhySheetItem: Identifiable {
    let id = UUID()
    let title: String
    let evidenceIDs: [UUID]
}

// MARK: - Buckets

private enum SignalBucket: Hashable {
    case compliance
    case relationshipRisk
    case followUp
    case opportunity

    var kind: InsightKind {
        switch self {
        case .compliance: return .complianceWarning
        case .relationshipRisk: return .relationshipAtRisk
        case .followUp: return .followUp
        case .opportunity: return .opportunity
        }
    }

    var displayName: String {
        switch self {
        case .compliance: return "Compliance"
        case .relationshipRisk: return "Relationship"
        case .followUp: return "Follow-Up"
        case .opportunity: return "Opportunity"
        }
    }

    var consentsCountHint: Int {
        // Placeholder: later we compute from ConsentRequirement data.
        switch self {
        case .compliance: return 1
        default: return 0
        }
    }

    func message(target: String?) -> String {
        let suffix = target.map { " (\($0))" } ?? ""
        switch self {
        case .compliance:
            return "Compliance review recommended\(suffix)."
        case .relationshipRisk:
            return "Possible relationship change detected\(suffix). Consider a check-in."
        case .followUp:
            return "Suggested follow-up\(suffix)."
        case .opportunity:
            return "Possible opportunity\(suffix). Consider reviewing options."
        }
    }
}
