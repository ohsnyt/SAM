//
//  StreakTrackingSection.swift
//  SAM
//
//  Created on February 24, 2026.
//  Streak tracking for positive behavior reinforcement in Awareness dashboard.
//

import SwiftUI
import SwiftData

struct StreakTrackingSection: View {

    @Query(sort: \SamEvidenceItem.occurredAt, order: .reverse)
    private var allEvidence: [SamEvidenceItem]

    /// Calendar events filtered in-memory (SwiftData predicates don't support enum member access).
    private var calendarEvents: [SamEvidenceItem] {
        allEvidence.lazy.filter { $0.source == .calendar }.prefix(50).map { $0 }
    }

    private var streaks: StreakResults {
        computeStreaks()
    }

    private var hasAnyStreak: Bool {
        streaks.meetingNotes > 0 || streaks.weeklyTouch > 0 || streaks.followUp > 0 || streaks.contentPosting > 0
    }

    var body: some View {
        if hasAnyStreak {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                    Text("Streaks")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                HStack(spacing: 12) {
                    if streaks.meetingNotes > 0 {
                        StreakCard(
                            icon: "note.text",
                            count: streaks.meetingNotes,
                            label: "Meeting Notes",
                            isActive: streaks.meetingNotes >= 3
                        )
                    }
                    if streaks.weeklyTouch > 0 {
                        StreakCard(
                            icon: "person.2.fill",
                            count: streaks.weeklyTouch,
                            label: "Weekly Client Contact",
                            isActive: streaks.weeklyTouch >= 3
                        )
                    }
                    if streaks.followUp > 0 {
                        StreakCard(
                            icon: "bolt.fill",
                            count: streaks.followUp,
                            label: "Same-Day Follow-Ups",
                            isActive: streaks.followUp >= 3
                        )
                    }
                    if streaks.contentPosting > 0 {
                        StreakCard(
                            icon: "text.badge.star",
                            count: streaks.contentPosting,
                            label: "Weekly Posting",
                            isActive: streaks.contentPosting >= 3
                        )
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Streak Computation

    private func computeStreaks() -> StreakResults {
        let meetings = Array(calendarEvents.prefix(50))
        let meetingNotesStreak = computeMeetingNotesStreak(meetings: meetings)
        let weeklyTouchStreak = computeWeeklyTouchStreak()
        let followUpStreak = computeFollowUpStreak(meetings: meetings)
        let contentPostingStreak = (try? ContentPostRepository.shared.weeklyPostingStreak()) ?? 0
        return StreakResults(
            meetingNotes: meetingNotesStreak,
            weeklyTouch: weeklyTouchStreak,
            followUp: followUpStreak,
            contentPosting: contentPostingStreak
        )
    }

    /// Count consecutive calendar events (most recent first) that have at least one linked note.
    private func computeMeetingNotesStreak(meetings: [SamEvidenceItem]) -> Int {
        var streak = 0
        for meeting in meetings {
            if !meeting.linkedNotes.isEmpty {
                streak += 1
            } else {
                break
            }
        }
        return streak
    }

    /// Count consecutive weeks (going backwards from current week) where at least one
    /// evidence item was created for any Client-role person.
    private func computeWeeklyTouchStreak() -> Int {
        let calendar = Calendar.current
        guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else {
            return 0
        }

        // Build a set of week-start dates that have client evidence
        var clientWeeks = Set<Date>()
        for item in allEvidence {
            let hasClient = item.linkedPeople.contains { person in
                person.roleBadges.contains("Client")
            }
            if hasClient, let weekStart = calendar.dateInterval(of: .weekOfYear, for: item.occurredAt)?.start {
                clientWeeks.insert(weekStart)
            }
        }

        // Walk backwards from current week
        var streak = 0
        var checkDate = currentWeekStart
        while clientWeeks.contains(checkDate) {
            streak += 1
            guard let previousWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: checkDate) else {
                break
            }
            checkDate = previousWeek
        }
        return streak
    }

    /// Count consecutive calendar events where a note was created within 24 hours
    /// of the event's endedAt (or occurredAt if no endedAt).
    private func computeFollowUpStreak(meetings: [SamEvidenceItem]) -> Int {
        let twentyFourHours: TimeInterval = 24 * 60 * 60
        var streak = 0
        for meeting in meetings {
            let referenceDate = meeting.endedAt ?? meeting.occurredAt
            let hasTimelyNote = meeting.linkedNotes.contains { note in
                let interval = note.createdAt.timeIntervalSince(referenceDate)
                return interval >= 0 && interval <= twentyFourHours
            }
            if hasTimelyNote {
                streak += 1
            } else {
                break
            }
        }
        return streak
    }
}

// MARK: - Supporting Types

private struct StreakResults {
    let meetingNotes: Int
    let weeklyTouch: Int
    let followUp: Int
    let contentPosting: Int
}

// MARK: - Streak Card

private struct StreakCard: View {

    let icon: String
    let count: Int
    let label: String
    let isActive: Bool

    private var accentColor: Color {
        isActive ? .green : .gray
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(accentColor)
                if count >= 5 {
                    Image(systemName: "flame.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Text("\(count)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(accentColor)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(isActive ? "Keep it going!" : "Start a new streak today")
                .font(.caption2)
                .foregroundStyle(isActive ? .green : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accentColor.opacity(0.3), lineWidth: 1)
        )
    }
}
