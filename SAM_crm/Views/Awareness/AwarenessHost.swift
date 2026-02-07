//
//  AwarenessHost.swift
//  SAM_crm
//
//  Created by David Snyder on 1/31/26.
//

import SwiftUI
import Foundation
import SwiftData
import EventKit
import Contacts

struct AwarenessHost: View {

    // SwiftData-backed evidence repository
    private let evidenceStore = EvidenceRepository.shared
    @Environment(\.modelContext) private var modelContext

    @State private var whySheet: WhySheetItem? = nil
    @State private var cachedContextNames: [UUID: String] = [:]
    @State private var cachedPersonNames:  [UUID: String] = [:]
    @State private var lastEvidenceSignature: Int? = nil

    @AppStorage("sam.awareness.usePersistedInsights") private var usePersistedInsights: Bool = true

    @Query(filter: #Predicate<SamInsight> { $0.dismissedAt == nil })
    private var persistedInsights: [SamInsight]

    @Query private var allPeople: [SamPerson]

    var body: some View {
        Group {
            if usePersistedInsights {
                AwarenessView(
                    insights: sortedPersisted,
                    onInsightTapped: { insight in
                        if let person = insight.samPerson {
                            NotificationCenter.default.post(name: .samNavigateToPerson, object: person.id)
                        } else if let context = insight.samContext {
                            NotificationCenter.default.post(name: .samNavigateToContext, object: context.id)
                        } else {
                            // Phase 3: basedOnEvidence is now a relationship
                            let e = insight.basedOnEvidence.map(\.id)
                            guard !e.isEmpty else { return }
                            whySheet = WhySheetItem(
                                title: insight.message,
                                evidenceIDs: e
                            )
                        }
                    }
                )
                .environment(\._awarenessDismissAction, { insight in
                    dismiss(insight)
                })
            } else {
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
            }
        }
        .addNoteToolbar(people: notePeopleItems, container: SAMModelContainer.shared)
        .sheet(item: $whySheet) { item in
            EvidenceDrillInSheet(title: item.title, evidenceIDs: item.evidenceIDs)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cachedContextNames.removeAll()
            cachedPersonNames.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            cachedContextNames.removeAll()
            cachedPersonNames.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            cachedContextNames.removeAll()
            cachedPersonNames.removeAll()
        }
    }

    private var notePeopleItems: [AddNoteForPeopleView.PersonItem] {
        allPeople.map { AddNoteForPeopleView.PersonItem(id: $0.id, displayName: $0.displayName) }
    }

    private func dismiss(_ insight: SamInsight) {
        insight.dismissedAt = Date()
        try? modelContext.save()
    }

    private var sortedPersisted: [SamInsight] {
        persistedInsights.sorted { a, b in
            let pa = priority(for: a.kind)
            let pb = priority(for: b.kind)
            if pa != pb { return pa < pb }
            return a.confidence > b.confidence
        }
    }

    // MARK: - Build insights from evidence

    private var awarenessInsights: [EvidenceBackedInsight] {
        // “Needs review” should be your triage list (not archived/done).
        let items = (try? evidenceStore.needsReview()) ?? []

        // Compute a simple signature of the evidence set (order-independent)
        let currentSignature: Int = {
            var hasher = Hasher()
            let ids = items.map(\.id).sorted(by: { $0.uuidString < $1.uuidString })
            for id in ids { hasher.combine(id) }
            return hasher.finalize()
        }()

        if lastEvidenceSignature != currentSignature {
            cachedContextNames.removeAll()
            cachedPersonNames.removeAll()
            lastEvidenceSignature = currentSignature
        }

        // Group by the strongest signal “bucket” so we produce a few high-quality cards,
        // rather than dozens of tiny ones.
        var buckets: [SignalBucket: [SamEvidenceItem]] = [:]

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

    private func bestTargetName(from evidence: [SamEvidenceItem]) -> String? {
        // Prefer confirmed links (user action) over proposed links.

        // Collect unique IDs from the evidence set
        var contextIDs = Set<UUID>()
        var personIDs  = Set<UUID>()
        for item in evidence {
            if let ctxID = item.linkedContexts.first?.id { contextIDs.insert(ctxID) }
            if let personID = item.linkedPeople.first?.id { personIDs.insert(personID) }
        }

        // Remove IDs we already have cached
        contextIDs.subtract(cachedContextNames.keys)
        personIDs.subtract(cachedPersonNames.keys)

        // Build lookup maps with batched fetches
        var contextByID: [UUID: SamContext] = [:]
        if !contextIDs.isEmpty {
            let fetch = FetchDescriptor<SamContext>(predicate: #Predicate { contextIDs.contains($0.id) })
            if let contexts = try? modelContext.fetch(fetch) {
                for c in contexts { contextByID[c.id] = c }
            }
            for (id, ctx) in contextByID { cachedContextNames[id] = ctx.name }
        }

        var personByID: [UUID: SamPerson] = [:]
        if !personIDs.isEmpty {
            let fetch = FetchDescriptor<SamPerson>(predicate: #Predicate { personIDs.contains($0.id) })
            if let people = try? modelContext.fetch(fetch) {
                for p in people { personByID[p.id] = p }
            }
            for (id, person) in personByID { cachedPersonNames[id] = person.displayName }
        }

        // 1) Confirmed context/person links
        for item in evidence {
            if let ctxID = item.linkedContexts.first?.id, let name = cachedContextNames[ctxID] {
                return name
            }
            if let personID = item.linkedPeople.first?.id, let name = cachedPersonNames[personID] {
                return name
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

extension Notification.Name {
    static let samNavigateToPerson  = Notification.Name("samNavigateToPerson")
    static let samNavigateToContext = Notification.Name("samNavigateToContext")
}
private struct AwarenessDismissActionKey: EnvironmentKey {
    static let defaultValue: ((SamInsight) -> Void)? = nil
}

extension EnvironmentValues {
    var _awarenessDismissAction: ((SamInsight) -> Void)? {
        get { self[AwarenessDismissActionKey.self] }
        set { self[AwarenessDismissActionKey.self] = newValue }
    }
}

