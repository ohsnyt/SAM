//
//  EveningRecapOverlay.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Daily Briefing System
//
//  Evening recap shown as .sheet — accomplishments, streaks, tomorrow preview.
//

import SwiftUI

struct EveningRecapOverlay: View {

    private var coordinator: DailyBriefingCoordinator { DailyBriefingCoordinator.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("End of Day")
                        .font(.title)
                        .fontWeight(.bold)

                    Text(Date.now.formatted(date: .complete, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let briefing = coordinator.eveningBriefing {
                    // AI narrative
                    if let narrative = briefing.narrativeSummary, !narrative.isEmpty {
                        Text(narrative)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // Metrics summary bar
                    metricsBar(briefing)

                    // Accomplishments
                    if !briefing.accomplishments.isEmpty {
                        accomplishmentsSection(briefing.accomplishments)
                    }

                    // Streak updates
                    if !briefing.streakUpdates.isEmpty {
                        streaksSection(briefing.streakUpdates)
                    }

                    // Tomorrow preview
                    if !briefing.tomorrowPreview.isEmpty {
                        tomorrowSection(briefing.tomorrowPreview)
                    }

                    // Friday: week-so-far
                    if Calendar.current.component(.weekday, from: .now) == 6 {
                        weekSummaryNote
                    }
                }

                // Dismiss
                Button(action: {
                    coordinator.markEveningViewed()
                }) {
                    Text("Done for Today")
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

    // MARK: - Metrics Bar

    private func metricsBar(_ briefing: SamDailyBriefing) -> some View {
        HStack(spacing: 16) {
            metricChip("Meetings", value: briefing.meetingCount, icon: "calendar")
            metricChip("Notes", value: briefing.notesTakenCount, icon: "note.text")
            metricChip("Completed", value: briefing.outcomesCompletedCount, icon: "checkmark.circle")
            metricChip("Emails", value: briefing.emailsProcessedCount, icon: "envelope")
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func metricChip(_ label: String, value: Int, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Accomplishments

    private func accomplishmentsSection(_ items: [BriefingAccomplishment]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("Accomplishments")
                    .font(.headline)
            }

            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(systemName: categoryIcon(item.category))
                        .font(.caption)
                        .foregroundStyle(.green)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)

                        if let person = item.personName {
                            Text(person)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Streaks

    private func streaksSection(_ updates: [BriefingStreakUpdate]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text("Streaks")
                    .font(.headline)
            }

            ForEach(updates) { update in
                HStack(spacing: 10) {
                    Text("\(update.currentCount)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(update.isNewRecord ? .orange : .primary)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(update.streakName)
                                .font(.subheadline)
                                .fontWeight(.medium)

                            if update.isNewRecord {
                                Text("NEW RECORD")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange)
                                    .clipShape(Capsule())
                            }
                        }

                        Text(update.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Tomorrow

    private func tomorrowSection(_ items: [BriefingCalendarItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.blue)
                Text("Tomorrow's Highlights")
                    .font(.headline)
            }

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
                        Text("with \(item.attendeeNames.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Week Summary Note (Friday only)

    private var weekSummaryNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundStyle(.purple)
                Text("Week So Far")
                    .font(.headline)
            }

            Text("You've had a productive week. A full weekly summary with trends and patterns will be available in future updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Helpers

    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "outcome": return "checkmark.circle.fill"
        case "note":    return "note.text"
        case "meeting": return "calendar"
        case "contact": return "person.fill"
        default:        return "star.fill"
        }
    }
}

// MARK: - Evening Prompt Banner

/// Non-modal banner shown at top of AwarenessView when evening recap is ready.
struct EveningPromptBanner: View {

    private var coordinator: DailyBriefingCoordinator { DailyBriefingCoordinator.shared }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.fill")
                .font(.title3)
                .foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 2) {
                if coordinator.isRecompilingEvening {
                    Text("Updating your end-of-day summary…")
                        .font(.subheadline)
                        .fontWeight(.medium)
                } else {
                    Text("Ready for your end-of-day summary?")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                Text("Review your accomplishments and plan for tomorrow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if coordinator.isRecompilingEvening {
                ProgressView()
                    .controlSize(.small)
            }

            Button("View") {
                coordinator.viewEveningRecap()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Later") {
                coordinator.postponeEveningFromUser()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: {
                coordinator.declineEvening()
            }) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.indigo.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.indigo.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
