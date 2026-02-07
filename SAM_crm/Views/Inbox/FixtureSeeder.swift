import Foundation
import SwiftData

#if DEBUG

private func _validateSeedEnums(_ context: ModelContext) {
    let validStates = Set(["needsReview", "done"])
    let items: [SamEvidenceItem] = (try? context.fetch(FetchDescriptor<SamEvidenceItem>())) ?? []
    for item in items {
        assert(validStates.contains(item.state.rawValue), "Invalid state value found in seeded SamEvidenceItem: \(item.state.rawValue)")
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Well-known seed UUIDs
// ─────────────────────────────────────────────────────────────────────
// Fixed UUIDs so that FixtureSeeder and any future scenario helpers can
// reference the same people / contexts without querying the store.
// These are only used in DEBUG builds.

enum SeedIDs {
    // People
    static let marySmith        = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let evanPatel        = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let cynthiaLopez     = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    // Contexts
    static let smithHousehold   = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    static let abcManufacturing = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
}

enum FixtureSeeder {
    static func seedIfNeeded(using container: ModelContainer) {
        let context = ModelContext(container)
        // Check if we already have any evidence; if so, skip seeding.
        let count = (try? context.fetchCount(FetchDescriptor<SamEvidenceItem>())) ?? 0
        guard count == 0 else { return }

        // 1. Seed the people & contexts that proposed links will reference.
        seedPeopleAndContexts(into: context)

        // 2. Seed evidence scenarios (each may attach proposedLinks).
        seedDivorceScenario(into: context)
        seedBusinessChangeScenario(into: context)
        seedReferralIntroScenario(into: context)

        try? context.save()

        _validateSeedEnums(context)
    }

    // ── People & Contexts ─────────────────────────────────────────────

    private static func seedPeopleAndContexts(into context: ModelContext) {
        let mary = SamPerson(
            id: SeedIDs.marySmith,
            displayName: "Mary Smith",
            roleBadges: ["Client"],
            email: "mary@example.com"
        )
        let evan = SamPerson(
            id: SeedIDs.evanPatel,
            displayName: "Evan Patel",
            roleBadges: ["Referral Partner"],
            email: "evan@patellaw.example"
        )
        let cynthia = SamPerson(
            id: SeedIDs.cynthiaLopez,
            displayName: "Cynthia Lopez",
            roleBadges: ["Client"],
            email: "cynthia@lopez.example"
        )

        let smithHH = SamContext(
            id: SeedIDs.smithHousehold,
            name: "John & Mary Smith",
            kind: .household
        )
        let abc = SamContext(
            id: SeedIDs.abcManufacturing,
            name: "ABC Manufacturing",
            kind: .business
        )

        for model in [mary, evan, cynthia] as [any PersistentModel] {
            context.insert(model)
        }
        for model in [smithHH, abc] as [any PersistentModel] {
            context.insert(model)
        }

        // ── Seed initial persisted insights (Phase 1) ───────────────
        let maryFollowUp = SamInsight(
            samPerson: mary,
            kind: .followUp,
            message: "Consider scheduling annual review.",
            confidence: 0.72,
        )
        context.insert(maryFollowUp)

        let smithConsent = SamInsight(
            samContext: smithHH,
            kind: .consentMissing,
            message: "Spousal consent may need review after recent household change.",
            confidence: 0.88,
        )
        context.insert(smithConsent)
    }

    // ── Scenario: Divorce / household change ─────────────────────────

    private static func seedDivorceScenario(into context: ModelContext) {
        let item = SamEvidenceItem(
            id: UUID(),
            state: .needsReview,
            sourceUID: nil,
            source: .mail,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 3),
            title: "Re: Update on the household paperwork",
            snippet: "We\u{2019}re separated now and need to update beneficiaries. Can we meet this week?",
            bodyText: "Hi \u{2014} quick update: we\u{2019}re separated and I need to make sure beneficiaries and survivorship details are correct. Can we meet this week?\n\n-Mary",
            participantHints: [
                ParticipantHint(displayName: "mary@example.com", isOrganizer: true, isVerified: false, rawEmail: "mary@example.com")
            ],
            signals: [
                EvidenceSignal(id: UUID(), kind: .divorce, confidence: 0.86, reason: "Contains separation language and beneficiary change intent."),
                EvidenceSignal(id: UUID(), kind: .complianceRisk, confidence: 0.62, reason: "Household survivorship and joint consent may require re-validation.")
            ],
            proposedLinks: [
                ProposedLink(
                    id: UUID(),
                    target: .person,
                    targetID: SeedIDs.marySmith,
                    displayName: "Mary Smith",
                    secondaryLine: nil,
                    confidence: 0.93,
                    reason: "Sender name matches and household context is referenced."
                ),
                ProposedLink(
                    id: UUID(),
                    target: .context,
                    targetID: SeedIDs.smithHousehold,
                    displayName: "John & Mary Smith",
                    secondaryLine: "Household",
                    confidence: 0.88,
                    reason: "Mentions updating household beneficiaries/survivorship."
                )
            ]
        )
        context.insert(item)
    }

    // ── Scenario: Business partner departure ─────────────────────────

    private static func seedBusinessChangeScenario(into context: ModelContext) {
        let item = SamEvidenceItem(
            id: UUID(),
            state: .needsReview,
            sourceUID: nil,
            source: .calendar,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 7),
            title: "ABC Manufacturing \u{2014} leadership change review",
            snippet: "Discuss partner departure + buy-sell exposure. Need updated ownership & key person coverage.",
            bodyText: "Agenda: partner leaving effective immediately; update ownership; review buy-sell; key person coverage; benefits for remaining employees.",
            participantHints: [
                ParticipantHint(displayName: "abc-cfo@example.com", isOrganizer: false, isVerified: false, rawEmail: "abc-cfo@example.com")
            ],
            signals: [
                EvidenceSignal(id: UUID(), kind: .partnerLeft, confidence: 0.83, reason: "Agenda includes partner departure and buy-sell exposure."),
                EvidenceSignal(id: UUID(), kind: .productOpportunity, confidence: 0.71, reason: "Key person + buy-sell commonly requires policy updates.")
            ],
            proposedLinks: [
                ProposedLink(
                    id: UUID(),
                    target: .context,
                    targetID: SeedIDs.abcManufacturing,
                    displayName: "ABC Manufacturing",
                    secondaryLine: "Business",
                    confidence: 0.86,
                    reason: "Meeting title names the business context."
                )
            ]
        )
        context.insert(item)
    }

    // ── Scenario: Referral partner intro ──────────────────────────────

    private static func seedReferralIntroScenario(into context: ModelContext) {
        let item = SamEvidenceItem(
            id: UUID(),
            state: .needsReview,
            sourceUID: nil,
            source: .mail,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 10),
            title: "Intro: Smith family estate plan update",
            snippet: "I just met with the Smiths. Estate plan updated; beneficiary review recommended.",
            bodyText: "Hi — I just met with the Smith family and they updated their estate plan. A beneficiary review would be timely.\n\n-Evan Patel",
            participantHints: [
                ParticipantHint(displayName: "evan@patellaw.example", isOrganizer: true, isVerified: false, rawEmail: "evan@patellaw.example")
            ],
            signals: [
                EvidenceSignal(id: UUID(), kind: .productOpportunity, confidence: 0.58, reason: "Estate plan update often implies beneficiary and trust alignment work.")
            ],
            proposedLinks: [
                ProposedLink(
                    id: UUID(),
                    target: .person,
                    targetID: SeedIDs.evanPatel,
                    displayName: "Evan Patel",
                    secondaryLine: "Referral Partner",
                    confidence: 0.75,
                    reason: "Referral partner introducing the Smith family."
                ),
                ProposedLink(
                    id: UUID(),
                    target: .context,
                    targetID: SeedIDs.smithHousehold,
                    displayName: "John & Mary Smith",
                    secondaryLine: "Household",
                    confidence: 0.7,
                    reason: "Mentions the Smith family household."
                )
            ]
        )
        context.insert(item)
    }
}
#endif

