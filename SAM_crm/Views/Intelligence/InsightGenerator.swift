//
//  InsightGenerator.swift
//  SAM_crm
//
//  Phase 2: Generates SamInsight rows from SamEvidenceItem signals.
//  Uses composite uniqueness (person + context + kind) to prevent duplicates
//  and aggregates related evidence into single insights.
//

import Foundation
@preconcurrency import SwiftData

/// Generates and persists SamInsight rows from evidence signals.
/// Call from a background task after evidence import completes.
actor InsightGenerator {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    private struct InsightGroupKey: Hashable {
        let personID: UUID?
        let contextID: UUID?
        let kind: InsightKind
    }

    private struct InsightDedupeKey: Hashable {
        let personID: UUID?
        let contextID: UUID?
        let kind: InsightKind
    }

    // MARK: - Public API

    /// Generate insights by grouping related evidence items.
    /// This creates one insight per (person, context, kind) tuple instead of
    /// one insight per evidence item.
    func generatePendingInsights() async {
        // Fetch all evidence with signals
        let fetch = FetchDescriptor<SamEvidenceItem>()
        let evidence: [SamEvidenceItem] = (try? context.fetch(fetch)) ?? []

        // Group evidence by (person, context, kind)
        struct Agg { var person: SamPerson?; var contextRef: SamContext?; var kind: InsightKind; var items: [SamEvidenceItem]; var maxConfidence: Double }
        var groups: [InsightGroupKey: Agg] = [:]

        for item in evidence where !item.signals.isEmpty {
            guard let best = item.signals.max(by: { $0.confidence < $1.confidence }) else { continue }
            let person = item.linkedPeople.first
            let contextRef = item.linkedContexts.first
            let kind = insightKind(for: best.kind)
            let key = InsightGroupKey(personID: person?.id, contextID: contextRef?.id, kind: kind)
            if groups[key] == nil {
                groups[key] = Agg(person: person, contextRef: contextRef, kind: kind, items: [], maxConfidence: best.confidence)
            }
            groups[key]!.items.append(item)
            if best.confidence > groups[key]!.maxConfidence { groups[key]!.maxConfidence = best.confidence }
        }

        // Upsert one insight per group
        for (_, agg) in groups {
            if let existing = await hasInsight(person: agg.person, context: agg.contextRef, kind: agg.kind) {
                // Merge evidence and bump confidence
                let existingIDs = Set(existing.basedOnEvidence.map { $0.id })
                let newItems = agg.items.filter { !existingIDs.contains($0.id) }
                if !newItems.isEmpty { existing.basedOnEvidence.append(contentsOf: newItems) }
                if agg.maxConfidence > existing.confidence { existing.confidence = agg.maxConfidence }
            } else {
                let message = defaultMessage(forKind: agg.kind, person: agg.person, context: agg.contextRef)
                let insight = SamInsight(
                    samPerson: agg.person,
                    samContext: agg.contextRef,
                    kind: agg.kind,
                    message: message,
                    confidence: agg.maxConfidence,
                    basedOnEvidence: agg.items
                )
                context.insert(insight)
            }
        }

        try? context.save()
    }

    /// Remove duplicate insights, keeping the one with the most evidence.
    /// Call this to clean up any duplicates that may have been created.
    func deduplicateInsights() async {
        let fetch = FetchDescriptor<SamInsight>(
            predicate: #Predicate<SamInsight> { $0.dismissedAt == nil }
        )
        guard let allInsights = try? context.fetch(fetch) else { return }

        var buckets: [InsightDedupeKey: [SamInsight]] = [:]
        for insight in allInsights {
            let key = InsightDedupeKey(personID: insight.samPerson?.id, contextID: insight.samContext?.id, kind: insight.kind)
            buckets[key, default: []].append(insight)
        }

        for (_, duplicates) in buckets where duplicates.count > 1 {
            let sorted = duplicates.sorted { a, b in
                if a.basedOnEvidence.count != b.basedOnEvidence.count { return a.basedOnEvidence.count > b.basedOnEvidence.count }
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                return a.createdAt > b.createdAt
            }
            let toKeep = sorted[0]
            let allEvidence = Set(duplicates.flatMap(\.basedOnEvidence))
            toKeep.basedOnEvidence = Array(allEvidence)
            for d in sorted.dropFirst() { context.delete(d) }
        }

        try? context.save()
    }

    /// Generate insight for a specific evidence item (legacy single-item API).
    /// Kept for compatibility; prefers generatePendingInsights() for batch processing.
    func generateInsights(for evidence: SamEvidenceItem) async {
        guard let best = evidence.signals.max(by: { $0.confidence < $1.confidence }) else { return }

        let person = evidence.linkedPeople.first
        let contextRef = evidence.linkedContexts.first
        let kind = insightKind(for: best.kind)

        // Check for existing insight
        if let existing = await hasInsight(person: person, context: contextRef, kind: kind) {
            // Update existing: add evidence if not already present, bump confidence if higher
            if !existing.basedOnEvidence.contains(where: { $0.id == evidence.id }) {
                existing.basedOnEvidence.append(evidence)
                if best.confidence > existing.confidence {
                    existing.confidence = best.confidence
                }
                try? context.save()
            }
        } else {
            // Create new
            let message = defaultMessage(for: best, person: person, context: contextRef)
            let insight = SamInsight(
                samPerson: person,
                samContext: contextRef,
                kind: kind,
                message: message,
                confidence: best.confidence,
                basedOnEvidence: [evidence]
            )
            context.insert(insight)
            try? context.save()
        }
    }

    // MARK: - Helpers

    /// Check if an insight already exists for this entity+kind combination.
    /// Prevents duplicates when same signal appears in multiple evidence items.
    private func hasInsight(
        person: SamPerson?,
        context samContext: SamContext?,
        kind: InsightKind
    ) async -> SamInsight? {
        // Fetch all non-dismissed insights of this kind and filter in memory
        // SwiftData predicates don't reliably handle optional UUID comparisons
        let fetch = FetchDescriptor<SamInsight>(
            predicate: #Predicate<SamInsight> { insight in
                insight.dismissedAt == nil && insight.kind == kind
            }
        )

        guard let allInsights = try? context.fetch(fetch) else { return nil }

        // Filter in memory for exact person+context match
        return allInsights.first { insight in
            insight.samPerson?.id == person?.id &&
            insight.samContext?.id == samContext?.id
        }
    }

    /// Map SignalKind → InsightKind using the same logic as AwarenessHost.bucketFor
    private func insightKind(for signalKind: SignalKind) -> InsightKind {
        switch signalKind {
        case .complianceRisk:
            return .complianceWarning
        case .divorce:
            return .relationshipAtRisk
        case .comingOfAge, .unlinkedEvidence:
            return .followUp
        case .partnerLeft, .productOpportunity:
            return .opportunity
        }
    }

    /// Generate a contextual message for this signal.
    /// Matches the quality of the old AwarenessHost bucketing system.
    private func defaultMessage(
        for signal: EvidenceSignal,
        person: SamPerson?,
        context: SamContext?
    ) -> String {
        // Build target suffix
        let targetSuffix: String
        if let ctx = context {
            targetSuffix = " (\(ctx.name))"
        } else if let p = person {
            targetSuffix = " (\(p.displayName))"
        } else {
            targetSuffix = ""
        }

        switch signal.kind {
        case .complianceRisk:
            return "Compliance review recommended\(targetSuffix)."
        case .divorce:
            return "Possible relationship change detected\(targetSuffix). Consider a check-in."
        case .comingOfAge:
            return "Coming of age event\(targetSuffix). Review dependent coverage."
        case .partnerLeft:
            return "Business change detected\(targetSuffix). Review buy-sell agreements."
        case .productOpportunity:
            return "Possible opportunity\(targetSuffix). Consider reviewing options."
        case .unlinkedEvidence:
            return "Suggested follow-up\(targetSuffix)."
        }
    }

    /// Generate a contextual message for an InsightKind.
    /// Used for aggregated groups where we only know the resulting insight kind.
    private func defaultMessage(
        forKind kind: InsightKind,
        person: SamPerson?,
        context: SamContext?
    ) -> String {
        let targetSuffix: String
        if let ctx = context {
            targetSuffix = " (\(ctx.name))"
        } else if let p = person {
            targetSuffix = " (\(p.displayName))"
        } else {
            targetSuffix = ""
        }

        switch kind {
        case .complianceWarning:
            return "Compliance review recommended\(targetSuffix)."
        case .relationshipAtRisk:
            return "Possible relationship change detected\(targetSuffix). Consider a check-in."
        case .followUp:
            return "Suggested follow-up\(targetSuffix)."
        case .opportunity:
            return "Possible opportunity\(targetSuffix). Consider reviewing options."
        case .consentMissing:
            return "Consent missing\(targetSuffix). Please review."
        @unknown default:
            return "Suggested other step\(targetSuffix)."
        }
    }
}

