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
