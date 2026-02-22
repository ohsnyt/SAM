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

struct MeetingPrepSection: View {

    @State private var coordinator = MeetingPrepCoordinator.shared

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

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(coordinator.briefings) { briefing in
                            BriefingCard(briefing: briefing)
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 500)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

// MARK: - Briefing Card

private struct BriefingCard: View {

    let briefing: MeetingBriefing
    @State private var isExpanded = false
    @State private var editingNote: SamNote?

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

                    // Action button
                    Button {
                        createAndEditNote()
                    } label: {
                        Label("Add Meeting Notes", systemImage: "note.text.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
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
        .sheet(item: $editingNote) { note in
            NoteEditorView(note: note) { }
        }
    }

    private func createAndEditNote() {
        let person = briefing.attendees.first.flatMap { attendee in
            try? PeopleRepository.shared.fetch(id: attendee.personID)
        }
        do {
            let note = try NotesRepository.shared.create(
                content: "",
                linkedPeopleIDs: person.map { [$0.id] } ?? []
            )
            editingNote = note
        } catch {
            // Non-critical
        }
    }

    // MARK: - Expanded Sections

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attendees")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            ForEach(briefing.attendees) { attendee in
                HStack(spacing: 10) {
                    AttendeeAvatar(attendee: attendee)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(attendee.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            ForEach(attendee.roleBadges, id: \.self) { badge in
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

// MARK: - Flow Layout (simple wrapping)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
