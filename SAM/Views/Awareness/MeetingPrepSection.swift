//
//  MeetingPrepSection.swift
//  SAM_crm
//
//  Created on February 20, 2026.
//  Phase K: Meeting Prep & Follow-Up
//
//  Briefing cards for upcoming meetings in Awareness view.
//

import SwiftUI
import AppKit

struct MeetingPrepSection: View {

    private var coordinator: MeetingPrepCoordinator { MeetingPrepCoordinator.shared }

    var body: some View {
        if !coordinator.briefings.isEmpty {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(.blue)
                    Text("Meeting Prep")
                        .font(.headline)
                    Text("\(coordinator.briefings.count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue)
                        .clipShape(Capsule())
                    Spacer()
                    Text("Next 48 hours")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                VStack(spacing: 10) {
                    ForEach(coordinator.briefings) { briefing in
                        BriefingCard(briefing: briefing)
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

// MARK: - Briefing Card

private struct BriefingCard: View {

    let briefing: MeetingBriefing
    @State private var isExpanded: Bool
    @State private var showingCapture = false

    init(briefing: MeetingBriefing) {
        self.briefing = briefing
        // Auto-expand if meeting starts within 15 minutes
        let timeUntilStart = briefing.startsAt.timeIntervalSinceNow
        self._isExpanded = State(initialValue: timeUntilStart <= 15 * 60 && timeUntilStart > 0)
    }

    private var attendeeIDs: [UUID] {
        briefing.attendees.compactMap { attendee in
            (try? PeopleRepository.shared.fetch(id: attendee.personID)) != nil ? attendee.personID : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(briefing.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        HStack(spacing: 8) {
                            Text(briefing.startsAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let location = briefing.location {
                                Text(location)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer()

                    // Attendee thumbnails + health dots
                    HStack(spacing: -6) {
                        ForEach(briefing.attendees.prefix(4)) { attendee in
                            AttendeeAvatar(attendee: attendee)
                        }
                        if briefing.attendees.count > 4 {
                            Text("+\(briefing.attendees.count - 4)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Circle())
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)

            // Expanded content
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 16) {
                    // Talking Points
                    if !briefing.talkingPoints.isEmpty {
                        talkingPointsSection
                    }

                    // Attendees
                    attendeesSection

                    // Recent History
                    if !briefing.recentHistory.isEmpty {
                        recentHistorySection
                    }

                    // Open Action Items
                    if !briefing.openActionItems.isEmpty {
                        actionItemsSection
                    }

                    // Topics
                    if !briefing.topics.isEmpty {
                        topicsSection
                    }

                    // Signals
                    if !briefing.signals.isEmpty {
                        signalsSection
                    }

                    // Shared Contexts
                    if !briefing.sharedContexts.isEmpty {
                        sharedContextsSection
                    }

                    // Family Relations
                    if !briefing.familyRelations.isEmpty {
                        familyRelationsSection
                    }

                    // Note capture
                    if showingCapture {
                        InlineNoteCaptureView(
                            linkedPerson: nil,
                            linkedContext: nil,
                            onSaved: { showingCapture = false },
                            linkedPeopleIDs: attendeeIDs,
                            initiallyExpanded: true
                        )
                    } else {
                        Button {
                            withAnimation { showingCapture = true }
                        } label: {
                            Label("Add Meeting Notes", systemImage: "note.text.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Expanded Sections

    private var talkingPointsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Talking Points")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.blue)

            ForEach(briefing.talkingPoints, id: \.self) { point in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .frame(width: 14)
                    Text(point)
                        .font(.caption)
                    Spacer()
                    CopyButton(text: point)
                }
            }
        }
    }

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attendees")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(briefing.attendees) { attendee in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        AttendeeAvatar(attendee: attendee)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(attendee.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let stage = attendee.pipelineStage {
                                    Text(stage)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                                ForEach(attendee.roleBadges.filter({ $0 != attendee.pipelineStage }), id: \.self) { badge in
                                    Text(badge)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                            }

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(attendee.health.statusColor)
                                    .frame(width: 6, height: 6)
                                Text("Last contact \(attendee.health.statusLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if !attendee.contexts.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(attendee.contexts.prefix(3), id: \.name) { ctx in
                                        Text(ctx.name)
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.1))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                    }
                                }
                            }
                        }

                        Spacer()
                    }

                    // Interaction history
                    if !attendee.lastInteractions.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(attendee.lastInteractions) { record in
                                HStack(spacing: 6) {
                                    Image(systemName: sourceIcon(record.source))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 12)
                                    Text(record.title)
                                        .font(.caption2)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(record.date, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.leading, 38)
                    }

                    // Pending actions
                    if !attendee.pendingActionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(attendee.pendingActionItems, id: \.self) { action in
                                HStack(spacing: 6) {
                                    Image(systemName: "circle")
                                        .font(.system(size: 6))
                                        .foregroundStyle(.orange)
                                    Text(action)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.leading, 38)
                    }

                    // Life events
                    if !attendee.recentLifeEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(attendee.recentLifeEvents, id: \.self) { event in
                                HStack(spacing: 6) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 7))
                                        .foregroundStyle(.yellow)
                                    Text(event)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.leading, 38)
                    }

                    // Product holdings
                    if !attendee.productHoldings.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(attendee.productHoldings, id: \.self) { product in
                                Text(product)
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.1))
                                    .foregroundStyle(.green)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        .padding(.leading, 38)
                    }
                }
            }
        }
    }

    private var recentHistorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent History")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(briefing.recentHistory) { record in
                HStack(spacing: 8) {
                    Image(systemName: sourceIcon(record.source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text(record.title)
                        .font(.caption)
                        .lineLimit(1)

                    Spacer()

                    Text(record.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open Action Items")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(briefing.openActionItems, id: \.description) { item in
                HStack(spacing: 6) {
                    Image(systemName: "circle")
                        .font(.caption2)
                        .foregroundStyle(urgencyColor(item.urgency))
                    Text(item.description)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    CopyButton(text: item.description)
                }
            }
        }
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Topics")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 4) {
                ForEach(briefing.topics, id: \.self) { topic in
                    Text(topic)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var signalsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Signals")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)

            ForEach(briefing.signals) { signal in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(signal.message)
                        .font(.caption)
                    Spacer()
                    CopyButton(text: signal.message)
                }
            }
        }
    }

    private var sharedContextsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shared Contexts")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(briefing.sharedContexts, id: \.id) { context in
                    HStack(spacing: 3) {
                        Image(systemName: "building.2")
                            .font(.caption2)
                        Text(context.name)
                            .font(.caption2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private var familyRelationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Family Relations")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(Array(briefing.familyRelations.enumerated()), id: \.offset) { _, rel in
                    HStack(spacing: 3) {
                        Image(systemName: "figure.2.and.child.holdinghands")
                            .font(.caption2)
                        Text("\(rel.personAName) — \(rel.relationType) — \(rel.personBName)")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.pink.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    // MARK: - Helpers

    private func sourceIcon(_ source: EvidenceSource) -> String {
        switch source {
        case .calendar: return "calendar"
        case .mail: return "envelope"
        case .contacts: return "person"
        case .note: return "note.text"
        case .manual: return "hand.raised"
        case .iMessage: return "message"
        case .phoneCall: return "phone"
        case .faceTime: return "video"
        }
    }

    private func urgencyColor(_ urgency: NoteActionItem.Urgency) -> Color {
        switch urgency {
        case .low: return .gray
        case .standard: return .blue
        case .soon: return .orange
        case .immediate: return .red
        }
    }
}

// MARK: - Attendee Avatar

private struct AttendeeAvatar: View {

    let attendee: AttendeeProfile

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let photoData = attendee.photoThumbnail,
               let nsImage = NSImage(data: photoData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
            } else {
                Text(initials(attendee.displayName))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.6))
                    .clipShape(Circle())
            }

            Circle()
                .fill(attendee.health.statusColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(.white, lineWidth: 1))
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let last = parts.count > 1 ? parts.last!.prefix(1) : ""
        return "\(first)\(last)".uppercased()
    }
}


