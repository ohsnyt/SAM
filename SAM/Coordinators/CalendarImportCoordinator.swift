//
//  CalendarImportCoordinator.swift
//  SAM_crm
//
//  Created on February 10, 2026.
//  Phase E: Calendar & Evidence
//
//  Orchestrates calendar event import from EKEventStore → EvidenceRepository.
//  Observes system notifications and user-triggered refreshes.
//

import Foundation
import EventKit
import Observation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CalendarImportCoordinator")

@MainActor
@Observable
final class CalendarImportCoordinator {

    // MARK: - Singleton

    static let shared = CalendarImportCoordinator()

    // MARK: - Dependencies

    private let calendarService = CalendarService.shared
    private let evidenceRepository = EvidenceRepository.shared

    // MARK: - Observable State

    /// Current import status
    var importStatus: ImportStatus = .idle

    /// Last successful import timestamp
    var lastImportedAt: Date?

    /// Total evidence items imported in last sync
    var lastImportCount: Int = 0

    /// Error message if import failed
    var lastError: String?

    // MARK: - Settings (UserDefaults-backed)

    /// Auto-import enabled (default: true)
    @ObservationIgnored
    var autoImportEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "calendarAutoImportEnabled") }
    }

    /// Selected calendar identifier to import from
    @ObservationIgnored
    var selectedCalendarIdentifier: String {
        get { UserDefaults.standard.string(forKey: "selectedCalendarIdentifier") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedCalendarIdentifier") }
    }

    /// Import interval in seconds (default: 5 minutes)
    @ObservationIgnored
    var importIntervalSeconds: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "calendarImportIntervalSeconds")
            return value > 0 ? value : 300 // Default 5 minutes
        }
        set { UserDefaults.standard.set(newValue, forKey: "calendarImportIntervalSeconds") }
    }

    // MARK: - Private State

    private var lastImportTime: Date?
    private var importTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        // Set default values if not set
        if !UserDefaults.standard.bool(forKey: "calendarAutoImportEnabledSet") {
            UserDefaults.standard.set(true, forKey: "calendarAutoImportEnabled")
            UserDefaults.standard.set(true, forKey: "calendarAutoImportEnabledSet")
        }

        setupNotificationObserver()
    }

    // MARK: - Public API

    /// Start auto-import if enabled and authorized.
    func startAutoImport() {
        guard autoImportEnabled else { return }

        Task {
            let status = await calendarService.authorizationStatus()

            guard status == .fullAccess else {
                logger.debug("Not authorized, skipping auto-import")
                return
            }

            await importNow()
        }
    }

    /// Manually trigger import (user-initiated).
    func importNow() async {
        // Cancel any pending import
        importTask?.cancel()

        // Start new import
        importTask = Task {
            await performImport()
        }

        await importTask?.value
    }

    /// Request calendar authorization (Settings-only).
    func requestAuthorization() async -> Bool {
        return await calendarService.requestAuthorization()
    }

    /// Check current authorization status.
    func checkAuthorizationStatus() async -> EKAuthorizationStatus {
        return await calendarService.authorizationStatus()
    }

    /// Fetch available calendars for selection.
    func fetchAvailableCalendars() async -> [CalendarDTO] {
        return await calendarService.fetchCalendars() ?? []
    }

    // MARK: - Private Implementation

    private func performImport() async {
        // Defer calendar import while contacts import is in progress
        if ContactsImportCoordinator.isImportingContacts {
            logger.debug("Contacts import in progress — deferring calendar import")
            importStatus = .idle
            return
        }

        // Defer if there are no people yet (ensures contacts import runs first)
        do {
            let peopleCount = try PeopleRepository.shared.count()
            if peopleCount == 0 {
                logger.debug("No people found yet — deferring calendar import")
                importStatus = .idle
                return
            }
        } catch {
            logger.warning("PeopleRepository unavailable — deferring calendar import")
            importStatus = .idle
            return
        }

        // Check if enough time has passed since last import
        if let lastImport = lastImportTime {
            let elapsed = Date().timeIntervalSince(lastImport)
            if elapsed < importIntervalSeconds {
                return
            }
        }

        importStatus = .importing
        lastError = nil

        do {
            // Check authorization
            let status = await calendarService.authorizationStatus()
            guard status == .fullAccess else {
                throw ImportError.notAuthorized
            }

            // Get selected calendar
            guard !selectedCalendarIdentifier.isEmpty else {
                throw ImportError.noCalendarsSelected
            }

            // Fetch events from single calendar
            guard let events = await calendarService.fetchRecentAndUpcomingEvents(from: [selectedCalendarIdentifier]) else {
                throw ImportError.fetchFailed
            }

            // Upsert into EvidenceRepository
            try evidenceRepository.bulkUpsert(events: events)

            // Trigger insights auto-generation after import
            InsightGenerator.shared.startAutoGeneration()

            // Prune orphaned evidence (events deleted from calendar)
            let validSourceUIDs = Set(events.map { $0.sourceUID })
            try evidenceRepository.pruneOrphans(validSourceUIDs: validSourceUIDs)

            // Update state
            lastImportedAt = Date()
            lastImportTime = Date()
            lastImportCount = events.count
            importStatus = .success

            logger.info("Import complete: \(events.count) events")

        } catch {
            lastError = error.localizedDescription
            importStatus = .failed
            logger.error("Import failed: \(error)")
        }
    }

    private func setupNotificationObserver() {
        // Observe calendar changes (nonisolated, no await needed)
        calendarService.observeCalendarChanges { [weak self] in
            guard let self = self else { return }

            logger.debug("Calendar changed, triggering import")

            Task { [weak self] in
                guard let self else { return }
                await self.importNow()
            }
        }
    }

    // MARK: - Import Status

    enum ImportStatus: Equatable {
        case idle
        case importing
        case success
        case failed

        var displayText: String {
            switch self {
            case .idle:
                return "Ready"
            case .importing:
                return "Importing..."
            case .success:
                return "Synced"
            case .failed:
                return "Failed"
            }
        }
    }

    // MARK: - Errors

    enum ImportError: Error, LocalizedError {
        case notAuthorized
        case noCalendarsSelected
        case fetchFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Calendar access not authorized. Please grant permission in Settings."
            case .noCalendarsSelected:
                return "No calendars selected. Please select calendars in Settings."
            case .fetchFailed:
                return "Failed to fetch calendar events."
            }
        }
    }
}
