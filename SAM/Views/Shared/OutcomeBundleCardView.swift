//
//  OutcomeBundleCardView.swift
//  SAM
//
//  Card for one per-person OutcomeBundle. Shows each open sub-item with
//  tick / skip buttons. When ≥1 sub-items target the same person, the
//  bundle is a single notification (not N) — completion is granular.
//

import SwiftUI

struct OutcomeBundleCardView: View {

    let bundle: OutcomeBundle
    var isHero: Bool = false

    /// When true, render a compact ≤2-line summary instead of the full card.
    /// The whole compact card is tappable and invokes `onExpand`.
    var collapsed: Bool = false
    /// Invoked when the user taps a collapsed card to expand it.
    var onExpand: (() -> Void)?

    /// Tick a single sub-item (user did this topic).
    let onTick: (OutcomeSubItem) -> Void
    /// Skip a single sub-item (user doesn't want to act on this topic now).
    let onSkip: (OutcomeSubItem) -> Void
    /// Open person detail.
    var onOpenPerson: (() -> Void)?
    /// Compose combined message from the bundle's draft.
    var onCompose: (() -> Void)?

    private var personName: String {
        bundle.person?.displayNameCache
            ?? bundle.person?.displayName
            ?? "Unknown"
    }

    private var roleBadge: String? {
        bundle.person?.roleBadges.first
    }

    private var openItems: [OutcomeSubItem] {
        bundle.openSubItems
    }

    private var topicGroupCount: Int {
        Set(openItems.map { $0.kind.topicGroup }).count
    }

    /// Border accent: person's role color (falls back to blue when unknown).
    private var accentColor: Color {
        if let role = bundle.person?.roleBadges.first {
            return RoleBadgeStyle.forBadge(role).color
        }
        return .blue
    }

    var body: some View {
        if collapsed {
            collapsedBody
        } else {
            expandedBody
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            lastTouchStrip
            if openItems.isEmpty {
                Text("No open topics.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(openItems, id: \.id) { item in
                        subItemRow(item)
                    }
                }
            }
            if let draft = bundle.combinedDraftMessage, !draft.isEmpty {
                combinedDraftSection(draft)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accentColor.opacity(0.5), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isHero {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 4)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Collapsed Body (2-line scannable summary)

    private var collapsedBody: some View {
        Button(action: { onExpand?() }) {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: priority dot + name + role + count + deadline
                HStack(spacing: 8) {
                    priorityDot
                    Text(personName)
                        .samFont(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    if let role = roleBadge {
                        Text(role)
                            .samFont(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(openItems.count) \(openItems.count == 1 ? "item" : "items")")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    if let due = bundle.nearestDueDate {
                        deadlineLabel(due)
                    }
                }
                // Line 2: top item title (truncated)
                if let first = openItems.first {
                    Text(first.title)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.tertiary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accentColor.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            priorityDot
            Button(action: { onOpenPerson?() }) {
                HStack(spacing: 6) {
                    Text(personName)
                        .font(isHero ? .title3.bold() : .headline)
                        .foregroundStyle(.primary)
                    if let role = roleBadge {
                        Text(role)
                            .samFont(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if topicGroupCount >= 2 {
                Label("\(openItems.count) topics", systemImage: "square.stack.3d.up.fill")
                    .samFont(.caption)
                    .foregroundStyle(.blue)
                    .help("This bundle covers \(topicGroupCount) distinct topic groups")
            }

            if let due = bundle.nearestDueDate {
                deadlineLabel(due)
            }
        }
    }

    private var priorityDot: some View {
        let p = bundle.priorityScore
        let color: Color = p >= 0.8 ? .red : (p >= 0.6 ? .orange : (p >= 0.4 ? .yellow : .green))
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help("Priority \(Int(p * 100))")
    }

    // MARK: - Last-Touch Strip

    @ViewBuilder
    private var lastTouchStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .samFont(.caption)
                .foregroundStyle(.secondary)
            Text(lastTouchText)
                .samFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var lastTouchText: String {
        if let summary = bundle.lastTouchSummary, !summary.isEmpty {
            return summary
        }
        return "No prior tracked contact — first exchange"
    }

    private func deadlineLabel(_ date: Date) -> some View {
        let remaining = date.timeIntervalSince(.now)
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 0

        let text: String
        if days < 0 {
            text = "Overdue"
        } else if days == 0 {
            // Show hours-left when same-day so it reads like "5h left" not just "Today"
            if remaining < 3600 {
                text = "\(max(0, Int(remaining / 60)))m left"
            } else {
                text = "\(Int(remaining / 3600))h left"
            }
        } else if days == 1 {
            text = "Tomorrow"
        } else if days <= 7 {
            text = "in \(days)d"
        } else {
            text = date.formatted(date: .abbreviated, time: .omitted)
        }

        // Time-critical: <60h gets a prominent orange pill so weekend deadlines pop.
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
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sub-item Row

    private func subItemRow(_ item: OutcomeSubItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: item.kind))
                        .samFont(.caption)
                        .foregroundStyle(iconColor(for: item.kind))
                        .frame(width: 14)
                    Text(item.title)
                        .samFont(.subheadline)
                        .foregroundStyle(.primary)
                    if item.isMilestone {
                        Text("milestone")
                            .samFont(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.2), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }
                if !item.rationale.isEmpty {
                    Text(item.rationale)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 20)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Button {
                    onTick(item)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .samFont(.title3)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Done")

                Button {
                    onSkip(item)
                } label: {
                    Image(systemName: "xmark.circle")
                        .samFont(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Skip")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
        )
    }

    // MARK: - Combined Draft

    private func combinedDraftSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .samFont(.caption)
                    .foregroundStyle(.blue)
                Text("Combined draft")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    ClipboardSecurity.copy(text, clearAfter: 60)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .samFont(.caption)
                }
                .buttonStyle(.plain)
                .help("Copy draft")

                if onCompose != nil {
                    Button {
                        onCompose?()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .samFont(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Compose")
                }
            }
            Text(text)
                .samFont(.subheadline)
                .foregroundStyle(.primary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.blue.opacity(0.08))
                )
        }
    }

    // MARK: - Icons

    private func iconName(for kind: OutcomeSubItemKind) -> String {
        switch kind {
        case .cadenceReconnect: return "phone.arrow.up.right"
        case .birthday:         return "gift.fill"
        case .anniversary:      return "heart.fill"
        case .annualReview:     return "doc.text.fill"
        case .lifeEventTouch:   return "star.fill"
        case .stewardshipArc:   return "checkerboard.shield"
        case .stalledPipeline:  return "exclamationmark.triangle.fill"
        case .openCommitment:   return "hand.raised.fill"
        case .openActionItem:   return "checklist"
        case .proposalPrep:     return "doc.plaintext.fill"
        case .recruitTouch:     return "person.crop.circle.badge.plus"
        }
    }

    private func iconColor(for kind: OutcomeSubItemKind) -> Color {
        switch kind {
        case .birthday, .anniversary:           return .pink
        case .lifeEventTouch:                   return .yellow
        case .stewardshipArc, .cadenceReconnect: return .blue
        case .stalledPipeline:                  return .orange
        case .openCommitment, .openActionItem:  return .purple
        case .proposalPrep, .annualReview:      return .green
        case .recruitTouch:                     return .teal
        }
    }
}
