//
//  TodayView.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F4: Today Tab
//
//  Daily overview — calendar events, pending actions, recent captures, trip stats.
//

import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var coordinator = FieldDayCoordinator.shared
    @State private var tripCoordinator = TripCoordinator.shared
    @State private var briefingJSON: String? = nil

    var body: some View {
        List {
            // Morning briefing from Mac via CloudKit
            if let json = briefingJSON {
                briefingSection(json)
            }

            // Calendar access prompt
            if coordinator.needsCalendarAccess {
                Section {
                    Button {
                        Task { await coordinator.requestCalendarAccess() }
                    } label: {
                        Label("Enable Calendar Access", systemImage: "calendar.badge.plus")
                    }
                } footer: {
                    Text("Allow calendar access to see your meetings and appointments here.")
                }
            }

            // Unconfirmed trips banner
            if tripCoordinator.unconfirmedCount > 0 {
                unconfirmedTripsBanner
            }

            // Active trip banner
            if tripCoordinator.isTracking {
                activeTripBanner
            }

            // Today's schedule
            scheduleSection

            // Pending follow-ups
            if !coordinator.pendingFollowUps.isEmpty {
                pendingSection
            }

            // Recent captures
            if !coordinator.recentCaptures.isEmpty {
                capturesSection
            }

            // Quick stats
            statsSection
        }
        .navigationTitle("Today")
        .refreshable {
            coordinator.refresh()
            tripCoordinator.refreshStats()
            // Pull latest briefing + settings from CloudKit
            await CloudSyncService.shared.fetchAndCacheWorkspaceSettings()
            briefingJSON = await CloudSyncService.shared.fetchBriefing()
            FieldCalendarService.shared.refreshToday()
        }
        .onAppear {
            coordinator.configure(container: modelContext.container)
            tripCoordinator.configure(container: modelContext.container)
            Task {
                // Fetch workspace settings and briefing from CloudKit
                if WorkspaceSettings.loadCached() == nil {
                    await CloudSyncService.shared.fetchAndCacheWorkspaceSettings()
                    FieldCalendarService.shared.refreshToday()
                }
                if briefingJSON == nil {
                    briefingJSON = await CloudSyncService.shared.fetchBriefing()
                }
            }
        }
    }

    // MARK: - Briefing

    @ViewBuilder
    private func briefingSection(_ json: String) -> some View {
        if let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {

            let heading = dict["sectionHeading"] ?? "Morning Briefing"
            let generatedAt: Date? = dict["date"].flatMap {
                ISO8601DateFormatter().date(from: $0)
            }

            Section {
                // Narrative summary
                if let narrative = dict["narrativeSummary"], !narrative.isEmpty {
                    Text(narrative)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // NOTE: Priority actions and follow-ups suppressed until
                // they are actionable on the phone (call, text, email).
                // See project_phone_actionable_items.md for the plan.
            } header: {
                HStack {
                    Text(heading)
                    Spacer()
                    if let date = generatedAt {
                        let minutes = max(1, Int(ceil(Date().timeIntervalSince(date) / 60.0)))
                        Text(minutes == 1 ? "1 min ago" : "\(minutes) min ago")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Unconfirmed Trips Banner

    private var unconfirmedTripsBanner: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(tripCoordinator.unconfirmedCount) trip\(tripCoordinator.unconfirmedCount == 1 ? "" : "s") need review")
                        .font(.headline)
                    Text("Confirm recent trips to satisfy IRS contemporaneous record requirements.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Active Trip Banner

    private var activeTripBanner: some View {
        Section {
            HStack {
                Image(systemName: "car.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trip Active")
                        .font(.headline)
                    Text(String(format: "%.1f miles", tripCoordinator.totalDistanceMiles))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        Section("Schedule") {
            if coordinator.calendarEvents.isEmpty {
                if coordinator.needsCalendarAccess {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text("Calendar access needed")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundStyle(.secondary)
                        Text("No events today")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(coordinator.calendarEvents) { event in
                    CalendarEventRow(event: event)
                }
            }
        }
    }

    // MARK: - Pending Actions

    private var pendingSection: some View {
        Section("Follow-ups") {
            ForEach(coordinator.pendingFollowUps) { action in
                HStack(spacing: 12) {
                    Circle()
                        .fill(action.isOverdue ? .red : .orange)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .font(.subheadline)
                            .lineLimit(2)

                        HStack(spacing: 4) {
                            if let person = action.personName {
                                Text(person)
                            }
                            if let deadline = action.deadline {
                                Text("Due \(deadline, style: .relative)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(action.isOverdue ? .red : .secondary)
                    }
                }
            }
        }
    }

    // MARK: - Recent Captures

    private var capturesSection: some View {
        Section("Recent Voice Notes") {
            ForEach(coordinator.recentCaptures.prefix(5), id: \.id) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.summary ?? String(note.content.prefix(80)))
                        .font(.subheadline)
                        .lineLimit(2)

                    HStack {
                        Text(note.createdAt, style: .relative)
                        if !note.linkedPeople.isEmpty {
                            Text("with \(note.linkedPeople.first?.displayNameCache ?? "someone")")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        Section("Quick Stats") {
            HStack {
                StatCard(icon: "calendar", value: "\(coordinator.todayStats.meetingsToday)", label: "Meetings")
                StatCard(icon: "bell.badge", value: "\(coordinator.todayStats.pendingActions)", label: "Pending")
                StatCard(icon: "mic.fill", value: "\(coordinator.todayStats.capturesThisWeek)", label: "Captures")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if tripCoordinator.monthBusinessMiles > 0 {
                HStack {
                    Image(systemName: "car.fill")
                        .foregroundStyle(.blue)
                    Text("This month")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f mi", tripCoordinator.monthBusinessMiles))
                        .font(.subheadline.monospacedDigit().bold())
                }
            }
        }
    }
}

// MARK: - Calendar Event Row

private struct CalendarEventRow: View {
    let event: FieldCalendarService.CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Time column
            VStack {
                if event.isAllDay {
                    Text("All Day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(event.startDate, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(event.isNow ? .blue : (event.isPast ? .secondary : .primary))
                }
            }
            .frame(width: 55, alignment: .trailing)

            // Color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(event.isNow ? .blue : .secondary)
                .frame(width: 3)

            // Event details
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(event.isPast ? .secondary : .primary)

                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.caption2)
                        Text(location)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !event.isAllDay {
                    let duration = event.durationMinutes
                    Text(duration >= 60 ? "\(duration / 60)h \(duration % 60)m" : "\(duration)m")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

#Preview("Today") {
    NavigationStack {
        TodayView()
    }
    .modelContainer(for: SamNote.self, inMemory: true)
}
