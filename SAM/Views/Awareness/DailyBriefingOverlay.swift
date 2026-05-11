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
import AppKit

struct DailyBriefingOverlay: View {

    private var coordinator: DailyBriefingCoordinator { DailyBriefingCoordinator.shared }
    @State private var copiedBriefing = false

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

                    // Calendar timeline — filter out past events
                    let upcoming = briefing.calendarItems.filter {
                        ($0.endsAt ?? $0.startsAt) > Date()
                    }
                    if !upcoming.isEmpty {
                        calendarSection(upcoming)
                    }

                    // Per-Sphere roll-up (Phase 6 — multi-Sphere users only)
                    if !briefing.sphereSections.isEmpty {
                        sphereSectionsBlock(briefing.sphereSections)
                    }

                    // Priority actions
                    if !briefing.priorityActions.isEmpty {
                        actionsSection(briefing.priorityActions)
                    }

                    // Reaching for you (Phase 3g — contactDrivenIgnored)
                    if !briefing.reachingForYou.isEmpty {
                        reachingForYouSection(briefing.reachingForYou)
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

                // Actions
                HStack(spacing: 12) {
                    Button {
                        if let briefing = coordinator.morningBriefing {
                            ClipboardSecurity.copy(briefingTextForCopy(briefing), clearAfter: 120)
                            copiedBriefing = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copiedBriefing = false }
                        }
                    } label: {
                        Label(copiedBriefing ? "Copied" : "Copy Briefing",
                              systemImage: copiedBriefing ? "checkmark" : "doc.on.doc")
                            .samFont(.headline)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        coordinator.markMorningViewed()
                    }) {
                        Text("Start My Day")
                            .samFont(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
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
                .samFont(.title)
                .fontWeight(.bold)

            Text(Date.now.formatted(date: .complete, time: .omitted))
                .samFont(.subheadline)
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
                        .samFont(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.purple)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(priority.title)
                            .samFont(.subheadline)
                            .fontWeight(.medium)

                        if let rationale = priority.rationale, !rationale.isEmpty {
                            Text(rationale)
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let person = priority.personName {
                            Text(person)
                                .samFont(.caption)
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
            .samFont(.caption2)
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
                .samFont(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contextMenu {
                    Button {
                        ClipboardSecurity.copy(text, clearAfter: 120)
                    } label: {
                        Label("Copy Narrative", systemImage: "doc.on.doc")
                    }
                }
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
                            .samFont(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                        if let end = item.endsAt {
                            Text(end.formatted(date: .omitted, time: .shortened))
                                .samFont(.caption2)
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
                            .samFont(.subheadline)
                            .fontWeight(.medium)

                        if !item.attendeeNames.isEmpty {
                            Text(item.attendeeNames.joined(separator: ", "))
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let prep = item.preparationNote, !prep.isEmpty {
                            Text(prep)
                                .samFont(.caption)
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
                        .samFont(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(urgencyColor(action.urgency))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .samFont(.subheadline)

                        if let person = action.personName {
                            Text(person)
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reaching for You (Phase 3g)
    //
    // Distinct from Follow-ups: this surfaces people who have been reaching
    // out to *you* and your outbound has lagged. The framing is "they came
    // to you, you haven't come back yet" — copy and icon deliberately call
    // that out rather than treating it as user-initiated outreach.

    // MARK: - Spheres roll-up (Phase 6)

    private func sphereSectionsBlock(_ sections: [BriefingSphereSection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("By Sphere", icon: "circle.grid.3x3.fill", count: sections.count)

            ForEach(sections) { section in
                let accent = SphereAccentColor(rawValue: section.accentColorRaw)?.color ?? .secondary
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(accent).frame(width: 10, height: 10)
                        Text(section.sphereName)
                            .samFont(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        if section.reachingForYouCount > 0 {
                            Label("\(section.reachingForYouCount)", systemImage: "hand.wave.fill")
                                .samFont(.caption)
                                .foregroundStyle(.indigo)
                        }
                    }
                    if let status = section.trajectoryStatus, !status.isEmpty {
                        Text(status)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !section.topActions.isEmpty {
                        ForEach(section.topActions) { action in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "lightbulb.fill")
                                    .samFont(.caption)
                                    .foregroundStyle(.orange)
                                Text(action.title)
                                    .samFont(.caption)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(.leading, 16)
                        }
                    }
                    if !section.topFollowUps.isEmpty {
                        ForEach(section.topFollowUps) { followUp in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "person.circle")
                                    .samFont(.caption)
                                    .foregroundStyle(.orange)
                                Text(followUp.personName)
                                    .samFont(.caption)
                                    .fontWeight(.medium)
                                Text("· \(followUp.reason)")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 16)
                        }
                    }
                }
                .padding(10)
                .background(accent.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(accent.opacity(0.15), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func reachingForYouSection(_ items: [BriefingReachingForYou]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Reaching for you", icon: "hand.wave.fill", count: items.count)

            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .samFont(.title3)
                        .foregroundStyle(.indigo)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.personName)
                                .samFont(.subheadline)
                                .fontWeight(.medium)

                            if let days = item.daysSinceLastOutbound {
                                Text("· quiet \(days)d")
                                    .samFont(.caption)
                                    .foregroundStyle(.indigo)
                            }
                        }

                        Text(item.suggestedAction)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)

                        if item.inboundCount30 > 0 {
                            Text("\(item.inboundCount30) inbound in last 30 days")
                                .samFont(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color.indigo.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Follow-ups

    private func followUpSection(_ followUps: [BriefingFollowUp]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Follow-ups Needed", icon: "person.2", count: followUps.count)

            ForEach(followUps) { followUp in
                HStack(spacing: 12) {
                    Image(systemName: "person.circle")
                        .samFont(.title3)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(followUp.personName)
                            .samFont(.subheadline)
                            .fontWeight(.medium)

                        Text(followUp.reason)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(followUp.daysSinceInteraction)d")
                        .samFont(.caption)
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
                        .samFont(.title3)
                        .foregroundStyle(.pink)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(event.personName) — \(event.eventDescription)")
                            .samFont(.subheadline)

                        if let suggestion = event.outreachSuggestion {
                            Text(suggestion)
                                .samFont(.caption)
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
                        .samFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)

                    Text(item.eventTitle)
                        .samFont(.subheadline)

                    if !item.attendeeNames.isEmpty {
                        Text("(\(item.attendeeNames.joined(separator: ", ")))")
                            .samFont(.caption)
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
                .samFont(.headline)
            Spacer()
            Text("\(count)")
                .samFont(.caption)
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

    // MARK: - Copy Briefing

    private func briefingTextForCopy(_ briefing: SamDailyBriefing) -> String {
        var parts: [String] = []
        parts.append("Daily Briefing — \(Date.now.formatted(date: .complete, time: .omitted))")

        if let narrative = briefing.narrativeSummary, !narrative.isEmpty {
            parts.append(narrative)
        }

        if !briefing.weeklyPriorities.isEmpty {
            parts.append("THIS WEEK'S PRIORITIES:")
            for (i, p) in briefing.weeklyPriorities.enumerated() {
                var line = "\(i + 1). \(p.title)"
                if let r = p.rationale, !r.isEmpty { line += " — \(r)" }
                if let name = p.personName { line += " [\(name)]" }
                parts.append(line)
            }
        }

        let upcomingCal = briefing.calendarItems.filter { ($0.endsAt ?? $0.startsAt) > Date() }
        if !upcomingCal.isEmpty {
            parts.append("TODAY'S SCHEDULE:")
            for item in upcomingCal {
                let time = item.startsAt.formatted(date: .omitted, time: .shortened)
                var line = "\(time)  \(item.eventTitle)"
                if !item.attendeeNames.isEmpty { line += " (\(item.attendeeNames.joined(separator: ", ")))" }
                if let prep = item.preparationNote, !prep.isEmpty { line += " — \(prep)" }
                parts.append(line)
            }
        }

        if !briefing.sphereSections.isEmpty {
            parts.append("BY SPHERE:")
            for section in briefing.sphereSections {
                parts.append("• \(section.sphereName)")
                if let status = section.trajectoryStatus, !status.isEmpty {
                    parts.append("  \(status)")
                }
                for action in section.topActions {
                    parts.append("  - \(action.title)")
                }
                for followUp in section.topFollowUps {
                    parts.append("  - \(followUp.personName): \(followUp.reason)")
                }
                if section.reachingForYouCount > 0 {
                    parts.append("  - \(section.reachingForYouCount) reaching for you")
                }
            }
        }

        if !briefing.priorityActions.isEmpty {
            parts.append("PRIORITY ACTIONS:")
            for (i, a) in briefing.priorityActions.enumerated() {
                var line = "\(i + 1). \(a.title)"
                if let name = a.personName { line += " [\(name)]" }
                parts.append(line)
            }
        }

        if !briefing.reachingForYou.isEmpty {
            parts.append("REACHING FOR YOU:")
            for r in briefing.reachingForYou {
                var line = "• \(r.personName)"
                if let days = r.daysSinceLastOutbound { line += " — quiet \(days)d" }
                if r.inboundCount30 > 0 { line += " (\(r.inboundCount30) inbound/30d)" }
                line += "\n  → \(r.suggestedAction)"
                parts.append(line)
            }
        }

        if !briefing.followUps.isEmpty {
            parts.append("FOLLOW-UPS NEEDED:")
            for f in briefing.followUps {
                parts.append("• \(f.personName) — \(f.reason) (\(f.daysSinceInteraction)d)")
            }
        }

        if !briefing.lifeEventOutreach.isEmpty {
            parts.append("LIFE EVENTS:")
            for e in briefing.lifeEventOutreach {
                var line = "• \(e.personName) — \(e.eventDescription)"
                if let s = e.outreachSuggestion { line += "\n  → \(s)" }
                parts.append(line)
            }
        }

        if !briefing.tomorrowPreview.isEmpty {
            parts.append("TOMORROW:")
            for item in briefing.tomorrowPreview {
                let time = item.startsAt.formatted(date: .omitted, time: .shortened)
                parts.append("\(time)  \(item.eventTitle)")
            }
        }

        return parts.joined(separator: "\n\n")
    }
}
