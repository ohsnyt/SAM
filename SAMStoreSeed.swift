//
//  SAMStoreSeed.swift
//  SAM_crm
//
//  One-time seed: reads the current mock arrays and creates the
//  corresponding @Model objects in the SwiftData ModelContext.
//
//  Guarded by a UserDefaults flag (`sam.swiftdata.seeded`).  Once
//  that flag is set the seed never runs again — all subsequent
//  mutations go through the store layer directly.
//
//  Design constraints:
//    • Every person referenced by a Context participant list or an
//      Evidence proposedLink must exist as a SamPerson *before* those
//      references are wired.  We therefore seed in three passes:
//        1. Contexts  (no back-references yet)
//        2. People    (including context-only people like John & Emma)
//        3. Evidence  (proposedLinks look up person/context by name)
//    • Proposed-link targetIDs are re-derived from the freshly-inserted
//      objects rather than copied from the mock arrays, because the
//      mock UUIDs are generated at process start and have no meaning
//      to SwiftData.
//

import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Entry point
// ─────────────────────────────────────────────────────────────────────

enum SAMStoreSeed {

    /// The single flag that prevents re-seeding after the first run.
    private static let seededKey = "sam.swiftdata.seeded"

    /// Call this once at app launch (e.g. from the `App` body or a
    /// `.task` on the root view).  It is a no-op if the store has
    /// already been seeded.
    @MainActor
    static func seedIfNeeded(into context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }

        // ── Pass 1: Contexts ──────────────────────────────────────
        let contexts = seedContexts(into: context)

        // ── Pass 2: People (includes context-only people) ────────
        let people = seedPeople(into: context, contexts: contexts)

        // ── Pass 3: Evidence (resolves proposedLink targetIDs) ───
        seedEvidence(into: context, people: people, contexts: contexts)

        // ── Commit ────────────────────────────────────────────────
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            // If save fails the flag stays false — we'll retry next launch.
            // In production you'd want to surface this, but for now just log.
            NSLog("SAMStoreSeed: save failed — %@", error.localizedDescription)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Pass 1 — Contexts
// ─────────────────────────────────────────────────────────────────────
//
// We read from MockContextStore.all (which today is just the Smith
// household).  Each ContextDetailModel becomes a SamContext plus its
// embedded product cards, interaction chips, and insight cards.
//
// ConsentRequirements and ContextParticipations are deferred to
// Pass 2 / 3 because they need person references.
// ─────────────────────────────────────────────────────────────────────

extension SAMStoreSeed {

    /// Returns a name → SamContext lookup so later passes can wire
    /// relationships by name.
    private static func seedContexts(into context: ModelContext) -> [String: SamContext] {
        var map: [String: SamContext] = [:]

        for mock in MockContextStore.all {
            let sam = SamContext(
                id:                 mock.id,
                name:               mock.name,
                kind:               mock.kind,
                consentAlertCount:  mock.alerts.consentCount,
                reviewAlertCount:   mock.alerts.reviewCount,
                followUpAlertCount: mock.alerts.followUpCount
            )

            // ── Embedded product cards ──────────────────────────
            sam.productCards = mock.products

            // ── Embedded interaction chips ──────────────────────
            sam.recentInteractions = mock.recentInteractions.map {
                InteractionModel(id: $0.id, title: $0.title, subtitle: $0.subtitle, whenText: $0.whenText, icon: $0.icon)
            }

            // ── Embedded insight cards ──────────────────────────
            sam.insights = mock.insights.map {
                ContextInsight(
                    kind:              $0.kind,
                    message:           $0.message,
                    confidence:        $0.confidence,
                    interactionsCount: $0.interactionsCount,
                    consentsCount:     $0.consentsCount
                )
            }

            // ── Relational Products (one per product card) ─────
            for card in mock.products {
                let product = Product(
                    id:            card.id,
                    type:          inferProductType(from: card.title),
                    name:          card.title,
                    statusDisplay: card.statusDisplay,
                    icon:          card.icon,
                    subtitle:      card.subtitle,
                    context:       sam
                )
                context.insert(product)
            }

            context.insert(sam)
            map[mock.name] = sam
        }

        return map
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Pass 2 — People
// ─────────────────────────────────────────────────────────────────────
//
// Sources:
//   • MockPeopleStore.all        — the three people the app already knows
//   • Context participant lists  — may contain people not in MockPeopleStore
//     (e.g. John Smith, Emma Smith).  These get a minimal SamPerson so
//     that ContextParticipation can reference them.
//
// After all people are inserted we go back and wire:
//   • ContextParticipation rows  (person ↔ context)
//   • ConsentRequirement rows    (person ← context)
// ─────────────────────────────────────────────────────────────────────

extension SAMStoreSeed {

    /// Returns a displayName → SamPerson lookup.
    private static func seedPeople(
        into context: ModelContext,
        contexts: [String: SamContext]
    ) -> [String: SamPerson] {
        var map: [String: SamPerson] = [:]

        // ── 2a. People from MockPeopleStore ───────────────────────
        for mock in MockPeopleStore.all {
            let person = SamPerson(
                id:                 mock.id,
                displayName:        mock.displayName,
                roleBadges:         mock.roleBadges,
                email:              mock.email,
                consentAlertsCount: mock.consentAlertsCount,
                reviewAlertsCount:  mock.reviewAlertsCount
            )

            // Embedded collections
            person.contextChips        = mock.contexts
            person.responsibilityNotes = mock.responsibilityNotes
            person.recentInteractions  = mock.recentInteractions
            person.insights = mock.insights.map {
                PersonInsight(
                    kind:              $0.kind,
                    message:           $0.message,
                    confidence:        $0.confidence,
                    interactionsCount: $0.interactionsCount,
                    consentsCount:     $0.consentsCount
                )
            }

            context.insert(person)
            map[mock.displayName] = person
        }

        // ── 2b. Context-only people (not in MockPeopleStore) ────
        //   Walk every context's participant list; if a name isn't
        //   already in `map` create a minimal SamPerson for it.
        for mock in MockContextStore.all {
            for participant in mock.participants {
                guard map[participant.displayName] == nil else { continue }

                let person = SamPerson(
                    id:          participant.id,   // use the participant's own UUID
                    displayName: participant.displayName,
                    roleBadges:  participant.roleBadges
                )
                context.insert(person)
                map[participant.displayName] = person
            }
        }

        // ── 2c. Wire ContextParticipation rows ──────────────────
        for mock in MockContextStore.all {
            guard let samContext = contexts[mock.name] else { continue }

            for participant in mock.participants {
                guard let samPerson = map[participant.displayName] else { continue }

                let participation = ContextParticipation(
                    id:         UUID(),
                    person:     samPerson,
                    context:    samContext,
                    roleBadges: participant.roleBadges,
                    isPrimary:  participant.isPrimary,
                    note:       participant.note
                )
                context.insert(participation)
            }
        }

        // ── 2d. Wire ConsentRequirement rows ────────────────────
        for mock in MockContextStore.all {
            guard let samContext = contexts[mock.name] else { continue }

            for req in mock.consentRequirements {
                // Best-effort person match: extract the first name
                // before the first parenthesis in the title
                // (e.g. "Mary Smith (Spouse) must consent" → "Mary Smith").
                let personName = extractPersonName(from: req.title)
                let person     = personName.flatMap { map[$0] }

                let consent = ConsentRequirement(
                    id:          req.id,
                    title:       req.title,
                    reason:      req.reason,
                    status:      ConsentStatus(rawValue: req.status.rawValue) ?? .required,
                    jurisdiction: req.jurisdiction,
                    person:      person,
                    context:     samContext
                )
                context.insert(consent)
            }
        }

        return map
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Pass 3 — Evidence
// ─────────────────────────────────────────────────────────────────────
//
// Reads from the current MockEvidenceRuntimeStore.  The tricky part
// is proposedLinks: their `targetID` fields were generated against
// the mock stores' in-memory UUIDs.  We re-derive them by looking
// up the target's `displayName` in the people/context maps we built
// in passes 1 & 2.
// ─────────────────────────────────────────────────────────────────────

extension SAMStoreSeed {

    private static func seedEvidence(
        into context: ModelContext,
        people:   [String: SamPerson],
        contexts: [String: SamContext]
    ) {
        let store = MockEvidenceRuntimeStore.shared

        for mock in store.items {
            // Re-map proposedLinks so targetIDs point at the real
            // SwiftData objects' UUIDs rather than the ephemeral mock UUIDs.
            let remapped = mock.proposedLinks.map { link -> ProposedLink in
                let resolvedID: UUID
                switch link.target {
                case .person:
                    resolvedID = people[link.displayName]?.id ?? link.targetID
                case .context:
                    resolvedID = contexts[link.displayName]?.id ?? link.targetID
                }
                return ProposedLink(
                    id:            link.id,
                    target:        link.target,
                    targetID:      resolvedID,
                    displayName:   link.displayName,
                    secondaryLine: link.secondaryLine,
                    confidence:    link.confidence,
                    reason:        link.reason,
                    status:        link.status,
                    decidedAt:     link.decidedAt
                )
            }

            // Same treatment for linkedPeople / linkedContexts
            let remappedPeople = mock.linkedPeople.compactMap { oldID -> UUID? in
                // The mock store stores UUIDs directly; find the person
                // whose mock id matches and return the seeded id.
                // In practice these are the same object so this is a
                // no-op, but it's explicit for clarity.
                people.values.first(where: { $0.id == oldID })?.id
            }
            let remappedContexts = mock.linkedContexts.compactMap { oldID -> UUID? in
                contexts.values.first(where: { $0.id == oldID })?.id
            }

            let evidence = EvidenceItem(
                id:               mock.id,
                state:            mock.state,
                sourceUID:        mock.sourceUID,
                source:           mock.source,
                occurredAt:       mock.occurredAt,
                title:            mock.title,
                snippet:          mock.snippet,
                bodyText:         mock.bodyText,
                participantHints: mock.participantHints,
                signals:          mock.signals,
                proposedLinks:    remapped,
                linkedPeople:     remappedPeople,
                linkedContexts:   remappedContexts
            )
            context.insert(evidence)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────

extension SAMStoreSeed {

    /// Infer a ProductType from a human-readable product title.
    /// Falls back to `.lifeInsurance` when no keyword matches.
    private static func inferProductType(from title: String) -> ProductType {
        let lower = title.lowercased()
        if lower.contains("life")            { return .lifeInsurance }
        if lower.contains("disability")      { return .disability }
        if lower.contains("buy-sell") ||
           lower.contains("buy sell")        { return .buySell }
        if lower.contains("key person")      { return .keyPerson }
        if lower.contains("retirement")      { return .retirement }
        if lower.contains("annuity")         { return .annuity }
        if lower.contains("long-term care") ||
           lower.contains("long term care")  { return .longTermCare }
        if lower.contains("college")         { return .collegeSavings }
        if lower.contains("trust")           { return .trusts }
        return .lifeInsurance   // safe default
    }

    /// Extract the person's display name from a consent-requirement
    /// title like "Mary Smith (Spouse) must consent".
    /// Returns nil if the pattern doesn't match.
    private static func extractPersonName(from title: String) -> String? {
        // Strategy: take everything before the first "(" and trim.
        guard let parenIdx = title.firstIndex(of: "(") else {
            // No parens — try "… must consent" pattern
            if let mustIdx = title.range(of: " must ") {
                let candidate = String(title[title.startIndex..<mustIdx.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate.isEmpty ? nil : candidate
            }
            return nil
        }
        let candidate = String(title[title.startIndex..<parenIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }
}
