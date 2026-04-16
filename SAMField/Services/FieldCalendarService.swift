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

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "FieldCalendarService")

@MainActor
@Observable
final class FieldCalendarService {

    static let shared = FieldCalendarService()

    private let store = EKEventStore()

    private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    private(set) var todayEvents: [CalendarEvent] = []

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Authorization

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess || authorizationStatus == .authorized
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

    /// Fetch events for a specific date.
    func fetchEvents(for date: Date) -> [CalendarEvent] {
        guard isAuthorized else { return [] }

        let calendar = Calendar.current
        guard let dayStart = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: date)),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
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
    /// Used by the recording tab to auto-populate participant info.
    func upcomingMeeting() -> CalendarEvent? {
        guard isAuthorized else { return nil }

        let now = Date()
        let windowStart = now.addingTimeInterval(-30 * 60)
        let windowEnd = now.addingTimeInterval(30 * 60)

        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
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

    private func makeCalendarEvent(from event: EKEvent) -> CalendarEvent {
        let attendeeNames = (event.attendees ?? [])
            .filter { $0.participantRole != .nonParticipant }
            .compactMap { attendee -> String? in
                // Prefer display name, fall back to URL-derived name
                if let name = attendee.name, !name.isEmpty {
                    return name
                }
                let email = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                if !email.isEmpty {
                    return email
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
            attendeeNames: attendeeNames
        )
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
        let attendeeNames: [String]

        init(id: String, title: String, startDate: Date, endDate: Date,
             location: String?, notes: String?, isAllDay: Bool,
             calendarName: String, calendarColor: CGColor?,
             attendeeNames: [String] = []) {
            self.id = id; self.title = title; self.startDate = startDate
            self.endDate = endDate; self.location = location; self.notes = notes
            self.isAllDay = isAllDay; self.calendarName = calendarName
            self.calendarColor = calendarColor; self.attendeeNames = attendeeNames
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
