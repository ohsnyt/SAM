//
//  FieldDayCoordinator.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F4: Today Tab
//
//  Powers the Today tab — calendar events (via EventKit), pending actions,
//  recent voice captures, and daily stats.
//

import Foundation
import SwiftData
import os.log

@MainActor
@Observable
final class FieldDayCoordinator {

    static let shared = FieldDayCoordinator()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "FieldDayCoordinator")

    // MARK: - State

    /// Today's calendar events (from EventKit directly)
    private(set) var calendarEvents: [FieldCalendarService.CalendarEvent] = []

    /// People with pending follow-ups (outcomes due today or overdue)
    private(set) var pendingFollowUps: [PendingAction] = []

    /// Quick stats for today
    private(set) var todayStats: DayStats = DayStats()

    /// Recent voice captures (last 7 days)
    private(set) var recentCaptures: [SamNote] = []

    /// Whether calendar access is needed
    var needsCalendarAccess: Bool {
        !FieldCalendarService.shared.isAuthorized
    }

    private var container: ModelContainer?
    private let calendarService = FieldCalendarService.shared

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        refresh()
    }

    // MARK: - Calendar Access

    func requestCalendarAccess() async {
        _ = await calendarService.requestAccess()
        refresh()
    }

    // MARK: - Refresh

    func refresh() {
        // Calendar events (direct from EventKit)
        calendarService.refreshToday()
        calendarEvents = calendarService.todayEvents

        // SwiftData queries
        guard let container else { return }
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = Date()

        guard let todayEnd = calendar.date(byAdding: .day, value: 1,
            to: calendar.date(from: calendar.dateComponents([.year, .month, .day], from: now))!) else { return }

        // Pending outcomes (due today or overdue)
        let pendingStatus = "pending"
        let outcomeDescriptor = FetchDescriptor<SamOutcome>(
            predicate: #Predicate {
                $0.statusRawValue == pendingStatus
            },
            sortBy: [SortDescriptor(\.deadlineDate)]
        )
        let outcomes = (try? context.fetch(outcomeDescriptor)) ?? []
        pendingFollowUps = outcomes
            .filter { outcome in
                guard let deadline = outcome.deadlineDate else { return false }
                return deadline <= todayEnd
            }
            .prefix(10)
            .map { outcome in
                PendingAction(
                    id: outcome.id,
                    title: outcome.title,
                    personName: outcome.linkedPerson?.displayNameCache,
                    deadline: outcome.deadlineDate,
                    isOverdue: outcome.deadlineDate.map { $0 < now } ?? false
                )
            }

        // Recent voice captures
        let dictatedSource = "dictated"
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let captureDescriptor = FetchDescriptor<SamNote>(
            predicate: #Predicate {
                $0.sourceTypeRawValue == dictatedSource &&
                $0.createdAt >= sevenDaysAgo
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        recentCaptures = (try? context.fetch(captureDescriptor)) ?? []

        // Stats
        todayStats = DayStats(
            meetingsToday: calendarEvents.count,
            pendingActions: pendingFollowUps.count,
            capturesThisWeek: recentCaptures.count
        )

        logger.debug("Refreshed: \(self.calendarEvents.count) calendar events, \(self.pendingFollowUps.count) pending, \(self.recentCaptures.count) captures")
    }

    // MARK: - Types

    struct PendingAction: Identifiable, Sendable {
        let id: UUID
        let title: String
        let personName: String?
        let deadline: Date?
        let isOverdue: Bool
    }

    struct DayStats: Sendable {
        var meetingsToday: Int = 0
        var pendingActions: Int = 0
        var capturesThisWeek: Int = 0
    }
}
