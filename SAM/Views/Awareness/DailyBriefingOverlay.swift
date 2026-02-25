//
//  DailyBriefingOverlay.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Daily Briefing System
//
//  Full morning briefing shown as .sheet on first open of the day.
//

import SwiftUI

struct DailyBriefingOverlay: View {

    private var coordinator: DailyBriefingCoordinator { DailyBriefingCoordinator.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                greetingHeader

                if let briefing = coordinator.morningBriefing {
                    // Weekly priorities (Monday mornings)
                    if !briefing.weeklyPriorities.isEmpty {
                        weeklyPrioritiesSection(briefing.weeklyPriorities)
                    }

                    // AI narrative (if available)
                    if let narrative = briefing.narrativeSummary, !narrative.isEmpty {
                        narrativeSection(narrative)
                    }

                    // Calendar timeline
                    if !briefing.calendarItems.isEmpty {
                        calendarSection(briefing.calendarItems)
                    }

                    // Priority actions
                    if !briefing.priorityActions.isEmpty {
                        actionsSection(briefing.priorityActions)
                    }

                    // Follow-ups
                    if !briefing.followUps.isEmpty {
                        followUpSection(briefing.followUps)
                    }

                    // Life events
                    if !briefing.lifeEventOutreach.isEmpty {
                        lifeEventsSection(briefing.lifeEventOutreach)
                    }

                    // Tomorrow preview
                    if !briefing.tomorrowPreview.isEmpty {
                        tomorrowSection(briefing.tomorrowPreview)
                    }
                }

                // Dismiss button
                Button(action: {
                    coordinator.markMorningViewed()
                }) {
                    Text("Start My Day")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding(32)
        }
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 700,
               minHeight: 400, idealHeight: 600, maxHeight: 800)
    }

    // MARK: - Header

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(greetingText)
                .font(.title)
                .fontWeight(.bold)

            Text(Date.now.formatted(date: .complete, time: .omitted))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    // MARK: - Weekly Priorities

    private func weeklyPrioritiesSection(_ priorities: [BriefingAction]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("This Week's Priorities", icon: "star.fill", count: priorities.count)

            ForEach(Array(priorities.enumerated()), id: \.element.id) { index, priority in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.purple)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(priority.title)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if let rationale = priority.rationale, !rationale.isEmpty {
                            Text(rationale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let person = priority.personName {
                            Text(person)
                                .font(.caption)
                                .foregroundStyle(.purple)
                        }
                    }

                    Spacer()

                    urgencyBadge(priority.urgency)
                }
            }
        }
        .padding()
        .background(Color.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func urgencyBadge(_ urgency: String) -> some View {
        Text(urgency.capitalized)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(urgencyColor(urgency).opacity(0.15))
            .foregroundStyle(urgencyColor(urgency))
            .clipShape(Capsule())
    }

    // MARK: - Narrative

    private func narrativeSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Calendar

    private func calendarSection(_ items: [BriefingCalendarItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Today's Schedule", icon: "calendar", count: items.count)

            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    // Time column
                    VStack(alignment: .trailing) {
                        Text(item.startsAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                        if let end = item.endsAt {
                            Text(end.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 60, alignment: .trailing)

                    // Timeline bar
                    Rectangle()
                        .fill(healthColor(item.healthStatus))
                        .frame(width: 3)
                        .clipShape(Capsule())

                    // Content
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.eventTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if !item.attendeeNames.isEmpty {
                            Text(item.attendeeNames.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let prep = item.preparationNote, !prep.isEmpty {
                            Text(prep)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func actionsSection(_ actions: [BriefingAction]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Priority Actions", icon: "checklist", count: actions.count)

            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(urgencyColor(action.urgency))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .font(.subheadline)

                        if let person = action.personName {
                            Text(person)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Follow-ups

    private func followUpSection(_ followUps: [BriefingFollowUp]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Follow-ups Needed", icon: "person.2", count: followUps.count)

            ForEach(followUps) { followUp in
                HStack(spacing: 12) {
                    Image(systemName: "person.circle")
                        .font(.title3)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(followUp.personName)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text(followUp.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(followUp.daysSinceInteraction)d")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Life Events

    private func lifeEventsSection(_ events: [BriefingLifeEvent]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Life Events", icon: "heart.fill", count: events.count)

            ForEach(events) { event in
                HStack(spacing: 12) {
                    Image(systemName: "gift.fill")
                        .font(.title3)
                        .foregroundStyle(.pink)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(event.personName) — \(event.eventDescription)")
                            .font(.subheadline)

                        if let suggestion = event.outreachSuggestion {
                            Text(suggestion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Tomorrow

    private func tomorrowSection(_ items: [BriefingCalendarItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Tomorrow", icon: "arrow.right.circle", count: items.count)

            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.startsAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)

                    Text(item.eventTitle)
                        .font(.subheadline)

                    if !item.attendeeNames.isEmpty {
                        Text("(\(item.attendeeNames.joined(separator: ", ")))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
    }

    private func healthColor(_ status: String?) -> Color {
        switch status {
        case "cold":    return .red
        case "at_risk": return .orange
        default:        return .green
        }
    }

    private func urgencyColor(_ urgency: String) -> Color {
        switch urgency {
        case "immediate": return .red
        case "soon":      return .orange
        default:          return .blue
        }
    }
}
