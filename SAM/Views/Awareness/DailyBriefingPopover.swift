//
//  DailyBriefingPopover.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Daily Briefing System
//
//  Compact popover for toolbar button re-access to today's briefing.
//

import SwiftUI

struct DailyBriefingPopover: View {

    private var coordinator: DailyBriefingCoordinator { DailyBriefingCoordinator.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let briefing = coordinator.morningBriefing {
                    // Mini header
                    HStack {
                        Text("Today's Briefing")
                            .font(.headline)
                        Spacer()
                        Text(briefing.generatedAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Mini narrative
                    if let narrative = briefing.narrativeSummary, !narrative.isEmpty {
                        Text(narrative)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Compact calendar rows
                    if !briefing.calendarItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Schedule")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            ForEach(briefing.calendarItems) { item in
                                HStack(spacing: 8) {
                                    Text(item.startsAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                        .frame(width: 50, alignment: .trailing)

                                    Circle()
                                        .fill(healthColor(item.healthStatus))
                                        .frame(width: 6, height: 6)

                                    Text(item.eventTitle)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    // Top 3 actions
                    if !briefing.priorityActions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Actions")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            ForEach(briefing.priorityActions.prefix(3)) { action in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(urgencyColor(action.urgency))
                                        .frame(width: 6, height: 6)

                                    Text(action.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }

                    // View Full Briefing button
                    Button(action: {
                        coordinator.showMorningBriefing = true
                    }) {
                        Text("View Full Briefing")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)

                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.book.closed")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No briefing yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
            .padding(16)
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
