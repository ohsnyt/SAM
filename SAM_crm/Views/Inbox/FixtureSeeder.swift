import Foundation
import SwiftData

#if DEBUG
enum FixtureSeeder {
    static func seedIfNeeded(using container: ModelContainer) {
        let context = ModelContext(container)
        // Check if we already have any evidence; if so, skip seeding.
        let count = (try? context.fetchCount(FetchDescriptor<SamEvidenceItem>())) ?? 0
        guard count == 0 else { return }

        // Seed scenarios
        seedDivorceScenario(into: context)
        seedBusinessChangeScenario(into: context)
        seedReferralIntroScenario(into: context)

        try? context.save()
    }

    private static func seedDivorceScenario(into context: ModelContext) {
        var item = SamEvidenceItem(
            id: UUID(),
            state: .needsReview,
            sourceUID: nil,
            source: .mail,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 3),
            title: "Re: Update on the household paperwork",
            snippet: "…we’re separated now and need to update beneficiaries. Can we meet this week?",
            bodyText: "Hi — quick update: we’re separated and I need to make sure beneficiaries and survivorship details are correct. Can we meet this week?\n\n-Mary",
            participantHints: [SamParticipantHint(displayName: "mary@example.com", isOrganizer: true, isVerified: false, rawEmail: "mary@example.com")],
            signals: [
                SamEvidenceSignal(id: UUID(), kind: .divorce, confidence: 0.86, reason: "Contains separation language and beneficiary change intent."),
                SamEvidenceSignal(id: UUID(), kind: .complianceRisk, confidence: 0.62, reason: "Household survivorship and joint consent may require re-validation.")
            ],
            proposedLinks: []
        )
        context.insert(item)
    }

    private static func seedBusinessChangeScenario(into context: ModelContext) {
        var item = SamEvidenceItem(
            id: UUID(),
            state: .needsReview,
            sourceUID: nil,
            source: .calendar,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 7),
            title: "ABC Manufacturing — leadership change review",
            snippet: "Discuss partner departure + buy-sell exposure. Need updated ownership & key person coverage.",
            bodyText: "Agenda: partner leaving effective immediately; update ownership; review buy-sell; key person coverage; benefits for remaining employees.",
            participantHints: [SamParticipantHint(displayName: "abc-cfo@example.com", isOrganizer: false, isVerified: false, rawEmail: "abc-cfo@example.com")],
            signals: [
                SamEvidenceSignal(id: UUID(), kind: .partnerLeft, confidence: 0.83, reason: "Agenda includes partner departure and buy-sell exposure."),
                SamEvidenceSignal(id: UUID(), kind: .productOpportunity, confidence: 0.71, reason: "Key person + buy-sell commonly requires policy updates.")
            ],
            proposedLinks: []
        )
        context.insert(item)
    }

    private static func seedReferralIntroScenario(into context: ModelContext) {
        var item = SamEvidenceItem(
            id: UUID(),
            state: .needsReview,
            sourceUID: nil,
            source: .mail,
            occurredAt: Date().addingTimeInterval(-60 * 60 * 24 * 10),
            title: "Intro: Smith family estate plan update",
            snippet: "I just met with the Smiths. Estate plan updated; beneficiary review recommended.",
            bodyText: "Hi — I just met with the Smith family and they updated their estate plan. A beneficiary review would be timely.\n\n-Evan Patel",
            participantHints: [SamParticipantHint(displayName: "evan@patellaw.example", isOrganizer: true, isVerified: false, rawEmail: "evan@patellaw.example")],
            signals: [
                SamEvidenceSignal(id: UUID(), kind: .productOpportunity, confidence: 0.58, reason: "Estate plan update often implies beneficiary and trust alignment work.")
            ],
            proposedLinks: []
        )
        context.insert(item)
    }
}
#endif
