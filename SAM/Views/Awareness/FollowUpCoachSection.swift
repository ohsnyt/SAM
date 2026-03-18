//
//  FollowUpCoachSection.swift
//  SAM_crm
//
//  Created on February 20, 2026.
//  Phase K: Meeting Prep & Follow-Up
//
//  Follow-up prompts for past meetings with no linked note.
//

import SwiftUI
import AppKit

struct FollowUpCoachSection: View {

    private var coordinator: MeetingPrepCoordinator { MeetingPrepCoordinator.shared }
    @State private var dismissedIDs: Set<UUID> = []

    private var visiblePrompts: [FollowUpPrompt] {
        coordinator.followUpPrompts.filter { !dismissedIDs.contains($0.id) }
    }

    var body: some View {
        if !visiblePrompts.isEmpty {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.orange)
                    Text("Meeting Follow-ups")
                        .samFont(.headline)
                    Text("\(visiblePrompts.count)")
                        .samFont(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange)
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                LazyVStack(spacing: 8) {
                    ForEach(visiblePrompts) { prompt in
                        FollowUpCard(prompt: prompt) {
                            _ = withAnimation {
                                dismissedIDs.insert(prompt.id)
                            }
                            // Mark the event evidence as done
                            if let evidence = try? EvidenceRepository.shared.fetch(id: prompt.eventID) {
                                try? EvidenceRepository.shared.markAsReviewed(item: evidence)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

// MARK: - Follow-Up Card

private struct FollowUpCard: View {

    let prompt: FollowUpPrompt
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Description
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                    .samFont(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(meetingDescription)
                        .samFont(.subheadline)

                    if !prompt.pendingActionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open items:")
                                .samFont(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            ForEach(prompt.pendingActionItems.prefix(3), id: \.description) { item in
                                HStack(spacing: 4) {
                                    Image(systemName: "circle")
                                        .font(.system(size: 6))
                                        .foregroundStyle(.secondary)
                                    Text(item.description)
                                        .samFont(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    CopyButton(text: item.description)
                                }
                            }
                        }
                    }
                }

                Spacer()
            }

            // Actions
            HStack(spacing: 10) {
                Button {
                    openCaptureSheet()
                } label: {
                    Label("Capture Notes", systemImage: "note.text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: onDismiss) {
                    Label("Dismiss", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func openCaptureSheet() {
        let attendeeInfos = prompt.attendees.map { attendee in
            let person = try? PeopleRepository.shared.fetch(id: attendee.personID)
            return CaptureAttendeeInfo(
                personID: attendee.personID,
                displayName: attendee.displayName,
                roleBadges: person?.roleBadges ?? [],
                pendingActionItems: prompt.pendingActionItems
                    .filter { $0.linkedPersonID == attendee.personID }
                    .map(\.description),
                recentLifeEvents: []
            )
        }

        let payload = CapturePayload(
            captureKind: .meeting,
            eventTitle: prompt.title,
            eventDate: prompt.endedAt,
            attendees: attendeeInfos,
            talkingPoints: [],
            openActionItems: prompt.pendingActionItems.map(\.description),
            evidenceID: prompt.eventID
        )

        NotificationCenter.default.post(
            name: .samOpenPostMeetingCapture,
            object: nil,
            userInfo: ["payload": payload]
        )
    }

    private var meetingDescription: AttributedString {
        let names = prompt.attendees.map(\.displayName).joined(separator: ", ")
        let timeAgo = relativeTimeString(from: prompt.endedAt)
        var result = AttributedString("You met with ")
        var boldNames = AttributedString(names)
        boldNames.font = .subheadline.bold()
        result.append(boldNames)
        result.append(AttributedString(" \(timeAgo)."))
        return result
    }

    private func relativeTimeString(from date: Date) -> String {
        let hours = Int(Date().timeIntervalSince(date) / 3600)
        if hours < 1 { return "just now" }
        if hours == 1 { return "1 hour ago" }
        if hours < 24 { return "\(hours) hours ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }
}
