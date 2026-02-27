//
//  StrategicActionSheet.swift
//  SAM
//
//  Created on February 27, 2026.
//  Strategic Action Coaching Flow — Phase B
//
//  Sheet presented when the user clicks "Act" on a strategic recommendation.
//  Shows implementation approaches and offers planning help.
//

import SwiftUI

struct StrategicActionSheet: View {

    let recommendation: StrategicRec
    let onFeedback: (RecommendationFeedback) -> Void
    let onPlanApproach: (StrategicRec, ImplementationApproach?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            headerSection

            Divider()

            // Approaches
            if recommendation.approaches.isEmpty {
                emptyApproachesSection
            } else {
                approachesSection
            }

            Divider()

            // Footer actions
            footerActions
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                categoryBadge(recommendation.category)
                Spacer()
                priorityIndicator(recommendation.priority)
            }

            Text(recommendation.title)
                .font(.title3)
                .fontWeight(.semibold)

            Text(recommendation.rationale)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Approaches

    private var approachesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How would you like to approach this?")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(recommendation.approaches) { approach in
                approachCard(approach)
            }
        }
    }

    private func approachCard(_ approach: ImplementationApproach) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(approach.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                effortBadge(approach.effort)
            }

            Text(approach.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !approach.steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(approach.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\u{2022}")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(step)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    onPlanApproach(recommendation, approach)
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Text("Plan This")
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Empty Approaches Fallback

    private var emptyApproachesSection: some View {
        VStack(spacing: 12) {
            Text("Want help planning how to tackle this?")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                onPlanApproach(recommendation, nil)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                    Text("Get Planning Help")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack {
            Button("Mark as Done") {
                onFeedback(.actedOn)
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()

            Button("Dismiss") {
                onFeedback(.dismissed)
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(.secondary)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Helpers

    private func categoryBadge(_ category: String) -> some View {
        Text(category.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(categoryColor(category).opacity(0.15), in: Capsule())
            .foregroundStyle(categoryColor(category))
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "pipeline": return .blue
        case "time": return .orange
        case "pattern": return .purple
        case "content": return .green
        default: return .secondary
        }
    }

    private func priorityIndicator(_ priority: Double) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(priorityColor(priority))
                .frame(width: 6, height: 6)
            Text(priorityLabel(priority))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func priorityColor(_ priority: Double) -> Color {
        if priority >= 0.7 { return .red }
        if priority >= 0.4 { return .orange }
        return .green
    }

    private func priorityLabel(_ priority: Double) -> String {
        if priority >= 0.7 { return "High Priority" }
        if priority >= 0.4 { return "Medium Priority" }
        return "Low Priority"
    }

    private func effortBadge(_ effort: EffortLevel) -> some View {
        Text(effortLabel(effort))
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(effortColor(effort).opacity(0.15), in: Capsule())
            .foregroundStyle(effortColor(effort))
    }

    private func effortColor(_ effort: EffortLevel) -> Color {
        switch effort {
        case .quick: return .green
        case .moderate: return .orange
        case .substantial: return .red
        }
    }

    private func effortLabel(_ effort: EffortLevel) -> String {
        switch effort {
        case .quick: return "Quick"
        case .moderate: return "Moderate"
        case .substantial: return "Substantial"
        }
    }
}
