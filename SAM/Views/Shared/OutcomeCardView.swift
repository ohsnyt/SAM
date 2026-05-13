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
    var isHero: Bool = false
    let onAct: (() -> Void)?
    let onDone: () -> Void
    let onSkip: () -> Void
    var onSnooze: ((Date) -> Void)?
    var onMuteKind: (() -> Void)?

    /// Total steps in the sequence (injected by parent or computed).
    var sequenceStepCount: Int = 0
    /// The next awaiting step in the sequence (for hint text).
    var nextAwaitingStep: SamOutcome?
    /// Optional guide article ID for "Learn more" link (e.g., feature adoption outcomes).
    var guideArticleID: String?

    /// When true, render a compact 2-line summary instead of the full card.
    /// The whole compact card is tappable when `onExpand` is non-nil.
    var collapsed: Bool = false
    /// Invoked when the user taps a collapsed card to expand it.
    var onExpand: (() -> Void)?

    @State private var copiedStep = false
    @State private var copiedAll = false
    @State private var showSnoozePicker = false
    @State private var snoozeDate = Calendar.current.date(byAdding: .day, value: 1, to: .now)!

    /// Compliance flags for any AI-generated draft on this outcome.
    private var draftComplianceFlags: [ComplianceFlag] {
        guard let draft = outcome.draftMessageText, !draft.isEmpty else { return [] }
        return ComplianceScanner.scanWithSettings(draft)
    }

    var body: some View {
        if collapsed {
            collapsedBody
        } else {
            expandedBody
        }
    }

    // MARK: - Collapsed Body (2-line scannable summary)

    private var collapsedBody: some View {
        Button(action: { onExpand?() }) {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: priority dot + kind badge + (person or kind label) + deadline
                HStack(spacing: 8) {
                    priorityDot
                    kindBadge
                    Spacer()
                    if let deadline = outcome.deadlineDate {
                        deadlineLabel(deadline)
                    }
                }
                // Line 2: title (truncated)
                Text(outcome.title)
                    .samFont(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onExpand == nil)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accentColor.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Expanded Body (full card)

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Kind badge + priority dot
            HStack(spacing: 8) {
                priorityDot
                kindBadge
                if !draftComplianceFlags.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .samFont(.caption2)
                        .foregroundStyle(.orange)
                        .help("Draft contains \(draftComplianceFlags.count) compliance-sensitive phrase\(draftComplianceFlags.count == 1 ? "" : "s")")
                }
                Spacer()
                if let deadline = outcome.deadlineDate {
                    deadlineLabel(deadline)
                }
            }

            // Sequence indicator
            if outcome.sequenceID != nil, sequenceStepCount > 1 {
                sequenceIndicator
            }

            // Companion indicator
            companionIndicator

            // Linked person name (clickable → navigates to People view)
            personLink

            // Title
            Text(outcome.title)
                .font(isHero ? .title3.bold() : .headline)
                .foregroundStyle(.primary)
                .lineLimit(2)

            // Rationale
            Text(outcome.rationale)
                .font(isHero ? .body : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(isHero ? 5 : 3)

            // Suggested next step
            if let step = outcome.suggestedNextStep, !step.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .samFont(.caption)
                        .foregroundStyle(.blue)
                    Text(step)
                        .samFont(.caption)
                        .foregroundStyle(.blue)
                        .italic()
                        .lineLimit(isHero ? 3 : 2)

                    Spacer()

                    Button {
                        ClipboardSecurity.copy(step, clearAfter: 60)
                        copiedStep = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copiedStep = false }
                    } label: {
                        Image(systemName: copiedStep ? "checkmark" : "doc.on.doc")
                            .samFont(.caption2)
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
                    .samFont(.caption2)
                    .foregroundStyle(.green)
                    .padding(.top, 1)
            }

            // Guide link for feature adoption outcomes
            if let articleID = guideArticleID {
                Button {
                    GuideContentService.shared.navigateTo(articleID: articleID)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "book.pages")
                            .samFont(.caption2)
                        Text("Learn more")
                            .samFont(.caption2)
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            // Action buttons
            HStack {
                Spacer()

                if let onAct {
                    Button(action: onAct) {
                        Label(actionButtonLabel, systemImage: actionButtonIcon)
                            .samFont(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(isHero ? .regular : .small)
                }

                if onAct != nil {
                    Button(action: onDone) {
                        Label("Done", systemImage: "checkmark.circle")
                            .samFont(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(isHero ? .regular : .small)
                } else {
                    Button(action: onDone) {
                        Label("Done", systemImage: "checkmark.circle")
                            .samFont(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(isHero ? .regular : .small)
                }

                if onSnooze != nil {
                    Button {
                        showSnoozePicker = true
                    } label: {
                        Label("Snooze", systemImage: "moon.zzz")
                            .samFont(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(isHero ? .regular : .small)
                    .popover(isPresented: $showSnoozePicker) {
                        SnoozePickerView(date: $snoozeDate) {
                            onSnooze?(snoozeDate)
                            showSnoozePicker = false
                        }
                    }
                }

                Button(action: onSkip) {
                    Label("Skip", systemImage: "xmark.circle")
                        .samFont(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(isHero ? .regular : .small)
                .contextMenu {
                    Button {
                        onMuteKind?()
                        onSkip()
                    } label: {
                        Label("Stop suggesting \(outcome.outcomeKind.displayName.lowercased())", systemImage: "speaker.slash")
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accentColor.opacity(0.5), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isHero {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 4)
                    .padding(.vertical, 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if copiedAll {
                Text("Copied")
                    .samFont(.caption2)
                    .foregroundStyle(.green)
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .contextMenu {
            Button {
                ClipboardSecurity.copy(outcomeTextForCopy, clearAfter: 120)
                copiedAll = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copiedAll = false }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            if outcome.draftMessageText != nil && outcome.actionLane != .openURL {
                Button {
                    ClipboardSecurity.copy(outcome.draftMessageText ?? "", clearAfter: 120)
                    copiedAll = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copiedAll = false }
                } label: {
                    Label("Copy Draft Message", systemImage: "text.bubble")
                }
            }
        }
    }

    /// Assembles all visible text from the outcome for clipboard copy.
    private var outcomeTextForCopy: String {
        var parts: [String] = []
        parts.append("[\(outcome.outcomeKind.displayName.uppercased())] \(outcome.title)")
        parts.append(outcome.rationale)
        if let step = outcome.suggestedNextStep, !step.isEmpty {
            parts.append("Next step: \(step)")
        }
        if let note = outcome.encouragementNote, !note.isEmpty {
            parts.append(note)
        }
        if let draft = outcome.draftMessageText, !draft.isEmpty, outcome.actionLane != .openURL {
            parts.append("Draft message:\n\(draft)")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Person Link

    @ViewBuilder
    private var personLink: some View {
        if let person = outcome.linkedPerson {
            let name = person.displayNameCache ?? person.displayName
            Button {
                NotificationCenter.default.post(
                    name: .samNavigateToPerson,
                    object: nil,
                    userInfo: ["personID": person.id]
                )
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.circle")
                        .samFont(.caption)
                        .foregroundStyle(.blue)
                    Text(name)
                        .samFont(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    // MARK: - Companion Indicator

    @ViewBuilder
    private var companionIndicator: some View {
        if outcome.isCompanionOutcome {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .samFont(.caption2)
                    .foregroundStyle(.secondary)
                Text("Heads-up companion")
                    .samFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sequence Indicator

    private var sequenceIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .samFont(.caption2)
                .foregroundStyle(.secondary)

            Text("Step \(outcome.sequenceIndex + 1) of \(sequenceStepCount)")
                .samFont(.caption2)
                .foregroundStyle(.secondary)

            if let next = nextAwaitingStep, outcome.sequenceIndex < next.sequenceIndex {
                Text("·")
                    .samFont(.caption2)
                    .foregroundStyle(.tertiary)

                let channelName = next.suggestedChannel?.displayName ?? "follow-up"
                let conditionText = next.triggerCondition?.displayName.lowercased() ?? ""
                let daysText = next.triggerAfterDays > 0 ? "in \(next.triggerAfterDays)d" : ""

                Text("Then: \(channelName) \(daysText) \(conditionText)")
                    .samFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if outcome.sequenceIndex > 0 {
                // This is an activated follow-up step
                let conditionLabel = outcome.triggerCondition == .noResponse ? "(no response received)" : ""
                if !conditionLabel.isEmpty {
                    Text("·")
                        .samFont(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Follow-up \(conditionLabel)")
                        .samFont(.caption2)
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
            .samFont(.caption2)
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

        // Time-critical: <60h gets a prominent orange pill badge so weekend
        // deadlines (Friday afternoon → Monday morning) are easy to spot.
        let isTimeCritical = remaining < 60 * 3600
        let isOverdue = remaining <= 0

        return Group {
            if isTimeCritical {
                Text(text)
                    .samFont(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((isOverdue ? Color.red : Color.orange).opacity(0.18), in: Capsule())
                    .foregroundStyle(isOverdue ? .red : .orange)
            } else {
                Text(text)
                    .samFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Accent Color (role color for person, neutral for non-person)

    /// Border accent. People cards inherit the linked person's role color;
    /// non-person cards (content, growth, setup, etc.) use a single neutral
    /// blue so they're visually distinguishable at a glance.
    private var accentColor: Color {
        if let role = outcome.linkedPerson?.roleBadges.first {
            return RoleBadgeStyle.forBadge(role).color
        }
        return .blue
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

    /// Content outcomes use their own label; everything else defers to action lane.
    private var actionButtonLabel: String {
        if outcome.outcomeKind == .contentCreation {
            return "Draft Post"
        }
        return outcome.actionLane.actionLabel
    }

    private var actionButtonIcon: String {
        if outcome.outcomeKind == .contentCreation {
            return "text.badge.star"
        }
        return outcome.actionLane.actionIcon
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
        case .setup:           return "Setup"
        case .roleFilling:     return "Recruiting"
        case .userTask:        return "Task"
        case .commitment:      return "Commitment"
        case .clientWithoutStewardship: return "Stewardship"
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
        case .setup:           return .cyan
        case .roleFilling:     return .cyan
        case .userTask:        return .gray
        case .commitment:      return .pink
        case .clientWithoutStewardship: return .indigo
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
        case .setup:           return "gearshape.2"
        case .roleFilling:     return "person.badge.key"
        case .userTask:        return "checklist"
        case .commitment:      return "hand.raised"
        case .clientWithoutStewardship: return "person.crop.circle.badge.checkmark"
        }
    }
}
