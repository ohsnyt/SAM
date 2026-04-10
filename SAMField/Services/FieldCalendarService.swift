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
            .map { event in
                CalendarEvent(
                    id: event.eventIdentifier,
                    title: event.title ?? "Untitled",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    location: event.location,
                    notes: event.notes,
                    isAllDay: event.isAllDay,
                    calendarName: event.calendar.title,
                    calendarColor: event.calendar.cgColor
                )
            }
    }

    /// Refresh today's events.
    func refreshToday() {
        todayEvents = fetchEvents(for: .now)
        logger.debug("Fetched \(self.todayEvents.count) events for today")
    }

    // MARK: - Types

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

        /// Minutes until this event starts (negative if already started)
        var minutesUntilStart: Int {
            Int(startDate.timeIntervalSinceNow / 60)
        }

        /// Whether this event is happening now
        var isNow: Bool {
            let now = Date()
            return startDate <= now && endDate >= now
        }

        /// Whether this event is in the past
        var isPast: Bool {
            endDate < Date()
        }

        /// Duration in minutes
        var durationMinutes: Int {
            Int(endDate.timeIntervalSince(startDate) / 60)
        }
    }
}
