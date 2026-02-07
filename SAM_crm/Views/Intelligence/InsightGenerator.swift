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
        print("🧠 [InsightGenerator] generatePendingInsights() called")
        // Fetch all evidence with signals
        let fetch = FetchDescriptor<SamEvidenceItem>()
        let evidence: [SamEvidenceItem] = (try? context.fetch(fetch)) ?? []
        print("🧠 [InsightGenerator] Found \(evidence.count) total evidence items")
        
        let evidenceWithSignals = evidence.filter { !$0.signals.isEmpty }
        print("🧠 [InsightGenerator] \(evidenceWithSignals.count) evidence items have signals")
        
        // Debug: Show evidence sources
        let sources = evidence.map { $0.source }
        let sourceCount = Dictionary(grouping: sources) { $0 }.mapValues { $0.count }
        print("🧠 [InsightGenerator] Evidence by source: \(sourceCount)")

        // Group evidence by (person, context, kind)
        struct Agg { var person: SamPerson?; var contextRef: SamContext?; var kind: InsightKind; var items: [SamEvidenceItem]; var maxConfidence: Double }
        var groups: [InsightGroupKey: Agg] = [:]

        for item in evidence where !item.signals.isEmpty {
            let person = item.linkedPeople.first
            let contextRef = item.linkedContexts.first
            
            // Process ALL signals, not just the best one
            for signal in item.signals {
                let kind = insightKind(for: signal.kind)
                let key = InsightGroupKey(personID: person?.id, contextID: contextRef?.id, kind: kind)
                if groups[key] == nil {
                    groups[key] = Agg(person: person, contextRef: contextRef, kind: kind, items: [], maxConfidence: signal.confidence)
                }
                // Only add item once per group (avoid duplicates)
                if !groups[key]!.items.contains(where: { $0.id == item.id }) {
                    groups[key]!.items.append(item)
                }
                if signal.confidence > groups[key]!.maxConfidence { 
                    groups[key]!.maxConfidence = signal.confidence 
                }
            }
        }
        
        print("🧠 [InsightGenerator] Grouped into \(groups.count) insight candidates")

        // Upsert one insight per group
        var created = 0
        var updated = 0
        for (_, agg) in groups {
            if let existing = await hasInsight(person: agg.person, context: agg.contextRef, kind: agg.kind) {
                // Merge evidence and bump confidence
                let existingIDs = Set(existing.basedOnEvidence.map { $0.id })
                let newItems = agg.items.filter { !existingIDs.contains($0.id) }
                if !newItems.isEmpty { 
                    existing.basedOnEvidence.append(contentsOf: newItems)
                    updated += 1
                }
                if agg.maxConfidence > existing.confidence { existing.confidence = agg.maxConfidence }
            } else {
                // Generate a contextual message that includes note details if available
                let message = await generateMessage(forKind: agg.kind, person: agg.person, context: agg.contextRef, evidence: agg.items)
                let insight = SamInsight(
                    samPerson: agg.person,
                    samContext: agg.contextRef,
                    kind: agg.kind,
                    message: message,
                    confidence: agg.maxConfidence,
                    basedOnEvidence: agg.items
                )
                context.insert(insight)
                created += 1
                print("✅ [InsightGenerator] Created insight: \(agg.kind) for person: \(agg.person?.displayName ?? "nil"), context: \(agg.contextRef?.name ?? "nil")")
            }
        }
        
        print("🧠 [InsightGenerator] Created \(created) new insights, updated \(updated) existing")

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
    private func generateMessage(
        forKind kind: InsightKind,
        person: SamPerson?,
        context samContext: SamContext?,
        evidence: [SamEvidenceItem]
    ) async -> String {
        let targetSuffix: String
        if let ctx = samContext {
            targetSuffix = " (\(ctx.name))"
        } else if let p = person {
            targetSuffix = " (\(p.displayName))"
        } else {
            targetSuffix = ""
        }
        
        // Check if any evidence is a note with analysis artifacts
        for item in evidence where item.source == .note {
            print("🔍 [InsightGenerator] Found note evidence item, checking for analysis...")
            // Fetch the analysis artifact for this note
            if let noteID = item.sourceUID,
               let noteUUID = UUID(uuidString: noteID) {
                let artifactFetch = FetchDescriptor<SamAnalysisArtifact>(
                    predicate: #Predicate { $0.note?.id == noteUUID }
                )
                if let artifact = try? self.context.fetch(artifactFetch).first {
                    print("🔍 [InsightGenerator] Found analysis artifact")
                    // Include topics in the message
                    let topicStr = artifact.note.flatMap { note in
                        // Try to extract topics from the note text
                        let text = note.text.lowercased()
                        var topics: [String] = []
                        if text.contains("life insurance") { topics.append("life insurance") }
                        if text.contains("retirement") { topics.append("retirement") }
                        if text.contains("annuity") { topics.append("annuity") }
                        if text.contains("401k") || text.contains("ira") { topics.append("retirement savings") }
                        print("🔍 [InsightGenerator] Extracted topics from note: \(topics)")
                        return topics.isEmpty ? nil : topics.joined(separator: ", ")
                    }
                    
                    if let topics = topicStr, !topics.isEmpty {
                        print("✅ [InsightGenerator] Using topics in message: \(topics)")
                        switch kind {
                        case .opportunity:
                            return "Possible opportunity regarding \(topics)\(targetSuffix). Consider reviewing options."
                        case .followUp:
                            return "Suggested follow-up regarding \(topics)\(targetSuffix)."
                        default:
                            break
                        }
                    } else {
                        print("⚠️ [InsightGenerator] No topics found in note text")
                    }
                } else {
                    print("⚠️ [InsightGenerator] No analysis artifact found for note")
                }
            }
        }

        // Fallback to generic message
        print("🔍 [InsightGenerator] Using generic message for \(kind)")
        return defaultMessage(forKind: kind, person: person, context: samContext)
    }
    
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

