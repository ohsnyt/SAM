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
import AppKit

struct OutcomeCardView: View {

    let outcome: SamOutcome
    let onAct: (() -> Void)?
    let onDone: () -> Void
    let onSkip: () -> Void

    /// Total steps in the sequence (injected by parent or computed).
    var sequenceStepCount: Int = 0
    /// The next awaiting step in the sequence (for hint text).
    var nextAwaitingStep: SamOutcome?

    @State private var copiedStep = false

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

            // Sequence indicator
            if outcome.sequenceID != nil, sequenceStepCount > 1 {
                sequenceIndicator
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

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(step, forType: .string)
                        copiedStep = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedStep = false
                        }
                    } label: {
                        Image(systemName: copiedStep ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(copiedStep ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy suggested step")
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
                        Label(outcome.actionLane.actionLabel, systemImage: outcome.actionLane.actionIcon)
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

    // MARK: - Sequence Indicator

    private var sequenceIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Step \(outcome.sequenceIndex + 1) of \(sequenceStepCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let next = nextAwaitingStep, outcome.sequenceIndex < next.sequenceIndex {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                let channelName = next.suggestedChannel?.displayName ?? "follow-up"
                let conditionText = next.triggerCondition?.displayName.lowercased() ?? ""
                let daysText = next.triggerAfterDays > 0 ? "in \(next.triggerAfterDays)d" : ""

                Text("Then: \(channelName) \(daysText) \(conditionText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if outcome.sequenceIndex > 0 {
                // This is an activated follow-up step
                let conditionLabel = outcome.triggerCondition == .noResponse ? "(no response received)" : ""
                if !conditionLabel.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Follow-up \(conditionLabel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
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
        case .training:        return "Training"
        case .compliance:      return "Compliance"
        case .contentCreation: return "Content"
        }
    }

    var themeColor: Color {
        switch self {
        case .preparation: return .blue
        case .followUp:    return .orange
        case .proposal:    return .purple
        case .outreach:    return .teal
        case .growth:      return .green
        case .training:        return .indigo
        case .compliance:      return .red
        case .contentCreation: return .mint
        }
    }

    var icon: String {
        switch self {
        case .preparation: return "doc.text.magnifyingglass"
        case .followUp:    return "arrow.uturn.backward.circle"
        case .proposal:    return "doc.richtext"
        case .outreach:    return "hand.wave"
        case .growth:      return "chart.line.uptrend.xyaxis"
        case .training:        return "book"
        case .compliance:      return "checkmark.shield"
        case .contentCreation: return "text.badge.star"
        }
    }
}
