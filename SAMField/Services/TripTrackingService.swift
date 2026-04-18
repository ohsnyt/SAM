//
//  TripTrackingService.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F3: Trip Tracking
//
//  GPS-based trip tracking with automatic stop detection.
//  Records route, detects stops via dwell time, computes distances.
//

import Foundation
import CoreLocation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "TripTrackingService")

@MainActor
@Observable
final class TripTrackingService {

    static let shared = TripTrackingService()

    // MARK: - State

    enum TrackingState: Sendable {
        case idle
        case tracking
        case paused
    }

    private(set) var state: TrackingState = .idle
    private(set) var currentTrip: SamTrip?
    private(set) var routePoints: [CLLocationCoordinate2D] = []
    private(set) var totalDistanceMiles: Double = 0

    // MARK: - Configuration

    /// Minimum dwell time (seconds) to register as a stop
    var dwellThreshold: TimeInterval = 120 // 2 minutes

    /// Distance threshold (meters) — if user stays within this radius, they're "dwelling"
    var dwellRadius: Double = 50

    // MARK: - Private

    private var container: ModelContainer?
    private let location = LocationService.shared
    private var lastMovingLocation: CLLocation?
    private var dwellStartTime: Date?
    private var dwellLocation: CLLocation?
    private var trackingTask: Task<Void, Never>?
    private var previousStopLocation: CLLocation?
    private var startAddressCaptured = false

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Trip Lifecycle

    /// Start tracking a new trip.
    func startTrip() throws {
        guard let container else { return }
        guard state == .idle else { return }

        let context = ModelContext(container)
        let trip = SamTrip(
            date: .now,
            status: .tracking,
            startedAt: .now
        )
        context.insert(trip)
        try context.save()

        currentTrip = trip
        routePoints = []
        totalDistanceMiles = 0
        lastMovingLocation = nil
        previousStopLocation = nil
        startAddressCaptured = false
        state = .tracking

        location.startUpdating()
        startTrackingLoop()

        logger.info("Started trip \(trip.id)")
    }

    /// Stop tracking and finalize the trip.
    func stopTrip() {
        guard state == .tracking || state == .paused else { return }

        trackingTask?.cancel()
        trackingTask = nil
        location.stopUpdating()

        // Finalize trip
        if let trip = currentTrip, let container {
            let context = ModelContext(container)
            let tripID = trip.id
            let descriptor = FetchDescriptor<SamTrip>(
                predicate: #Predicate { $0.id == tripID }
            )
            if let localTrip = try? context.fetch(descriptor).first {
                localTrip.endedAt = .now
                localTrip.totalDistanceMiles = totalDistanceMiles
                localTrip.status = .recorded

                // Compute business vs personal miles from stops
                let businessMiles = localTrip.stops
                    .filter { $0.purpose != .personal }
                    .compactMap(\.distanceFromPreviousMiles)
                    .reduce(0, +)
                localTrip.businessDistanceMiles = businessMiles
                localTrip.personalDistanceMiles = totalDistanceMiles - businessMiles

                try? context.save()
                logger.info("Finalized trip \(tripID): \(self.totalDistanceMiles) total miles")
            }
        }

        state = .idle
        currentTrip = nil
    }

    /// Pause tracking (e.g., user is at a long stop).
    func pauseTracking() {
        guard state == .tracking else { return }
        location.stopUpdating()
        state = .paused
        logger.info("Tracking paused")
    }

    /// Resume tracking after pause.
    func resumeTracking() {
        guard state == .paused else { return }
        location.startUpdating()
        state = .tracking
        logger.info("Tracking resumed")
    }

    // MARK: - Stop Management

    /// Manually add a stop at the current location.
    func addStopAtCurrentLocation(
        purpose: StopPurpose = .prospecting,
        locationName: String? = nil,
        notes: String? = nil
    ) async throws {
        guard let currentLocation = location.currentLocation else { return }
        try await addStop(at: currentLocation, purpose: purpose, locationName: locationName, notes: notes)
    }

    /// Add a stop at a specific location.
    func addStop(
        at clLocation: CLLocation,
        purpose: StopPurpose = .prospecting,
        locationName: String? = nil,
        notes: String? = nil
    ) async throws {
        guard let container, let trip = currentTrip else { return }

        let context = ModelContext(container)

        // Reverse geocode
        let geo = await location.reverseGeocode(clLocation)

        // Compute distance from previous stop
        var distance: Double?
        if let prev = previousStopLocation {
            distance = LocationService.distanceMiles(from: prev, to: clLocation)
        }

        let tripID = trip.id
        let descriptor = FetchDescriptor<SamTrip>(
            predicate: #Predicate { $0.id == tripID }
        )
        guard let localTrip = try? context.fetch(descriptor).first else { return }

        let stop = SamTripStop(
            latitude: clLocation.coordinate.latitude,
            longitude: clLocation.coordinate.longitude,
            address: geo?.address,
            locationName: locationName ?? geo?.name,
            arrivedAt: .now,
            distanceFromPreviousMiles: distance,
            purpose: purpose,
            notes: notes,
            sortOrder: localTrip.stops.count
        )
        stop.trip = localTrip
        context.insert(stop)
        try context.save()

        previousStopLocation = clLocation

        if let distance {
            totalDistanceMiles += distance
        }

        logger.info("Added stop: \(geo?.address ?? "unknown") (\(purpose.displayName))")
    }

    // MARK: - Private

    private func startTrackingLoop() {
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.state == .tracking else { continue }
                self.processLocationUpdate()
            }
        }
    }

    private func processLocationUpdate() {
        guard let current = location.currentLocation else { return }

        // Capture starting address on the first GPS fix
        if !startAddressCaptured, let trip = currentTrip, let container {
            startAddressCaptured = true
            let cloc = CLLocation(latitude: current.coordinate.latitude, longitude: current.coordinate.longitude)
            let tripID = trip.id
            Task {
                let geo = await LocationService.shared.reverseGeocode(cloc)
                let address = geo?.address ?? geo?.name
                guard let address else { return }
                let ctx = ModelContext(container)
                let desc = FetchDescriptor<SamTrip>(predicate: #Predicate { $0.id == tripID })
                if let localTrip = try? ctx.fetch(desc).first {
                    localTrip.startAddress = address
                    try? ctx.save()
                }
            }
        }

        // Add to route
        routePoints.append(current.coordinate)

        // Accumulate distance
        if let last = lastMovingLocation {
            let segmentMiles = LocationService.distanceMiles(from: last, to: current)
            if segmentMiles > 0.005 { // Ignore GPS jitter < ~25 feet
                totalDistanceMiles += segmentMiles
                lastMovingLocation = current
                // User is moving — reset dwell detection
                dwellStartTime = nil
                dwellLocation = nil
            }
        } else {
            lastMovingLocation = current
        }

        // Dwell detection: if user stays in same spot for dwellThreshold, auto-detect a stop
        if let dwellLoc = dwellLocation {
            let dist = current.distance(from: dwellLoc)
            if dist < dwellRadius {
                // Still dwelling
                if let start = dwellStartTime, Date().timeIntervalSince(start) > dwellThreshold {
                    // Auto-detected stop — only if we don't already have a recent stop here
                    dwellStartTime = nil
                    dwellLocation = nil
                    // The user should manually confirm auto-detected stops
                    logger.debug("Dwell detected at \(current.coordinate.latitude), \(current.coordinate.longitude)")
                }
            } else {
                // Moved away from dwell location
                dwellStartTime = Date()
                dwellLocation = current
            }
        } else {
            dwellStartTime = Date()
            dwellLocation = current
        }
    }

}
