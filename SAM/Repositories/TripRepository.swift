//
//  TripRepository.swift
//  SAM_crm
//
//  Created by Assistant on 4/8/26.
//  Phase F1: iOS Companion App Foundation
//
//  SwiftData CRUD operations for SamTrip and SamTripStop.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TripRepository")

@MainActor
@Observable
final class TripRepository {

    // MARK: - Singleton

    static let shared = TripRepository()

    // MARK: - Container

    private var container: ModelContainer?
    private var context: ModelContext?

    private init() {}

    /// Configure the repository with the app-wide ModelContainer.
    /// Must be called once at app launch before any operations.
    func configure(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    // MARK: - Trip Fetch Operations

    /// Fetch all trips, newest first.
    func fetchAll() throws -> [SamTrip] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamTrip>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetch a single trip by ID.
    func fetch(id: UUID) throws -> SamTrip? {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamTrip>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    /// Fetch trips within a date range.
    func fetchTrips(from startDate: Date, to endDate: Date) throws -> [SamTrip] {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamTrip>(
            predicate: #Predicate { $0.date >= startDate && $0.date <= endDate },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Fetch trips for a specific month (for monthly mileage summaries).
    func fetchTrips(year: Int, month: Int) throws -> [SamTrip] {
        let calendar = Calendar.current
        guard let startDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let endDate = calendar.date(byAdding: .month, value: 1, to: startDate) else {
            return []
        }
        return try fetchTrips(from: startDate, to: endDate)
    }

    /// Fetch the currently active (tracking) trip, if any.
    func fetchActiveTrip() throws -> SamTrip? {
        guard let context else { throw RepositoryError.notConfigured }

        let trackingStatus = TripStatus.tracking.rawValue
        let descriptor = FetchDescriptor<SamTrip>(
            predicate: #Predicate { $0.statusRawValue == trackingStatus }
        )
        return try context.fetch(descriptor).first
    }

    // MARK: - Trip CRUD

    /// Create and insert a new trip.
    @discardableResult
    func createTrip(
        date: Date = .now,
        status: TripStatus = .recorded,
        notes: String? = nil,
        startedAt: Date? = nil
    ) throws -> SamTrip {
        guard let context else { throw RepositoryError.notConfigured }

        let trip = SamTrip(
            date: date,
            status: status,
            notes: notes,
            startedAt: startedAt
        )
        context.insert(trip)
        try context.save()
        logger.info("Created trip \(trip.id) on \(date)")
        return trip
    }

    /// Delete a trip and all its stops (cascade).
    func deleteTrip(_ trip: SamTrip) throws {
        guard let context else { throw RepositoryError.notConfigured }

        context.delete(trip)
        try context.save()
        logger.info("Deleted trip \(trip.id)")
    }

    /// Save any pending changes.
    func save() throws {
        guard let context else { throw RepositoryError.notConfigured }
        try context.save()
    }

    // MARK: - Trip Stop Operations

    /// Add a stop to a trip.
    @discardableResult
    func addStop(
        to trip: SamTrip,
        latitude: Double,
        longitude: Double,
        address: String? = nil,
        locationName: String? = nil,
        arrivedAt: Date = .now,
        purpose: StopPurpose = .prospecting,
        sortOrder: Int? = nil
    ) throws -> SamTripStop {
        guard let context else { throw RepositoryError.notConfigured }

        let order = sortOrder ?? trip.stops.count
        let stop = SamTripStop(
            latitude: latitude,
            longitude: longitude,
            address: address,
            locationName: locationName,
            arrivedAt: arrivedAt,
            purpose: purpose,
            sortOrder: order
        )
        stop.trip = trip
        context.insert(stop)
        try context.save()
        logger.info("Added stop to trip \(trip.id) at \(address ?? "unknown")")
        return stop
    }

    /// Fetch stops for a specific person (across all trips).
    func fetchStops(for person: SamPerson) throws -> [SamTripStop] {
        guard let context else { throw RepositoryError.notConfigured }

        let personID = person.id
        let descriptor = FetchDescriptor<SamTripStop>(
            predicate: #Predicate { $0.linkedPerson?.id == personID },
            sortBy: [SortDescriptor(\.arrivedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Sync (Phone ↔ Mac)

    /// Idempotent upsert of a trip and its stops, keyed by UUID. Used by the Mac
    /// to ingest trip records pushed from the phone, and by the phone to apply
    /// a sync bundle from the Mac on first launch.
    ///
    /// Strategy:
    /// - Match the trip by `id`. If absent, insert a new SamTrip.
    /// - Copy scalar fields from the DTO onto the trip (last-write-wins).
    /// - Match each incoming stop by `id` against the trip's existing stops.
    ///   - Existing match: copy scalar fields; preserve Mac-side relationship
    ///     enrichment (`linkedPerson`, `linkedEvidence`, `trip`).
    ///   - No match: insert a new SamTripStop attached to the trip.
    /// - Stops present on the trip but not in the DTO are removed (the phone
    ///   is authoritative on stop list membership for trips it owns).
    @discardableResult
    func upsert(dto: SamTripDTO) throws -> SamTrip {
        guard let context else { throw RepositoryError.notConfigured }

        let tripID = dto.id
        let descriptor = FetchDescriptor<SamTrip>(
            predicate: #Predicate { $0.id == tripID }
        )
        let existing = try context.fetch(descriptor).first

        let trip: SamTrip
        if let existing {
            trip = existing
        } else {
            trip = SamTrip(id: dto.id, date: dto.date)
            context.insert(trip)
        }

        // Copy scalar fields
        trip.date = dto.date
        trip.totalDistanceMiles = dto.totalDistanceMiles
        trip.businessDistanceMiles = dto.businessDistanceMiles
        trip.personalDistanceMiles = dto.personalDistanceMiles
        trip.startOdometer = dto.startOdometer
        trip.endOdometer = dto.endOdometer
        trip.statusRawValue = dto.statusRawValue
        trip.notes = dto.notes
        trip.startedAt = dto.startedAt
        trip.endedAt = dto.endedAt
        trip.startAddress = dto.startAddress
        trip.vehicle = dto.vehicle
        trip.tripPurposeRawValue = dto.tripPurposeRawValue
        trip.confirmedAt = dto.confirmedAt
        trip.isCommuting = dto.isCommuting

        // Reconcile stops by UUID
        let incomingByID = Dictionary(uniqueKeysWithValues: dto.stops.map { ($0.id, $0) })
        let existingByID = Dictionary(uniqueKeysWithValues: trip.stops.map { ($0.id, $0) })

        // Update existing or insert new
        for stopDTO in dto.stops {
            if let existingStop = existingByID[stopDTO.id] {
                existingStop.latitude = stopDTO.latitude
                existingStop.longitude = stopDTO.longitude
                existingStop.address = stopDTO.address
                existingStop.locationName = stopDTO.locationName
                existingStop.arrivedAt = stopDTO.arrivedAt
                existingStop.departedAt = stopDTO.departedAt
                existingStop.distanceFromPreviousMiles = stopDTO.distanceFromPreviousMiles
                existingStop.purposeRawValue = stopDTO.purposeRawValue
                existingStop.outcomeRawValue = stopDTO.outcomeRawValue
                existingStop.notes = stopDTO.notes
                existingStop.sortOrder = stopDTO.sortOrder
            } else {
                let newStop = SamTripStop(
                    id: stopDTO.id,
                    latitude: stopDTO.latitude,
                    longitude: stopDTO.longitude,
                    address: stopDTO.address,
                    locationName: stopDTO.locationName,
                    arrivedAt: stopDTO.arrivedAt,
                    departedAt: stopDTO.departedAt,
                    distanceFromPreviousMiles: stopDTO.distanceFromPreviousMiles,
                    purpose: StopPurpose(rawValue: stopDTO.purposeRawValue) ?? .prospecting,
                    outcome: stopDTO.outcomeRawValue.flatMap { VisitOutcome(rawValue: $0) },
                    notes: stopDTO.notes,
                    sortOrder: stopDTO.sortOrder
                )
                newStop.trip = trip
                context.insert(newStop)
            }
        }

        // Delete stops the phone no longer has
        for existingStop in trip.stops where incomingByID[existingStop.id] == nil {
            context.delete(existingStop)
        }

        try context.save()
        logger.info("Upserted trip \(trip.id) with \(dto.stops.count) stops")
        return trip
    }

    /// Delete a trip by UUID. Cascades to stops. No-op if missing.
    func delete(tripID: UUID) throws {
        guard let context else { throw RepositoryError.notConfigured }

        let descriptor = FetchDescriptor<SamTrip>(
            predicate: #Predicate { $0.id == tripID }
        )
        guard let trip = try context.fetch(descriptor).first else { return }
        context.delete(trip)
        try context.save()
        logger.info("Deleted trip \(tripID) via sync")
    }

    /// Build a `SamTripDTO` from a persistent SamTrip. Used to assemble
    /// `TripSyncBundleDTO` responses to phone restore handshakes.
    static func dto(from trip: SamTrip) -> SamTripDTO {
        let stopDTOs = trip.stops
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { stop in
                TripStopDTO(
                    id: stop.id,
                    latitude: stop.latitude,
                    longitude: stop.longitude,
                    address: stop.address,
                    locationName: stop.locationName,
                    arrivedAt: stop.arrivedAt,
                    departedAt: stop.departedAt,
                    distanceFromPreviousMiles: stop.distanceFromPreviousMiles,
                    purposeRawValue: stop.purposeRawValue,
                    outcomeRawValue: stop.outcomeRawValue,
                    notes: stop.notes,
                    sortOrder: stop.sortOrder
                )
            }
        return SamTripDTO(
            id: trip.id,
            date: trip.date,
            totalDistanceMiles: trip.totalDistanceMiles,
            businessDistanceMiles: trip.businessDistanceMiles,
            personalDistanceMiles: trip.personalDistanceMiles,
            startOdometer: trip.startOdometer,
            endOdometer: trip.endOdometer,
            statusRawValue: trip.statusRawValue,
            notes: trip.notes,
            startedAt: trip.startedAt,
            endedAt: trip.endedAt,
            startAddress: trip.startAddress,
            vehicle: trip.vehicle,
            tripPurposeRawValue: trip.tripPurposeRawValue,
            confirmedAt: trip.confirmedAt,
            isCommuting: trip.isCommuting,
            stops: stopDTOs
        )
    }

    // MARK: - Mileage Summaries

    /// Total business miles for a given month.
    func businessMiles(year: Int, month: Int) throws -> Double {
        let trips = try fetchTrips(year: year, month: month)
        return trips.reduce(0) { $0 + $1.businessDistanceMiles }
    }

    /// Year-to-date business miles.
    func businessMilesYTD(year: Int) throws -> Double {
        let calendar = Calendar.current
        guard let startDate = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return 0
        }
        let trips = try fetchTrips(from: startDate, to: .now)
        return trips.reduce(0) { $0 + $1.businessDistanceMiles }
    }

}
