//
//  FieldCalendarService.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F4: Today Tab — Direct EventKit calendar access
//
//  Reads calendar events directly on iOS via EventKit.
//  This provides Today tab data without requiring CloudKit sync.
//

import Foundation
import EventKit
import os.log

@MainActor
@Observable
final class FieldCalendarService {

    static let shared = FieldCalendarService()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "FieldCalendarService")

    private let store = EKEventStore()

    private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    private(set) var todayEvents: [CalendarEvent] = []

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Authorization

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            logger.info("Calendar access \(granted ? "granted" : "denied")")
            return granted
        } catch {
            logger.error("Calendar access request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Fetch Events

    /// Fetch events for a specific date. Filters to SAM work calendars
    /// if workspace settings have been synced from the Mac.
    func fetchEvents(for date: Date) -> [CalendarEvent] {
        guard isAuthorized else { return [] }

        let calendar = Calendar.current
        guard let dayStart = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: date)),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        // Only read from SAM-configured work calendars. Never read
        // from all calendars — we told the user we only access SAM groups.
        let calendars = samWorkCalendars()
        guard !calendars.isEmpty else {
            logger.debug("No SAM work calendars configured — skipping calendar fetch")
            return []
        }

        let predicate = store.predicateForEvents(
            withStart: dayStart,
            end: dayEnd,
            calendars: calendars
        )
        let ekEvents = store.events(matching: predicate)

        return ekEvents
            .sorted { $0.startDate < $1.startDate }
            .map { makeCalendarEvent(from: $0) }
    }

    /// Refresh today's events.
    func refreshToday() {
        todayEvents = fetchEvents(for: .now)
        logger.debug("Fetched \(self.todayEvents.count) events for today")
    }

    // MARK: - Types

    /// Find the upcoming or current meeting closest to now (within ±30 min).
    /// Filters to SAM's configured work calendars if workspace settings
    /// have been synced from the Mac. Falls back to all calendars if
    /// no settings are cached.
    func upcomingMeeting() -> CalendarEvent? {
        guard isAuthorized else { return nil }

        let now = Date()
        let windowStart = now.addingTimeInterval(-30 * 60)
        let windowEnd = now.addingTimeInterval(30 * 60)

        // Only read from SAM-configured work calendars.
        let calendars = samWorkCalendars()
        guard !calendars.isEmpty else { return nil }

        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: calendars
        )
        let ekEvents = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        // Prefer: currently happening > starting soon > recently started
        if let current = ekEvents.first(where: { $0.startDate <= now && $0.endDate >= now }) {
            return makeCalendarEvent(from: current)
        }
        if let upcoming = ekEvents.first(where: { $0.startDate > now }) {
            return makeCalendarEvent(from: upcoming)
        }
        return ekEvents.first.map { makeCalendarEvent(from: $0) }
    }

    /// Return the EKCalendar objects matching SAM's workspace settings.
    /// Uses cached settings from the Mac. Returns empty if no settings cached
    /// (caller should pass nil to search all calendars).
    private func samWorkCalendars() -> [EKCalendar] {
        guard let settings = WorkspaceSettings.loadCached() else { return [] }

        let allCalendars = store.calendars(for: .event)

        // Match by identifier first (exact), then by name (fallback)
        var matched: [EKCalendar] = []
        for cal in allCalendars {
            if settings.calendarIdentifiers.contains(cal.calendarIdentifier) {
                matched.append(cal)
            } else if settings.calendarNames.contains(cal.title) {
                matched.append(cal)
            }
        }

        if !matched.isEmpty {
            logger.debug("Filtered to \(matched.count) SAM work calendar(s): \(matched.map(\.title).joined(separator: ", "))")
        }

        return matched
    }

    private func makeCalendarEvent(from event: EKEvent) -> CalendarEvent {
        let attendees: [EventAttendee] = (event.attendees ?? [])
            .filter { $0.participantRole != .nonParticipant }
            .compactMap { attendee -> EventAttendee? in
                let emailRaw = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                let email = emailRaw.isEmpty ? nil : emailRaw
                if let name = attendee.name, !name.isEmpty {
                    return EventAttendee(name: name, email: email, thumbnailData: nil)
                }
                if let email {
                    return EventAttendee(name: email, email: email, thumbnailData: nil)
                }
                return nil
            }

        return CalendarEvent(
            id: event.eventIdentifier,
            title: event.title ?? "Untitled",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            notes: event.notes,
            isAllDay: event.isAllDay,
            calendarName: event.calendar.title,
            calendarColor: event.calendar.cgColor,
            attendees: attendees
        )
    }

    /// Asynchronously enriches a CalendarEvent's attendees with CNContact thumbnails.
    /// Returns a new CalendarEvent with thumbnailData populated where matches are found.
    func enrichWithThumbnails(_ event: CalendarEvent) async -> CalendarEvent {
        let lookupInputs = event.attendees.map { (name: $0.name, email: $0.email) }
        let thumbnails = await FieldContactLookupService.shared.thumbnails(for: lookupInputs)
        var enriched = event
        for i in enriched.attendees.indices {
            enriched.attendees[i].thumbnailData = i < thumbnails.count ? thumbnails[i] : nil
        }
        return enriched
    }

    struct EventAttendee: Sendable {
        let name: String
        let email: String?
        /// CNContact thumbnail image data, populated asynchronously after initial fetch.
        var thumbnailData: Data?
    }

    struct CalendarEvent: Identifiable, Sendable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let location: String?
        let notes: String?
        let isAllDay: Bool
        let calendarName: String
        let calendarColor: CGColor?
        var attendees: [EventAttendee]

        /// Convenience accessor for backward-compatible name-only access.
        var attendeeNames: [String] { attendees.map(\.name) }

        init(id: String, title: String, startDate: Date, endDate: Date,
             location: String?, notes: String?, isAllDay: Bool,
             calendarName: String, calendarColor: CGColor?,
             attendees: [EventAttendee] = []) {
            self.id = id; self.title = title; self.startDate = startDate
            self.endDate = endDate; self.location = location; self.notes = notes
            self.isAllDay = isAllDay; self.calendarName = calendarName
            self.calendarColor = calendarColor; self.attendees = attendees
        }

        var minutesUntilStart: Int {
            Int(startDate.timeIntervalSinceNow / 60)
        }

        var isNow: Bool {
            let now = Date()
            return startDate <= now && endDate >= now
        }

        var isPast: Bool {
            endDate < Date()
        }

        var durationMinutes: Int {
            Int(endDate.timeIntervalSince(startDate) / 60)
        }
    }
}
