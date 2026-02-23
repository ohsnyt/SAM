//
//  OutcomeCardView.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  Reusable card for displaying a single coaching outcome.
//

import SwiftUI

struct OutcomeCardView: View {

    let outcome: SamOutcome
    let onAct: (() -> Void)?
    let onDone: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Kind badge + priority dot
            HStack(spacing: 8) {
                priorityDot
                kindBadge
                Spacer()
                if let deadline = outcome.deadlineDate {
                    deadlineLabel(deadline)
                }
            }

            // Title
            Text(outcome.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            // Rationale
            Text(outcome.rationale)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            // Suggested next step
            if let step = outcome.suggestedNextStep, !step.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text(step)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .italic()
                        .lineLimit(2)
                }
                .padding(.top, 2)
            }

            // Encouragement note
            if let note = outcome.encouragementNote, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.top, 1)
            }

            // Action buttons
            HStack {
                Spacer()

                if let onAct {
                    Button(action: onAct) {
                        Label(outcome.outcomeKind.actionLabel, systemImage: outcome.outcomeKind.actionIcon)
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if onAct != nil {
                    Button(action: onDone) {
                        Label("Done", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button(action: onDone) {
                        Label("Done", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button(action: onSkip) {
                    Label("Skip", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(kindColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Subviews

    private var priorityDot: some View {
        Circle()
            .fill(priorityColor)
            .frame(width: 8, height: 8)
    }

    private var kindBadge: some View {
        Text(outcome.outcomeKind.displayName.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(kindColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(kindColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private func deadlineLabel(_ date: Date) -> some View {
        let remaining = date.timeIntervalSince(.now)
        let text: String
        if remaining <= 0 {
            text = "Overdue"
        } else if remaining < 3600 {
            text = "\(Int(remaining / 60))m left"
        } else if remaining < 86400 {
            text = "\(Int(remaining / 3600))h left"
        } else {
            text = "\(Int(remaining / 86400))d left"
        }

        return Text(text)
            .font(.caption2)
            .foregroundStyle(remaining <= 0 ? .red : remaining < 86400 ? .orange : .secondary)
    }

    // MARK: - Colors

    private var priorityColor: Color {
        let score = outcome.priorityScore
        if score >= 0.7 { return .red }
        if score >= 0.4 { return .yellow }
        return .green
    }

    private var kindColor: Color {
        outcome.outcomeKind.themeColor
    }
}

// MARK: - OutcomeKind Display Extensions

extension OutcomeKind {
    var displayName: String {
        switch self {
        case .preparation: return "Preparation"
        case .followUp:    return "Follow-Up"
        case .proposal:    return "Proposal"
        case .outreach:    return "Outreach"
        case .growth:      return "Growth"
        case .training:    return "Training"
        case .compliance:  return "Compliance"
        }
    }

    var themeColor: Color {
        switch self {
        case .preparation: return .blue
        case .followUp:    return .orange
        case .proposal:    return .purple
        case .outreach:    return .teal
        case .growth:      return .green
        case .training:    return .indigo
        case .compliance:  return .red
        }
    }

    var icon: String {
        switch self {
        case .preparation: return "doc.text.magnifyingglass"
        case .followUp:    return "arrow.uturn.backward.circle"
        case .proposal:    return "doc.richtext"
        case .outreach:    return "hand.wave"
        case .growth:      return "chart.line.uptrend.xyaxis"
        case .training:    return "book"
        case .compliance:  return "checkmark.shield"
        }
    }
}
