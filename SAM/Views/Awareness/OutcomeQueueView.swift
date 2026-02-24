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

    // MARK: - Computed

    private var activeOutcomes: [SamOutcome] {
        allOutcomes.filter { $0.status == .pending || $0.status == .inProgress }
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
                                onSkip: { markSkipped(outcome) }
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
        let action = outcome.outcomeKind.defaultAction
        switch action {
        case .captureNote:
            return {
                let payload = QuickNotePayload(
                    outcomeID: outcome.id,
                    personID: outcome.linkedPerson?.id,
                    personName: outcome.linkedPerson?.displayNameCache,
                    contextTitle: outcome.suggestedNextStep ?? outcome.title
                )
                openWindow(id: "quick-note", value: payload)
            }
        case .openPerson:
            guard let personID = outcome.linkedPerson?.id else { return nil }
            return {
                NotificationCenter.default.post(
                    name: .samNavigateToPerson,
                    object: nil,
                    userInfo: ["personID": personID]
                )
            }
        case .openEvidence:
            return nil
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
}
