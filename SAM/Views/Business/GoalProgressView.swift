//
//  GoalProgressView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase X: Goal Setting & Decomposition
//
//  5th tab in BusinessDashboardView — shows all active goals with live progress.
//

import SwiftUI

struct GoalProgressView: View {

    @State private var progressItems: [GoalProgress] = []
    @State private var showAddGoal = false
    @State private var editingGoal: BusinessGoal? = nil

    private var engine: GoalProgressEngine { GoalProgressEngine.shared }
    private var goalRepo: GoalRepository { GoalRepository.shared }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Goals", systemImage: "target")
                    .font(.headline)

                Spacer()

                Button {
                    showAddGoal = true
                } label: {
                    Label("Add Goal", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if progressItems.isEmpty {
                emptyState
            } else {
                goalList
            }
        }
        .task {
            refreshProgress()
        }
        .sheet(isPresented: $showAddGoal) {
            GoalEntryForm(mode: .create) {
                refreshProgress()
            }
        }
        .sheet(item: $editingGoal) { goal in
            GoalEntryForm(mode: .edit(goal)) {
                refreshProgress()
            }
        }
    }

    // MARK: - Goal List

    private var goalList: some View {
        VStack(spacing: 12) {
            ForEach(progressItems) { item in
                goalCard(item)
            }
        }
        .padding()
    }

    // MARK: - Goal Card

    private func goalCard(_ progress: GoalProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title row
            HStack(spacing: 8) {
                Image(systemName: progress.goalType.icon)
                    .foregroundStyle(progress.goalType.color)
                    .font(.title3)

                Text(progress.title)
                    .font(.headline)

                Spacer()

                // Pace badge
                Text(progress.pace.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(progress.pace.color)
                    .clipShape(Capsule())
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(progress.pace.color)
                        .frame(width: geo.size.width * progress.percentComplete, height: 8)
                }
            }
            .frame(height: 8)

            // Value + days remaining
            HStack {
                Text(formattedValue(progress.currentValue, type: progress.goalType))
                    .fontWeight(.semibold)
                +
                Text(" / ")
                    .foregroundStyle(.secondary)
                +
                Text(formattedValue(progress.targetValue, type: progress.goalType))
                    .foregroundStyle(.secondary)

                Spacer()

                if progress.daysRemaining > 0 {
                    Text("\(progress.daysRemaining) days left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Deadline passed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .font(.subheadline)

            // Pacing hint
            if progress.daysRemaining > 0 && progress.currentValue < progress.targetValue {
                Text(pacingHint(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Projection
            if progress.daysRemaining > 0 {
                Text("On pace for \(formattedValue(progress.projectedCompletion, type: progress.goalType)) of \(formattedValue(progress.targetValue, type: progress.goalType)) target")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Actions
            HStack(spacing: 12) {
                Spacer()

                Button {
                    if let goal = try? goalRepo.fetchActive().first(where: { $0.id == progress.goalID }) {
                        editingGoal = goal
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    archiveGoal(progress.goalID)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "target")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No goals set")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Tap + to create your first business goal.")
                .font(.body)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private func refreshProgress() {
        progressItems = engine.computeAllProgress()
    }

    private func archiveGoal(_ id: UUID) {
        try? goalRepo.archive(id: id)
        refreshProgress()
    }

    private func formattedValue(_ value: Double, type: GoalType) -> String {
        if type.isCurrency {
            if value >= 1_000_000 {
                return String(format: "$%.1fM", value / 1_000_000)
            } else if value >= 1_000 {
                return String(format: "$%.0fK", value / 1_000)
            } else {
                return String(format: "$%.0f", value)
            }
        } else if type == .deepWorkHours {
            return String(format: "%.1f", value)
        } else {
            return "\(Int(value))"
        }
    }

    private func pacingHint(_ progress: GoalProgress) -> String {
        let type = progress.goalType
        let remaining = max(progress.targetValue - progress.currentValue, 0)
        let days = Double(max(progress.daysRemaining, 1))

        let perDay = remaining / days
        let perWeek = remaining / (days / 7.0)
        let perMonth = remaining / (days / 30.0)

        // Pick the smallest time unit where the rate is >= 1
        if perDay >= 1 {
            return "Need \(formattedValue(perDay, type: type)) per day to finish on time"
        } else if perWeek >= 1 {
            return "Need \(formattedValue(perWeek, type: type)) per week to finish on time"
        } else {
            return "Need \(formattedValue(perMonth, type: type)) per month to finish on time"
        }
    }
}
