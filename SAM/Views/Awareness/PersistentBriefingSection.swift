//
//  PersistentBriefingSection.swift
//  SAM
//
//  Created by Assistant on 3/4/26.
//  Phase 1: Today View Declutter
//
//  Persistent inline briefing at the top of AwarenessView.
//  Shows greeting immediately, progress bar while generating, then narrative
//  + checkable rows for calendar, follow-ups, and life events.
//  Priority actions are NOT shown here — they appear as outcome cards in Zone 2.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PersistentBriefingSection")

struct PersistentBriefingSection: View {

    private var coordinator: DailyBriefingCoordinator { DailyBriefingCoordinator.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Greeting is always visible
            greetingHeader
                .padding([.horizontal, .top])
                .padding(.bottom, 8)

            if coordinator.generationStatus == .generating {
                progressSection
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }

            if let briefing = coordinator.morningBriefing {
                briefingContent(briefing)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            } else if coordinator.generationStatus != .generating {
                Text("Your briefing will appear here once SAM has enough data.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Greeting (always visible)

    private var greetingHeader: some View {
        HStack {
            Text(timeOfDayGreeting)
                .font(.largeTitle)
                .fontWeight(.bold)

            Spacer()

            if let briefing = coordinator.morningBriefing {
                Text("Updated \(briefing.generatedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case ..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:     return "Good evening"
        }
    }

    // MARK: - Progress Section

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: coordinator.generationProgress)
                .tint(.blue)

            Text(coordinator.generationStageLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Briefing Content

    @ViewBuilder
    private func briefingContent(_ briefing: SamDailyBriefing) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // AI narrative
            if let narrative = briefing.narrativeSummary, !narrative.isEmpty {
                Text(narrative)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            // All-done banner
            if coordinator.allItemsChecked {
                allDoneBanner
            }

            // Schedule
            if !briefing.calendarItems.isEmpty {
                checkableSection(
                    title: "Schedule",
                    icon: "calendar",
                    color: .blue
                ) {
                    ForEach(briefing.calendarItems) { item in
                        calendarRow(item)
                    }
                }
            }

            // Follow-ups
            if !briefing.followUps.isEmpty {
                checkableSection(
                    title: "Follow-ups",
                    icon: "arrow.turn.up.right",
                    color: .purple
                ) {
                    ForEach(briefing.followUps) { followUp in
                        followUpRow(followUp)
                    }
                }
            }

            // Life events
            if !briefing.lifeEventOutreach.isEmpty {
                checkableSection(
                    title: "Life Events",
                    icon: "gift.fill",
                    color: .pink
                ) {
                    ForEach(briefing.lifeEventOutreach) { event in
                        lifeEventRow(event)
                    }
                }
            }
        }
    }

    // MARK: - Checkable Section Container

    @ViewBuilder
    private func checkableSection<Content: View>(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            content()
        }
    }

    // MARK: - Calendar Row

    private func calendarRow(_ item: BriefingCalendarItem) -> some View {
        let itemID = item.id.uuidString
        let checked = coordinator.isItemChecked(itemID)

        return Button(action: {
            if checked {
                coordinator.markItemUnchecked(itemID)
            } else {
                coordinator.markItemChecked(itemID)
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(checked ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.eventTitle)
                        .font(.subheadline)
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? .secondary : .primary)

                    HStack(spacing: 6) {
                        Text(item.startsAt, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !item.attendeeNames.isEmpty {
                            Text(item.attendeeNames.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if let health = item.healthStatus {
                    healthDot(health)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Follow-Up Row

    private func followUpRow(_ followUp: BriefingFollowUp) -> some View {
        let itemID = followUp.id.uuidString
        let checked = coordinator.isItemChecked(itemID)

        return Button(action: {
            if checked {
                coordinator.markItemUnchecked(itemID)
            } else {
                coordinator.markItemChecked(itemID)
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(checked ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(followUp.personName)
                        .font(.subheadline)
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? .secondary : .primary)

                    Text(followUp.reason)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if followUp.daysSinceInteraction > 0 {
                    Text("\(followUp.daysSinceInteraction)d")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Life Event Row

    private func lifeEventRow(_ event: BriefingLifeEvent) -> some View {
        let itemID = event.id.uuidString
        let checked = coordinator.isItemChecked(itemID)

        return Button(action: {
            if checked {
                coordinator.markItemUnchecked(itemID)
            } else {
                coordinator.markItemChecked(itemID)
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(checked ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(event.personName) — \(event.eventDescription)")
                        .font(.subheadline)
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? .secondary : .primary)

                    if let suggestion = event.outreachSuggestion, !suggestion.isEmpty {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Supporting Views

    private func healthDot(_ status: String) -> some View {
        Circle()
            .fill(healthColor(status))
            .frame(width: 8, height: 8)
    }

    private func healthColor(_ status: String) -> Color {
        switch status {
        case "healthy": return .green
        case "at_risk": return .orange
        case "cold":    return .red
        default:        return .gray
        }
    }

    private var allDoneBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("All done for today!")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
