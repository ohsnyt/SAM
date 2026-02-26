//
//  GoalPacingSection.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase X: Goal Setting & Decomposition
//
//  Compact goal pacing cards for the Today's Focus group in AwarenessView.
//

import SwiftUI

struct GoalPacingSection: View {

    @State private var progressItems: [GoalProgress] = []

    private var engine: GoalProgressEngine { GoalProgressEngine.shared }

    /// Prioritized: atRisk first, then behind, then nearest deadline. Max 3.
    private var prioritizedItems: [GoalProgress] {
        let sorted = progressItems.sorted { a, b in
            let aWeight = paceWeight(a.pace)
            let bWeight = paceWeight(b.pace)
            if aWeight != bWeight { return aWeight > bWeight }
            return a.daysRemaining < b.daysRemaining
        }
        return Array(sorted.prefix(3))
    }

    var body: some View {
        if !progressItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .foregroundStyle(.secondary)
                    Text("Goal Pacing")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 10)

                // Compact goal cards
                VStack(spacing: 6) {
                    ForEach(prioritizedItems) { item in
                        compactGoalCard(item)
                    }
                }
                .padding(.horizontal)

                // "View all" link if more than 3
                if progressItems.count > 3 {
                    Text("View all \(progressItems.count) goals →")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.horizontal)
                }

                Divider()
                    .padding(.top, 6)
            }
            .task {
                progressItems = engine.computeAllProgress()
            }
        }
    }

    // MARK: - Compact Card

    private func compactGoalCard(_ progress: GoalProgress) -> some View {
        HStack(spacing: 10) {
            Image(systemName: progress.goalType.icon)
                .foregroundStyle(progress.goalType.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(progress.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                // Mini progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 4)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(progress.pace.color)
                            .frame(width: geo.size.width * progress.percentComplete, height: 4)
                    }
                }
                .frame(height: 4)
            }

            Spacer()

            // Pace badge
            Text(progress.pace.displayName)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(progress.pace.color)
                .clipShape(Capsule())
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func paceWeight(_ pace: GoalPace) -> Int {
        switch pace {
        case .atRisk:  return 3
        case .behind:  return 2
        case .onTrack: return 1
        case .ahead:   return 0
        }
    }
}
