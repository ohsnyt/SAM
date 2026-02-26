//
//  OutcomeQueueView.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  Outcome-focused coaching queue shown at the top of the Awareness dashboard.
//  Displays prioritized outcomes with Done/Skip actions and a completed-today section.
//

import SwiftUI
import SwiftData

struct OutcomeQueueView: View {

    // MARK: - Dependencies

    private var engine: OutcomeEngine { OutcomeEngine.shared }
    private var outcomeRepo: OutcomeRepository { OutcomeRepository.shared }
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    // MARK: - Queries

    @Query(sort: \SamOutcome.priorityScore, order: .reverse)
    private var allOutcomes: [SamOutcome]

    // MARK: - State

    @State private var showRatingFor: SamOutcome?
    @State private var ratingValue: Int = 3
    @State private var showCompleted = false
    @State private var showDeepWorkSheet = false
    @State private var deepWorkOutcome: SamOutcome?
    @State private var showContentDraftSheet = false
    @State private var contentDraftOutcome: SamOutcome?

    // MARK: - Computed

    private var activeOutcomes: [SamOutcome] {
        allOutcomes.filter {
            ($0.status == .pending || $0.status == .inProgress) && !$0.isAwaitingTrigger
        }
    }

    private var completedToday: [SamOutcome] {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return allOutcomes.filter {
            $0.status == .completed
            && $0.completedAt != nil
            && $0.completedAt! >= startOfDay
        }
    }

    // MARK: - Body

    var body: some View {
        if activeOutcomes.isEmpty && completedToday.isEmpty {
            // Don't show anything when there are no outcomes at all
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                header
                    .padding()

                Divider()

                if activeOutcomes.isEmpty {
                    emptyActiveState
                        .padding()
                } else {
                    // Active outcome cards
                    VStack(spacing: 12) {
                        ForEach(activeOutcomes) { outcome in
                            OutcomeCardView(
                                outcome: outcome,
                                onAct: actClosure(for: outcome),
                                onDone: { markDone(outcome) },
                                onSkip: { markSkipped(outcome) },
                                sequenceStepCount: sequenceStepCount(for: outcome),
                                nextAwaitingStep: nextAwaitingStep(for: outcome)
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }

                // Completed today section
                if !completedToday.isEmpty {
                    completedSection
                }

                Divider()
            }
            .sheet(item: $showRatingFor) { outcome in
                ratingSheet(for: outcome)
            }
            .sheet(isPresented: $showDeepWorkSheet) {
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
            .sheet(isPresented: $showContentDraftSheet) {
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
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SAM Coach")
                    .font(.title3)
                    .fontWeight(.semibold)

                let count = activeOutcomes.count
                if count > 0 {
                    Text("\(count) outcome\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") your attention")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("All caught up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Status indicator
            if engine.generationStatus == .generating {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 8)
            }

            Button(action: {
                Task { await engine.generateOutcomes() }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(engine.generationStatus == .generating)
            .help("Refresh outcomes")
        }
    }

    // MARK: - Empty Active State

    private var emptyActiveState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title)
                .foregroundStyle(.green)
            Text("You're on track")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("No outcomes need attention right now. Keep up the momentum.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Completed Section

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation { showCompleted.toggle() } }) {
                HStack {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Completed Today (\(completedToday.count))")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if showCompleted {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(completedToday) { outcome in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(outcome.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Rating Sheet

    private func ratingSheet(for outcome: SamOutcome) -> some View {
        VStack(spacing: 16) {
            Text("How helpful was this?")
                .font(.headline)

            Text(outcome.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Star rating
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= ratingValue ? "star.fill" : "star")
                        .font(.title2)
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
        // Content creation outcomes always open the draft sheet
        if outcome.outcomeKind == .contentCreation {
            return {
                contentDraftOutcome = outcome
                showContentDraftSheet = true
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
                let address = person?.emailCache ?? person?.phoneAliases.first ?? ""
                let channel = outcome.suggestedChannel ?? person?.effectiveChannel ?? .iMessage
                let payload = ComposePayload(
                    outcomeID: outcome.id,
                    personID: person?.id,
                    personName: person?.displayNameCache ?? person?.displayName,
                    recipientAddress: address,
                    channel: channel,
                    draftBody: outcome.draftMessageText ?? outcome.suggestedNextStep ?? "",
                    contextTitle: outcome.title
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
        }
    }

    private func markDone(_ outcome: SamOutcome) {
        try? outcomeRepo.markCompleted(id: outcome.id)

        // Occasionally show rating (roughly 1 in 5)
        if Int.random(in: 1...5) == 1 {
            ratingValue = 3
            showRatingFor = outcome
        }
    }

    private func markSkipped(_ outcome: SamOutcome) {
        try? outcomeRepo.markDismissed(id: outcome.id)
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
