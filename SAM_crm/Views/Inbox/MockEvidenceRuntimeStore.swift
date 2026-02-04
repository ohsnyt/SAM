//
//  MockEvidenceRuntimeStore.swift
//  SAM_crm
//
//  Mock-first Evidence Inbox store.
//  This is the substrate for “intelligence”: evidence → proposed links/signals → user confirmation.
//

import Foundation
import Observation

@MainActor
@Observable
final class MockEvidenceRuntimeStore {
    static let shared = MockEvidenceRuntimeStore()

    private(set) var items: [EvidenceItem] = []

    private let peopleStore = MockPeopleRuntimeStore.shared
    private let contextStore = MockContextRuntimeStore.shared

    init() {
        seedIfNeeded()
    }

    var needsReview: [EvidenceItem] {
        items
            .filter { $0.state == .needsReview }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    var done: [EvidenceItem] {
        items
            .filter { $0.state == .done }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    func item(id: UUID?) -> EvidenceItem? {
        guard let id else { return nil }
        return items.first(where: { $0.id == id })
    }

    func markDone(_ evidenceID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == evidenceID }) else { return }
        items[idx].state = .done
    }

    func reopen(_ evidenceID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == evidenceID }) else { return }
        items[idx].state = .needsReview
    }

    func linkToPerson(evidenceID: UUID, personID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == evidenceID }) else { return }
        if !items[idx].linkedPeople.contains(personID) {
            items[idx].linkedPeople.append(personID)
        }
    }

    func linkToContext(evidenceID: UUID, contextID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == evidenceID }) else { return }
        if !items[idx].linkedContexts.contains(contextID) {
            items[idx].linkedContexts.append(contextID)
        }
    }

    func acceptSuggestion(evidenceID: UUID, suggestionID: UUID) {
        guard let eIdx = items.firstIndex(where: { $0.id == evidenceID }) else { return }
        guard let sIdx = items[eIdx].proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }

        items[eIdx].proposedLinks[sIdx].status = .accepted
        items[eIdx].proposedLinks[sIdx].decidedAt = Date()

        let s = items[eIdx].proposedLinks[sIdx]

        switch s.target {
        case .person:
            if !items[eIdx].linkedPeople.contains(s.targetID) {
                items[eIdx].linkedPeople.append(s.targetID)
            }
        case .context:
            if !items[eIdx].linkedContexts.contains(s.targetID) {
                items[eIdx].linkedContexts.append(s.targetID)
            }
        }
    }

    func declineSuggestion(evidenceID: UUID, suggestionID: UUID) {
        guard let eIdx = items.firstIndex(where: { $0.id == evidenceID }) else { return }
        guard let sIdx = items[eIdx].proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }

        items[eIdx].proposedLinks[sIdx].status = .declined
        items[eIdx].proposedLinks[sIdx].decidedAt = Date()
    }

    func resetSuggestionToPending(evidenceID: UUID, suggestionID: UUID) {
        guard let eIdx = items.firstIndex(where: { $0.id == evidenceID }) else { return }
        guard let sIdx = items[eIdx].proposedLinks.firstIndex(where: { $0.id == suggestionID }) else { return }
        items[eIdx].proposedLinks[sIdx].status = .pending
        items[eIdx].proposedLinks[sIdx].decidedAt = Date()
    }
    
    func removeConfirmedLink(
        evidenceID: UUID,
        target: EvidenceLinkTarget,
        targetID: UUID,
        revertSuggestionTo: LinkSuggestionStatus = .pending
    ) {
        guard let eIdx = items.firstIndex(where: { $0.id == evidenceID }) else { return }

        switch target {
        case .person:
            items[eIdx].linkedPeople.removeAll { $0 == targetID }
        case .context:
            items[eIdx].linkedContexts.removeAll { $0 == targetID }
        }

        if let sIdx = items[eIdx].proposedLinks.firstIndex(where: {
            $0.target == target && $0.targetID == targetID
        }) {
            items[eIdx].proposedLinks[sIdx].status = revertSuggestionTo
            items[eIdx].proposedLinks[sIdx].decidedAt = Date()
        }
    }
    
    // MARK: - Seed

    private func seedIfNeeded() {
        guard items.isEmpty else { return }

        let mary = personID(named: "Mary Smith")
        let evan = personID(named: "Evan Patel")
        let cynthia = personID(named: "Cynthia Lopez")

        let smithHousehold = contextID(named: "John & Mary Smith")
        let abc = contextID(named: "ABC Manufacturing")

        // 1) Divorce / household change (mail)
        var e1 = EvidenceItem(
            id: UUID(),
            state: .needsReview,
            source: .mail,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 3),
            title: "Re: Update on the household paperwork",
            snippet: "…we’re separated now and need to update beneficiaries. Can we meet this week?",
            bodyText: "Hi — quick update: we’re separated and I need to make sure beneficiaries and survivorship details are correct. Can we meet this week?\n\n-Mary",
            participantHints: [ParticipantHint(displayName: "mary@example.com", isOrganizer: true, isVerified: false, rawEmail: "mary@example.com")],
            signals: [
                EvidenceSignal(id: UUID(), kind: .divorce, confidence: 0.86, reason: "Contains separation language and beneficiary change intent."),
                EvidenceSignal(id: UUID(), kind: .complianceRisk, confidence: 0.62, reason: "Household survivorship and joint consent may require re-validation.")
            ],
            proposedLinks: [],
            linkedPeople: [],
            linkedContexts: []
        )

        if let mary, let smithHousehold {
            e1.proposedLinks = [
                ProposedLink(
                    id: UUID(),
                    target: .person,
                    targetID: mary,
                    displayName: "Mary Smith",
                    secondaryLine: nil,
                    confidence: 0.93,
                    reason: "Sender name matches and household context is referenced."
                ),
                ProposedLink(
                    id: UUID(),
                    target: .context,
                    targetID: smithHousehold,
                    displayName: "John & Mary Smith",
                    secondaryLine: "Household",
                    confidence: 0.88,
                    reason: "Mentions updating household beneficiaries/survivorship."
                )
            ]
        }

        // 2) Business partner departure (calendar / zoom)
        var e2 = EvidenceItem(
            id: UUID(),
            state: .needsReview,
            source: .calendar,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 7),
            title: "ABC Manufacturing — leadership change review",
            snippet: "Discuss partner departure + buy-sell exposure. Need updated ownership & key person coverage.",
            bodyText: "Agenda: partner leaving effective immediately; update ownership; review buy-sell; key person coverage; benefits for remaining employees.",
            participantHints: [ParticipantHint(displayName: "abc-cfo@example.com", isOrganizer: false, isVerified: false, rawEmail: "abc-cfo@example.com")],
            signals: [
                EvidenceSignal(id: UUID(), kind: .partnerLeft, confidence: 0.83, reason: "Agenda includes partner departure and buy-sell exposure."),
                EvidenceSignal(id: UUID(), kind: .productOpportunity, confidence: 0.71, reason: "Key person + buy-sell commonly requires policy updates.")
            ],
            proposedLinks: [],
            linkedPeople: [],
            linkedContexts: []
        )

        if let abc {
            e2.proposedLinks = [
                ProposedLink(
                    id: UUID(),
                    target: .context,
                    targetID: abc,
                    displayName: "ABC Manufacturing",
                    secondaryLine: "Business",
                    confidence: 0.86,
                    reason: "Meeting title names the business context."
                )
            ]
        }

        // 3) Referral partner intro (mail)
        var e3 = EvidenceItem(
            id: UUID(),
            state: .needsReview,
            source: .mail,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 10),
            title: "Intro: Smith family estate plan update",
            snippet: "I just met with the Smiths. Estate plan updated; beneficiary review recommended.",
            bodyText: "Hi — I just met with the Smith family and they updated their estate plan. A beneficiary review would be timely.\n\n-Evan Patel",
            participantHints: [ParticipantHint(displayName: "evan@patellaw.example", isOrganizer: true, isVerified: false, rawEmail: "evan@patellaw.example")],
            signals: [
                EvidenceSignal(id: UUID(), kind: .productOpportunity, confidence: 0.58, reason: "Estate plan update often implies beneficiary and trust alignment work.")
            ],
            proposedLinks: [],
            linkedPeople: [],
            linkedContexts: []
        )

        var links3: [ProposedLink] = []
        if let evan {
            links3.append(
                ProposedLink(
                    id: UUID(),
                    target: .person,
                    targetID: evan,
                    displayName: "Evan Patel",
                    secondaryLine: "Referral Partner",
                    confidence: 0.92,
                    reason: "Signature matches referral partner."
                )
            )
        }
        if let smithHousehold {
            links3.append(
                ProposedLink(
                    id: UUID(),
                    target: .context,
                    targetID: smithHousehold,
                    displayName: "John & Mary Smith",
                    secondaryLine: "Household",
                    confidence: 0.74,
                    reason: "Mentions the Smith family and estate plan update."
                )
            )
        }
        e3.proposedLinks = links3

        // Optionally attach a vendor-related evidence (kept for later expansion)
        if let cynthia {
            // placeholder usage so variable isn't unused in future tweaks
            _ = cynthia
        }

        items = [e1, e2, e3]
    }

    private func personID(named name: String) -> UUID? {
        peopleStore.listItems.first(where: { $0.displayName == name })?.id
    }

    private func contextID(named name: String) -> UUID? {
        contextStore.listItems.first(where: { $0.name == name })?.id
    }
}
// MARK: - Upsert & Prune (called by CalendarImportCoordinator)

extension MockEvidenceRuntimeStore {

    /// Upsert an EvidenceItem by sourceUID.
    /// If an item with the same sourceUID already exists, its observable facts
    /// (title, snippet, body, occurredAt) are updated and signals are recomputed,
    /// but user work (state, confirmed links, suggestion decisions) is preserved.
    func upsert(_ newItem: EvidenceItem) {
        if let index = items.firstIndex(where: { $0.sourceUID == newItem.sourceUID }) {
            var existing = items[index]

            // Preserve user work (state, confirmed links, suggestion decisions).
            // Update observable facts from the source.
            existing.occurredAt = newItem.occurredAt
            existing.title = newItem.title
            existing.snippet = newItem.snippet
            existing.bodyText = newItem.bodyText
            existing.participantHints = newItem.participantHints

            // Recompute signals after updating facts
            existing.signals = InsightGeneratorV1.signals(for: existing)

            items[index] = existing
        } else {
            var new = newItem
            new.signals = InsightGeneratorV1.signals(for: new)
            items.append(new)
        }
    }

    /// Removes calendar-derived evidence items (EventKit) that are no longer present
    /// in the observed calendar within the current import window.
    ///
    /// This handles cases where a user moves an event to a different calendar
    /// or deletes it: SAM should no longer show it in Inbox.
    func pruneCalendarEvidenceNotIn(
        _ currentUIDs: Set<String>,
        windowStart: Date,
        windowEnd: Date
    ) {
        items.removeAll { item in
            guard item.source == .calendar else { return false }
            guard item.sourceUID.hasPrefix("eventkit:") else { return false }

            // Only prune items in the active import window.
            guard item.occurredAt >= windowStart && item.occurredAt <= windowEnd else { return false }

            // If it isn't in the current calendar query, it was moved/deleted.
            return !currentUIDs.contains(item.sourceUID)
        }
    }
}

