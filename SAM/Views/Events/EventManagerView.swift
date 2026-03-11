//
//  EventManagerView.swift
//  SAM
//
//  Created on March 11, 2026.
//  Event Manager — Main container for event lifecycle management.
//

import SwiftUI

struct EventManagerView: View {

    @State private var coordinator = EventCoordinator.shared
    @State private var selectedEventID: UUID?
    @State private var showNewEventForm = false
    @State private var eventFilter: EventFilter = .upcoming
    @State private var refreshToken = UUID()
    @State private var activeSection: EventSection = .events

    enum EventSection: String, CaseIterable {
        case events = "Events"
        case presentations = "Presentations"
    }

    enum EventFilter: String, CaseIterable {
        case upcoming = "Upcoming"
        case past = "Past"
        case all = "All"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Section picker
            Picker("Section", selection: $activeSection) {
                ForEach(EventSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Content
            switch activeSection {
            case .events:
                eventsContent
            case .presentations:
                PresentationLibraryView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .samUndoDidRestore)) { _ in
            refreshToken = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .samRSVPAutoAdded)) { _ in
            refreshToken = UUID()
        }
        .sheet(isPresented: $showNewEventForm) {
            EventFormView { event in
                selectedEventID = event.id
                refreshToken = UUID()
            }
        }
    }

    private var eventsContent: some View {
        HSplitView {
            eventList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)

            Group {
                if let eventID = selectedEventID {
                    EventDetailView(eventID: eventID, onDelete: {
                        selectedEventID = nil
                        refreshToken = UUID()
                    })
                } else {
                    ContentUnavailableView(
                        "Select an Event",
                        systemImage: "calendar.badge.plus",
                        description: Text("Choose an event from the list or create a new one")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Event List

    private var eventList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Events")
                    .font(.title2.bold())
                Spacer()
                Button {
                    showNewEventForm = true
                } label: {
                    Label("New Event", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Picker("Filter", selection: $eventFilter) {
                ForEach(EventFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            List(selection: $selectedEventID) {
                let events = filteredEvents
                if events.isEmpty {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "calendar",
                        description: Text("Create your first event to get started")
                    )
                } else {
                    ForEach(events, id: \.id) { event in
                        EventRowView(event: event)
                            .tag(event.id)
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(maxHeight: .infinity)
    }

    private var filteredEvents: [SamEvent] {
        // refreshToken dependency triggers SwiftUI re-evaluation after event creation
        _ = refreshToken
        let repo = EventRepository.shared
        do {
            switch eventFilter {
            case .upcoming: return try repo.fetchUpcoming()
            case .past: return try repo.fetchPast()
            case .all: return try repo.fetchAll()
            }
        } catch {
            return []
        }
    }
}

// MARK: - Event Row

struct EventRowView: View {
    let event: SamEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: event.format.icon)
                    .foregroundStyle(statusColor)
                    .font(.caption)
                Text(event.title)
                    .font(.headline)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(event.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // RSVP summary
                HStack(spacing: 4) {
                    Image(systemName: "person.fill.checkmark")
                        .foregroundStyle(.green)
                    Text("\(event.acceptedCount)")
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text("\(event.targetParticipantCount)")
                }
                .font(.caption)
            }

            HStack(spacing: 6) {
                Text(event.status.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor)

                Text(event.format.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch event.status {
        case .draft:      return .secondary
        case .inviting:   return .blue
        case .confirmed:  return .green
        case .inProgress: return .orange
        case .completed:  return .secondary
        case .cancelled:  return .red
        }
    }
}
