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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
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
                .strokeBorder(.separator, lineWidth: 0.5)
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

    private func deadlineLabel(_ date: Date) -> some View {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 0
        let text: String
        let color: Color
        if days < 0 {
            text = "Overdue"
            color = .red
        } else if days == 0 {
            text = "Today"
            color = .orange
        } else if days == 1 {
            text = "Tomorrow"
            color = .orange
        } else if days <= 7 {
            text = "in \(days)d"
            color = .secondary
        } else {
            text = date.formatted(date: .abbreviated, time: .omitted)
            color = .secondary
        }
        return Text(text)
            .samFont(.caption)
            .foregroundStyle(color)
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
