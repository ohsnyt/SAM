//
//  TripCoordinator.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F3: Trip Tracking
//
//  Manages trip lifecycle, stop tagging, and mileage summaries.
//

import Foundation
import SwiftData
import CoreLocation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "TripCoordinator")

@MainActor
@Observable
final class TripCoordinator {

    static let shared = TripCoordinator()

    private var container: ModelContainer?
    private let tracker = TripTrackingService.shared
    private let location = LocationService.shared

    // MARK: - State

    /// Recent trips for the history list
    private(set) var recentTrips: [SamTrip] = []

    /// Current month's business miles
    private(set) var monthBusinessMiles: Double = 0

    /// Year-to-date business miles
    private(set) var ytdBusinessMiles: Double = 0

    /// The last completed trip (for summary display)
    private(set) var completedTrip: SamTrip?

    /// Count of recorded trips not yet confirmed by the user
    private(set) var unconfirmedCount: Int = 0

    /// Whether to show the trip summary sheet
    var showTripSummary = false

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
        tracker.configure(container: container)
        refreshStats()
    }

    // MARK: - Trip Controls (delegate to TripTrackingService)

    var isTracking: Bool { tracker.state == .tracking }
    var isPaused: Bool { tracker.state == .paused }
    var currentTrip: SamTrip? { tracker.currentTrip }
    var totalDistanceMiles: Double { tracker.totalDistanceMiles }
    var routePoints: [CLLocationCoordinate2D] { tracker.routePoints }

    func startTrip() {
        do {
            try tracker.startTrip()
        } catch {
            logger.error("Failed to start trip: \(error)")
        }
    }

    func stopTrip() {
        completedTrip = tracker.currentTrip
        tracker.stopTrip()
        refreshStats()
        if completedTrip != nil {
            showTripSummary = true
        }
    }

    func pauseTrip() { tracker.pauseTracking() }
    func resumeTrip() { tracker.resumeTracking() }

    // MARK: - Stops

    func addStop(
        purpose: StopPurpose = .prospecting,
        name: String? = nil,
        notes: String? = nil
    ) async {
        do {
            try await tracker.addStopAtCurrentLocation(purpose: purpose, locationName: name, notes: notes)
        } catch {
            logger.error("Failed to add stop: \(error)")
        }
    }

    /// Update a stop's outcome and optionally its purpose.
    func updateStop(_ stop: SamTripStop, outcome: VisitOutcome?, purpose: StopPurpose? = nil) {
        stop.outcome = outcome
        if let purpose { stop.purpose = purpose }
        if let container {
            let context = ModelContext(container)
            try? context.save()
        }
    }

    /// Current location from the location service.
    var currentLocation: CLLocation? { location.currentLocation }

    // MARK: - Delete

    func deleteTrip(_ trip: SamTrip, context: ModelContext) {
        context.delete(trip)
        try? context.save()
        refreshStats()
    }

    // MARK: - Stats

    func refreshStats() {
        guard let container else { return }

        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)

        // Fetch all trips
        let allDescriptor = FetchDescriptor<SamTrip>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let allTrips = (try? context.fetch(allDescriptor)) ?? []
        recentTrips = allTrips
        unconfirmedCount = allTrips.filter { $0.confirmedAt == nil && $0.statusRawValue == TripStatus.recorded.rawValue }.count

        // Current month
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return }

        let monthTrips = allTrips.filter { $0.date >= monthStart && $0.date < monthEnd }
        monthBusinessMiles = monthTrips.reduce(0) { $0 + $1.businessDistanceMiles }

        // YTD
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return }
        let ytdTrips = allTrips.filter { $0.date >= yearStart }
        ytdBusinessMiles = ytdTrips.reduce(0) { $0 + $1.businessDistanceMiles }
    }
}
