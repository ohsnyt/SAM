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

    /// Maximum number of cards to show before the "Show more" footer.
    /// 7 covers a typical day's worth of high-priority items without overwhelming
    /// the user; remaining items appear in collapsed form below when expanded.
    var maxVisible: Int = 7

    /// Optional Sphere filter (passed from AwarenessView toolbar). When set,
    /// only outcomes/bundles for people in the active Sphere are shown.
    var sphereFilter: AwarenessView.SphereFilter = AwarenessView.SphereFilter(
        sphereID: nil, memberIDs: nil, accentColor: nil
    )

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
    /// When true, overflow items beyond `maxVisible` render below the footer
    /// as collapsed-only cards. Resets to false each app launch — focus
    /// discipline by default.
    @State private var showAllOutcomes = false
    @State private var showDeepWorkSheet = false
    @State private var deepWorkOutcome: SamOutcome?
    @State private var showContentDraftSheet = false
    @State private var contentDraftOutcome: SamOutcome?
    @State private var showSetupGuideSheet = false
    @State private var setupGuideOutcome: SamOutcome?
    @State private var gapRefreshToken = UUID()

    /// Which card in the merged feed is rendered expanded. The id matches
    /// either an `OutcomeBundle.id` or a `SamOutcome.id`. Defaults to the
    /// top-priority item (lazily resolved in `expandedItemResolved`).
    @State private var expandedItemID: UUID?

    // MARK: - Queue Item (unified bundle + standalone outcome)

    /// Wraps either type so we can merge into a single priority-sorted feed.
    /// Priority lives on a shared [0,1] scale (see CLAUDE.md / OutcomeEngine),
    /// so sorting across both types reflects actual urgency rather than the
    /// older bundles-first-then-outcomes rendering rule.
    private enum QueueItem: Identifiable {
        case bundle(OutcomeBundle)
        case outcome(SamOutcome)

        var id: UUID {
            switch self {
            case .bundle(let b):  return b.id
            case .outcome(let o): return o.id
            }
        }

        var priorityScore: Double {
            switch self {
            case .bundle(let b):  return b.priorityScore
            case .outcome(let o): return o.priorityScore
            }
        }
    }

    // MARK: - Computed

    private var activeOutcomes: [SamOutcome] {
        allOutcomes.filter {
            ($0.status == .pending || $0.status == .inProgress)
                && !$0.isAwaitingTrigger
                && sphereFilter.allows(personID: $0.linkedPerson?.id)
        }
    }

    private var activeBundles: [OutcomeBundle] {
        allBundles.filter {
            $0.closedAt == nil
                && !$0.openSubItems.isEmpty
                && sphereFilter.allows(personID: $0.personID)
        }
    }

    /// Single priority-sorted feed combining bundles and standalone outcomes.
    private var mergedFeed: [QueueItem] {
        let items: [QueueItem] = activeBundles.map { .bundle($0) } + activeOutcomes.map { .outcome($0) }
        return items.sorted { $0.priorityScore > $1.priorityScore }
    }

    /// Top `maxVisible` items — always rendered with one expanded + rest collapsed.
    private var topItems: [QueueItem] {
        Array(mergedFeed.prefix(maxVisible))
    }

    /// Overflow items — only rendered when the user taps the footer to expand.
    /// These are always collapsed and cannot be expanded individually.
    private var overflowItems: [QueueItem] {
        guard mergedFeed.count > maxVisible else { return [] }
        return Array(mergedFeed.dropFirst(maxVisible))
    }

    private var hasMore: Bool {
        mergedFeed.count > maxVisible
    }

    /// Which item is currently expanded. Defaults to the top-priority item
    /// when the user hasn't explicitly picked one (or has picked one that's
    /// since left the queue via completion/dismissal). The chosen item can
    /// live in either the top section or the overflow section — both are
    /// expandable so the user can preview any card without losing place.
    private var expandedItemResolved: UUID? {
        if let chosen = expandedItemID,
           mergedFeed.contains(where: { $0.id == chosen }) {
            return chosen
        }
        return topItems.first?.id
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

                // Merged feed: bundles + standalones interleaved by priorityScore.
                // Only one card is expanded at a time (top by default; user can
                // tap a collapsed card to swap which one is expanded). Items beyond
                // `maxVisible` only render when the footer is tapped, and always
                // as collapsed-only cards — preserves focus discipline.
                let expandedID = expandedItemResolved
                VStack(spacing: 10) {
                    ForEach(topItems) { item in
                        renderCard(item, expandedID: expandedID, allowExpand: true)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)

                // Footer — tappable: expands the backlog as a list of collapsed cards.
                if hasMore {
                    let overflowCount = overflowItems.count
                    Button(action: {
                        withAnimation { showAllOutcomes.toggle() }
                    }) {
                        VStack(spacing: 6) {
                            Rectangle()
                                .fill(.separator)
                                .frame(height: 0.5)
                            HStack(spacing: 6) {
                                Image(systemName: showAllOutcomes ? "chevron.up" : "chevron.down")
                                    .samFont(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(showAllOutcomes
                                     ? "Show fewer"
                                     : "\(overflowCount) additional \(overflowCount == 1 ? "task has" : "tasks have") been identified and are ready for your consideration.")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }

                // Overflow items — tappable to expand in place. Expansion is
                // single-card across the whole feed, so tapping here collapses
                // whatever was expanded in the top section.
                if showAllOutcomes && !overflowItems.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(overflowItems) { item in
                            renderCard(item, expandedID: expandedID, allowExpand: true)
                        }
                    }
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

    // MARK: - Card Rendering

    /// Renders a queue item as the appropriate card type. `allowExpand` is
    /// false for overflow items beyond the top cap — they remain collapsed.
    @ViewBuilder
    private func renderCard(_ item: QueueItem, expandedID: UUID?, allowExpand: Bool) -> some View {
        switch item {
        case .bundle(let bundle):
            let isExpanded = allowExpand && bundle.id == expandedID
            OutcomeBundleCardView(
                bundle: bundle,
                isHero: isExpanded,
                collapsed: !isExpanded,
                onExpand: allowExpand ? {
                    withAnimation { expandedItemID = bundle.id }
                } : nil,
                onTick: { sub in handleBundleTick(sub, in: bundle) },
                onSkip: { sub in handleBundleSkip(sub, in: bundle) },
                onOpenPerson: { openPerson(for: bundle) },
                onCompose: composeClosure(for: bundle)
            )
        case .outcome(let outcome):
            let isExpanded = allowExpand && outcome.id == expandedID
            OutcomeCardView(
                outcome: outcome,
                isHero: isExpanded,
                onAct: actClosure(for: outcome),
                onDone: { markDone(outcome) },
                onSkip: { markSkipped(outcome) },
                onSnooze: { date in snoozeOutcome(outcome, until: date) },
                onMuteKind: {
                    Task { await CalibrationService.shared.setMuted(kind: outcome.outcomeKindRawValue, muted: true) }
                },
                sequenceStepCount: sequenceStepCount(for: outcome),
                nextAwaitingStep: nextAwaitingStep(for: outcome),
                collapsed: !isExpanded,
                onExpand: allowExpand ? {
                    withAnimation { expandedItemID = outcome.id }
                } : nil
            )
        }
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
    /// Returns an empty topic when the outcome was created without a
    /// concrete suggestion (e.g. cadence nudges like "Post on LinkedIn —
    /// 47 days since last post"). ContentDraftSheet detects the empty
    /// topic and prompts the user to enter one — that's better than
    /// generating a draft about the word "Educational content".
    private func parseContentTopic(from json: String) -> (topic: String, keyPoints: [String], suggestedTone: String, complianceNotes: String?) {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let topic = try? JSONDecoder().decode(ContentTopic.self, from: data) else {
            return (topic: "", keyPoints: [], suggestedTone: "educational", complianceNotes: nil)
        }
        return (topic: topic.topic, keyPoints: topic.keyPoints, suggestedTone: topic.suggestedTone, complianceNotes: topic.complianceNotes)
    }
}
