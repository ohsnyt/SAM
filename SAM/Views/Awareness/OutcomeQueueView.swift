//
//  OutcomeQueueView.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  Outcome-focused coaching queue shown in the Awareness dashboard.
//  Displays prioritized outcomes with Done/Skip actions.
//

import SwiftUI
import SwiftData
import TipKit

struct OutcomeQueueView: View {

    // MARK: - Parameters

    /// Maximum number of outcome cards to show before "Show all" link.
    var maxVisible: Int = 5

    // MARK: - Dependencies

    private var engine: OutcomeEngine { OutcomeEngine.shared }
    private var outcomeRepo: OutcomeRepository { OutcomeRepository.shared }
    private var bundleRepo: OutcomeBundleRepository { OutcomeBundleRepository.shared }
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    // MARK: - Queries

    @Query(sort: \SamOutcome.priorityScore, order: .reverse)
    private var allOutcomes: [SamOutcome]

    @Query(sort: \OutcomeBundle.priorityScore, order: .reverse)
    private var allBundles: [OutcomeBundle]

    // MARK: - State

    @State private var showRatingFor: SamOutcome?
    @State private var ratingValue: Int = 3
    @State private var showAllOutcomes = false
    @State private var showDeepWorkSheet = false
    @State private var deepWorkOutcome: SamOutcome?
    @State private var showContentDraftSheet = false
    @State private var contentDraftOutcome: SamOutcome?
    @State private var showSetupGuideSheet = false
    @State private var setupGuideOutcome: SamOutcome?
    @State private var gapRefreshToken = UUID()

    // MARK: - Computed

    private var activeOutcomes: [SamOutcome] {
        allOutcomes.filter {
            ($0.status == .pending || $0.status == .inProgress) && !$0.isAwaitingTrigger
        }
    }

    private var visibleOutcomes: [SamOutcome] {
        if showAllOutcomes {
            return activeOutcomes
        }
        return Array(activeOutcomes.prefix(maxVisible))
    }

    private var hasMore: Bool {
        activeOutcomes.count > maxVisible
    }

    private var activeBundles: [OutcomeBundle] {
        allBundles.filter { $0.closedAt == nil && !$0.openSubItems.isEmpty }
    }

    // MARK: - Body

    var body: some View {
        if activeOutcomes.isEmpty && activeBundles.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                TipView(OutcomeQueueTip())
                    .tipViewStyle(SAMTipViewStyle())
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                // Knowledge gap prompt (max 1 at a time)
                if let gap = engine.activeGaps.first {
                    InlineGapPromptView(gap: gap) {
                        // Refresh gaps after answer
                        engine.activeGaps = engine.detectKnowledgeGaps()
                        gapRefreshToken = UUID()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .id(gapRefreshToken)
                }

                TipView(TodayHeroCardTip())
                    .tipViewStyle(SAMTipViewStyle())
                    .padding(.horizontal)
                    .padding(.bottom, 4)

                // Per-person bundle cards (one card per person, multiple sub-items inside).
                if !activeBundles.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(Array(activeBundles.enumerated()), id: \.element.id) { index, bundle in
                            OutcomeBundleCardView(
                                bundle: bundle,
                                isHero: index == 0 && activeOutcomes.isEmpty,
                                onTick: { item in handleBundleTick(item, in: bundle) },
                                onSkip: { item in handleBundleSkip(item, in: bundle) },
                                onOpenPerson: { openPerson(for: bundle) },
                                onCompose: composeClosure(for: bundle)
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }

                // Active outcome cards
                VStack(spacing: 12) {
                    ForEach(Array(visibleOutcomes.enumerated()), id: \.element.id) { index, outcome in
                        OutcomeCardView(
                            outcome: outcome,
                            isHero: index == 0 && activeBundles.isEmpty,
                            onAct: actClosure(for: outcome),
                            onDone: { markDone(outcome) },
                            onSkip: { markSkipped(outcome) },
                            onSnooze: { date in snoozeOutcome(outcome, until: date) },
                            onMuteKind: {
                                Task { await CalibrationService.shared.setMuted(kind: outcome.outcomeKindRawValue, muted: true) }
                            },
                            sequenceStepCount: sequenceStepCount(for: outcome),
                            nextAwaitingStep: nextAwaitingStep(for: outcome)
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)

                // Show all / collapse link
                if hasMore {
                    Button(action: {
                        withAnimation { showAllOutcomes.toggle() }
                    }) {
                        Text(showAllOutcomes ? "Show fewer" : "Show all \(activeOutcomes.count) suggestions")
                            .samFont(.subheadline)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
            .managedSheet(
                item: $showRatingFor,
                priority: .userInitiated,
                identifier: "outcome.rating"
            ) { outcome in
                ratingSheet(for: outcome)
            }
            .managedSheet(
                isPresented: $showDeepWorkSheet,
                priority: .userInitiated,
                identifier: "outcome.deep-work"
            ) {
                if let outcome = deepWorkOutcome {
                    DeepWorkScheduleSheet(
                        payload: DeepWorkPayload(
                            outcomeID: outcome.id,
                            personID: outcome.linkedPerson?.id,
                            personName: outcome.linkedPerson?.displayNameCache ?? outcome.linkedPerson?.displayName,
                            title: outcome.title,
                            rationale: outcome.rationale
                        ),
                        onScheduled: {
                            try? outcomeRepo.markInProgress(id: outcome.id)
                            showDeepWorkSheet = false
                        },
                        onCancel: {
                            showDeepWorkSheet = false
                        }
                    )
                }
            }
            .managedSheet(
                isPresented: $showContentDraftSheet,
                priority: .userInitiated,
                identifier: "outcome.content-draft"
            ) {
                if let outcome = contentDraftOutcome {
                    let parsed = parseContentTopic(from: outcome.sourceInsightSummary)
                    ContentDraftSheet(
                        topic: parsed.topic,
                        keyPoints: parsed.keyPoints,
                        suggestedTone: parsed.suggestedTone,
                        complianceNotes: parsed.complianceNotes,
                        sourceOutcomeID: outcome.id,
                        onPosted: {
                            try? outcomeRepo.markCompleted(id: outcome.id)
                            showContentDraftSheet = false
                        },
                        onCancel: {
                            showContentDraftSheet = false
                        }
                    )
                }
            }
            .managedSheet(
                isPresented: $showSetupGuideSheet,
                priority: .userInitiated,
                identifier: "outcome.linkedin-setup-guide"
            ) {
                if let outcome = setupGuideOutcome {
                    LinkedInSetupGuideSheet(
                        outcome: outcome,
                        onDone: {
                            showSetupGuideSheet = false
                        },
                        onAlreadyDone: {
                            recordSetupAcknowledgement(outcome)
                            try? outcomeRepo.markCompleted(id: outcome.id)
                            showSetupGuideSheet = false
                        },
                        onDismiss: {
                            recordSetupDismissal(outcome)
                            markSkipped(outcome)
                            showSetupGuideSheet = false
                        }
                    )
                }
            }
        }
    }

    // MARK: - Rating Sheet

    private func ratingSheet(for outcome: SamOutcome) -> some View {
        VStack(spacing: 16) {
            Text("How helpful was this?")
                .samFont(.headline)

            Text(outcome.title)
                .samFont(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Star rating
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= ratingValue ? "star.fill" : "star")
                        .samFont(.title2)
                        .foregroundStyle(star <= ratingValue ? .yellow : .gray)
                        .onTapGesture { ratingValue = star }
                }
            }
            .padding(.vertical, 8)

            HStack {
                Button("Skip") {
                    showRatingFor = nil
                }
                .buttonStyle(.bordered)

                Button("Submit") {
                    if let outcome = showRatingFor {
                        try? outcomeRepo.recordRating(id: outcome.id, rating: ratingValue)
                        Task { await CalibrationService.shared.recordRating(kind: outcome.outcomeKindRawValue, rating: ratingValue) }
                        try? CoachingAdvisor.shared.updateProfile()
                    }
                    showRatingFor = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 300)
    }

    // MARK: - Actions

    private func actClosure(for outcome: SamOutcome) -> (() -> Void)? {
        // Consolidated "Review N meetings" outcome — route into the queue walker instead of
        // the standard outcome action lanes. The walker opens one capture sheet at a time and
        // advances as Sarah saves or skips each meeting.
        if outcome.sourceInsightSummary == DailyBriefingCoordinator.pendingReviewsSourceInsightKey {
            return {
                DailyBriefingCoordinator.shared.startPendingReviewWalker()
            }
        }

        // Content creation outcomes always open the draft sheet
        if outcome.outcomeKind == .contentCreation {
            return {
                contentDraftOutcome = outcome
                showContentDraftSheet = true
            }
        }

        // Setup guidance outcomes open the LinkedIn settings URL + show the guide sheet
        if outcome.outcomeKind == .setup {
            return {
                if let urlString = outcome.draftMessageText, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
                setupGuideOutcome = outcome
                showSetupGuideSheet = true
            }
        }

        switch outcome.actionLane {
        case .record:
            return {
                let payload = QuickNotePayload(
                    outcomeID: outcome.id,
                    personID: outcome.linkedPerson?.id,
                    personName: outcome.linkedPerson?.displayNameCache,
                    contextTitle: outcome.title,
                    prefillText: outcome.suggestedNextStep
                )
                openWindow(id: "quick-note", value: payload)
            }

        case .communicate:
            return {
                let person = outcome.linkedPerson
                let channel = outcome.suggestedChannel ?? person?.effectiveChannel ?? .iMessage
                let address: String
                if channel == .linkedIn, let url = person?.linkedInProfileURL {
                    address = url
                } else {
                    address = person?.emailCache ?? person?.phoneAliases.first ?? ""
                }
                let payload = ComposePayload(
                    outcomeID: outcome.id,
                    personID: person?.id,
                    personName: person?.displayNameCache ?? person?.displayName,
                    recipientAddress: address,
                    channel: channel,
                    draftBody: outcome.draftMessageText ?? outcome.suggestedNextStep ?? "",
                    contextTitle: outcome.title,
                    linkedInProfileURL: person?.linkedInProfileURL,
                    contactAddresses: person?.contactAddresses
                )
                openWindow(id: "compose-message", value: payload)
            }

        case .call:
            return {
                let person = outcome.linkedPerson
                let phone = person?.phoneAliases.first ?? ""
                if !phone.isEmpty {
                    ComposeService.shared.initiateCall(recipient: phone)
                }
                // After call, offer note capture via quick note
                let payload = QuickNotePayload(
                    outcomeID: outcome.id,
                    personID: person?.id,
                    personName: person?.displayNameCache ?? person?.displayName,
                    contextTitle: "Post-call: \(outcome.title)",
                    prefillText: "How did it go?"
                )
                openWindow(id: "quick-note", value: payload)
            }

        case .deepWork:
            return {
                deepWorkOutcome = outcome
                showDeepWorkSheet = true
            }

        case .schedule:
            // Schedule lane: navigate to person for now; calendar event creation in Part 4
            guard let personID = outcome.linkedPerson?.id else { return nil }
            return {
                NotificationCenter.default.post(
                    name: .samNavigateToPerson,
                    object: nil,
                    userInfo: ["personID": personID]
                )
            }

        case .reviewGraph:
            return {
                // Complete this outcome immediately — the user is taking action.
                // When they exit the graph, OutcomeEngine will recheck and create
                // a fresh outcome if any unconfirmed items remain.
                markDone(outcome)

                let focusMode = outcome.title.contains("suggested role")
                    ? "roleConfirmation"
                    : "deducedRelationships"
                NotificationCenter.default.post(
                    name: .samNavigateToGraph,
                    object: nil,
                    userInfo: ["focusMode": focusMode]
                )
            }

        case .openURL:
            // Handled above by the .setup kind check; fall through to nil for any other outcome
            return nil
        }
    }

    private func markDone(_ outcome: SamOutcome) {
        try? outcomeRepo.markCompleted(id: outcome.id)

        // Update coaching profile
        try? CoachingAdvisor.shared.updateProfile()

        // Record calibration signals
        Task {
            let hour = Calendar.current.component(.hour, from: .now)
            let dow = Calendar.current.component(.weekday, from: .now)
            let responseMin = outcome.lastSurfacedAt.map { Date.now.timeIntervalSince($0) / 60 } ?? 0
            await CalibrationService.shared.recordCompletion(
                kind: outcome.outcomeKindRawValue, responseMinutes: responseMin, hour: hour, dayOfWeek: dow)
        }

        // Adaptive rating frequency
        if CoachingAdvisor.shared.shouldRequestRating() {
            ratingValue = 3
            showRatingFor = outcome
        }
    }

    private func markSkipped(_ outcome: SamOutcome) {
        // For setup outcomes, record the dismissal in UserDefaults for resurface timing
        if outcome.outcomeKind == .setup {
            recordSetupDismissal(outcome)
        }

        try? outcomeRepo.markDismissed(id: outcome.id)

        // Record calibration dismissal signal
        Task { await CalibrationService.shared.recordDismissal(kind: outcome.outcomeKindRawValue) }
    }

    private func snoozeOutcome(_ outcome: SamOutcome, until date: Date) {
        try? outcomeRepo.markSnoozed(id: outcome.id, until: date)
        Task { await CalibrationService.shared.recordSnooze(kind: outcome.outcomeKindRawValue) }
    }

    // MARK: - Bundle Actions

    private func handleBundleTick(_ item: OutcomeSubItem, in bundle: OutcomeBundle) {
        let kindRaw = item.kindRawValue
        applyBundleStatusChange(item: item, in: bundle, kind: .completed)
        Task { await CalibrationService.shared.recordCompletion(
            kind: kindRaw, responseMinutes: 0, hour: Calendar.current.component(.hour, from: .now),
            dayOfWeek: Calendar.current.component(.weekday, from: .now)) }
    }

    private func handleBundleSkip(_ item: OutcomeSubItem, in bundle: OutcomeBundle) {
        let kindRaw = item.kindRawValue
        applyBundleStatusChange(item: item, in: bundle, kind: .skipped)
        Task { await CalibrationService.shared.recordDismissal(kind: kindRaw) }
    }

    private enum BundleStatusChange { case completed, skipped }

    /// Tick/skip a sub-item using the view's `modelContext` so SwiftUI observes
    /// the mutation and the bundle's `openSubItems` re-filters on next render.
    /// `OutcomeBundleRepository` owns a separate context — writing through it
    /// leaves the view stale (cross-context visibility), so all state the UI
    /// renders is mutated here. The suppression record is still written via
    /// the repo since it's only consumed by background scanners.
    private func applyBundleStatusChange(item: OutcomeSubItem, in bundle: OutcomeBundle, kind: BundleStatusChange) {
        let kindRaw = item.kindRawValue
        let nextDue = OutcomeRecurrence.nextDueAt(for: item.kind, after: .now, isMilestone: item.isMilestone)

        switch kind {
        case .completed: item.completedAt = .now
        case .skipped:   item.skippedAt = .now
        }
        item.nextDueAt = nextDue
        bundle.updatedAt = .now

        let open = bundle.openSubItems
        if open.isEmpty {
            bundle.priorityScore = 0
            bundle.nearestDueDate = nil
        } else {
            let maxPriority = open.map(\.priorityScore).max() ?? 0
            let groups = Set(open.map { $0.kind.topicGroup })
            let bump = groups.count >= 2 ? 0.1 : 0.0
            bundle.priorityScore = min(1.0, maxPriority + bump)
            bundle.nearestDueDate = open.compactMap(\.dueDate).min()
        }

        if bundle.closedAt == nil,
           !bundle.subItems.isEmpty,
           bundle.subItems.allSatisfy({ $0.completedAt != nil || $0.skippedAt != nil }) {
            bundle.closedAt = .now
        }

        try? modelContext.save()

        try? bundleRepo.recordSuppression(
            personID: bundle.personID,
            kindRawValue: kindRaw,
            suppressUntil: nextDue,
            migratedFromLegacy: false
        )
    }

    private func openPerson(for bundle: OutcomeBundle) {
        guard let personID = bundle.person?.id else { return }
        NotificationCenter.default.post(
            name: .samNavigateToPerson,
            object: nil,
            userInfo: ["personID": personID]
        )
    }

    private func composeClosure(for bundle: OutcomeBundle) -> (() -> Void)? {
        guard let draft = bundle.combinedDraftMessage, !draft.isEmpty,
              let person = bundle.person else { return nil }
        return {
            let channel = person.effectiveChannel ?? .iMessage
            let address: String
            if channel == .linkedIn, let url = person.linkedInProfileURL {
                address = url
            } else {
                address = person.emailCache ?? person.phoneAliases.first ?? ""
            }
            let payload = ComposePayload(
                outcomeID: bundle.id,
                personID: person.id,
                personName: person.displayNameCache ?? person.displayName,
                recipientAddress: address,
                channel: channel,
                draftBody: draft,
                contextTitle: "Outreach to \(person.displayNameCache ?? person.displayName)",
                linkedInProfileURL: person.linkedInProfileURL,
                contactAddresses: person.contactAddresses
            )
            openWindow(id: "compose-message", value: payload)
        }
    }

    // MARK: - Setup Guidance UserDefaults Helpers (Phase 6)

    /// Records that the user said "Already Done" for a setup guidance outcome.
    private func recordSetupAcknowledgement(_ outcome: SamOutcome) {
        guard let payload = parseSetupPayload(outcome) else { return }
        let key = payload.userDefaultsKey
        UserDefaults.standard.set(true, forKey: "\(key).acknowledged")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "\(key).acknowledgedAt")
    }

    /// Records a dismissal for a setup guidance outcome, incrementing the dismiss count.
    private func recordSetupDismissal(_ outcome: SamOutcome) {
        guard let payload = parseSetupPayload(outcome) else { return }
        let key = payload.userDefaultsKey
        let count = UserDefaults.standard.integer(forKey: "\(key).dismissCount")
        UserDefaults.standard.set(count + 1, forKey: "\(key).dismissCount")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "\(key).lastDismissedAt")
    }

    /// Decodes a SetupGuidePayload from a setup guidance outcome's sourceInsightSummary.
    private func parseSetupPayload(_ outcome: SamOutcome) -> SetupGuidePayload? {
        let json = outcome.sourceInsightSummary
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SetupGuidePayload.self, from: data)
    }

    // MARK: - Sequence Helpers

    private func sequenceStepCount(for outcome: SamOutcome) -> Int {
        guard let seqID = outcome.sequenceID else { return 0 }
        return allOutcomes.filter { $0.sequenceID == seqID }.count
    }

    private func nextAwaitingStep(for outcome: SamOutcome) -> SamOutcome? {
        guard let seqID = outcome.sequenceID else { return nil }
        return allOutcomes
            .filter { $0.sequenceID == seqID && $0.sequenceIndex > outcome.sequenceIndex && $0.isAwaitingTrigger && $0.status == .pending }
            .sorted(by: { $0.sequenceIndex < $1.sequenceIndex })
            .first
    }

    // MARK: - Content Topic Parsing (Phase W)

    /// Parse a ContentTopic from JSON stored in sourceInsightSummary.
    /// Falls back to using the outcome title as the topic.
    private func parseContentTopic(from json: String) -> (topic: String, keyPoints: [String], suggestedTone: String, complianceNotes: String?) {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let topic = try? JSONDecoder().decode(ContentTopic.self, from: data) else {
            return (topic: "Educational content", keyPoints: [], suggestedTone: "educational", complianceNotes: nil)
        }
        return (topic: topic.topic, keyPoints: topic.keyPoints, suggestedTone: topic.suggestedTone, complianceNotes: topic.complianceNotes)
    }
}
