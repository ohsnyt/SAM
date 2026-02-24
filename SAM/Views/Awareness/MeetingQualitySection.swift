//
//  MeetingQualitySection.swift
//  SAM
//
//  Created on February 24, 2026.
//  Retroactive meeting follow-through quality scoring for Awareness dashboard.
//

import SwiftUI
import SwiftData

struct MeetingQualitySection: View {

    @Query private var allEvidence: [SamEvidenceItem]

    // MARK: - Computed State

    /// Calendar meetings from the last 14 days that have already ended.
    private var recentMeetings: [ScoredMeeting] {
        let now = Date()
        let fourteenDaysAgo = Calendar.current.date(byAdding: .day, value: -14, to: now)!

        return allEvidence
            .filter { item in
                item.source == .calendar
                && item.occurredAt >= fourteenDaysAgo
                && (item.endedAt ?? item.occurredAt) <= now
            }
            .map { scoreMeeting($0) }
            .sorted { $0.score < $1.score } // Lowest scores first
    }

    /// Meetings scoring below 60 that need attention.
    private var lowScoringMeetings: [ScoredMeeting] {
        Array(recentMeetings.filter { $0.score < 60 }.prefix(5))
    }

    /// Average score across all recent meetings.
    private var averageScore: Int {
        guard !recentMeetings.isEmpty else { return 0 }
        let total = recentMeetings.reduce(0) { $0 + $1.score }
        return total / recentMeetings.count
    }

    private var allWellDocumented: Bool {
        !recentMeetings.isEmpty && lowScoringMeetings.isEmpty
    }

    // MARK: - Body

    var body: some View {
        if !recentMeetings.isEmpty {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.purple)
                    Text("Meeting Quality")
                        .font(.headline)
                    averageScoreBadge
                    Spacer()
                    Text("Last 14 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                if allWellDocumented {
                    congratulatoryMessage
                } else {
                    VStack(spacing: 10) {
                        ForEach(lowScoringMeetings) { meeting in
                            MeetingQualityCard(meeting: meeting)
                        }
                    }
                    .padding()
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Subviews

    private var averageScoreBadge: some View {
        Text("\(averageScore)")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(colorForScore(averageScore))
            .clipShape(Capsule())
    }

    private var congratulatoryMessage: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("All meetings well-documented")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(recentMeetings.count) meeting\(recentMeetings.count == 1 ? "" : "s") in the last two weeks, all with solid follow-through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Scoring

    private func scoreMeeting(_ item: SamEvidenceItem) -> ScoredMeeting {
        var score = 0
        var missing: [String] = []

        let hasNote = !item.linkedNotes.isEmpty
        let meetingEnd = item.endedAt ?? item.occurredAt

        // +40: Note created
        if hasNote {
            score += 40
        } else {
            missing.append("No notes")
        }

        // +20: Timely note (within 24h of meeting end)
        if hasNote {
            let earliestNote = item.linkedNotes.map(\.createdAt).min()!
            let hoursAfter = earliestNote.timeIntervalSince(meetingEnd) / 3600
            if hoursAfter <= 24 {
                score += 20
            } else {
                missing.append("Late follow-up")
            }
        }

        // +20: Action items identified
        if hasNote {
            let hasActionItems = item.linkedNotes.contains { !$0.extractedActionItems.isEmpty }
            if hasActionItems {
                score += 20
            } else {
                missing.append("No action items")
            }
        } else {
            missing.append("No action items")
        }

        // +20: Has attendees
        if !item.linkedPeople.isEmpty {
            score += 20
        } else {
            missing.append("No attendees")
        }

        return ScoredMeeting(
            id: item.id,
            title: item.title,
            occurredAt: item.occurredAt,
            score: score,
            missing: missing
        )
    }

    // MARK: - Helpers

    fileprivate static func colorForScore(_ score: Int) -> Color {
        switch score {
        case 80...100: return .green
        case 60..<80:  return .blue
        case 40..<60:  return .orange
        default:        return .red
        }
    }

    private func colorForScore(_ score: Int) -> Color {
        Self.colorForScore(score)
    }
}

// MARK: - Scored Meeting Model

private struct ScoredMeeting: Identifiable {
    let id: UUID
    let title: String
    let occurredAt: Date
    let score: Int
    let missing: [String]
}

// MARK: - Meeting Quality Card

private struct MeetingQualityCard: View {

    let meeting: ScoredMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(meeting.occurredAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Score indicator
                scoreLabel
            }

            // Score bar
            scoreBar

            // Missing tags
            if !meeting.missing.isEmpty {
                HStack(spacing: 4) {
                    ForEach(meeting.missing, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var scoreLabel: some View {
        Text("\(meeting.score)")
            .font(.title3)
            .fontWeight(.bold)
            .foregroundStyle(MeetingQualitySection.colorForScore(meeting.score))
    }

    private var scoreBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 3)
                    .fill(MeetingQualitySection.colorForScore(meeting.score))
                    .frame(width: geometry.size.width * CGFloat(meeting.score) / 100.0, height: 6)
            }
        }
        .frame(height: 6)
    }
}
