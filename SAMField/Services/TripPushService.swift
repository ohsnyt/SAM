//
//  TripPushService.swift
//  SAM Field
//
//  Phase 0b: Trip Durability.
//
//  Phone-side outbox for trip upserts and deletes. Trips live in the phone's
//  local SwiftData store; this service is the durable bridge that ensures
//  every change reaches the Mac eventually, even when the link is down at
//  the moment the change happens (which is the common case while driving).
//
//  Outbox design:
//    - `outboxUpsertIDs` — UUIDs of trips with pending upsert work. The
//      authoritative trip data still lives in SwiftData; on drain we re-fetch
//      it. This means a trip edited five times offline only sends once, with
//      the final state.
//    - `outboxDeleteIDs` — UUIDs of trips the user has deleted. We keep the
//      tombstone here because the SwiftData row is gone.
//
//  Both lists persist in UserDefaults so they survive process death. On
//  reconnect, the service drains both lists in order: deletes first, then
//  upserts (ensures a trip we deleted then a new trip with the same UUID,
//  vanishingly unlikely, doesn't fight).
//

import Foundation
import SwiftData
import os.log

@MainActor
@Observable
final class TripPushService {

    static let shared = TripPushService()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "TripPushService")

    private var container: ModelContainer?
    private var streamingService: AudioStreamingService?

    // MARK: - Persistent outbox

    private let upsertKey = "TripPushService.outboxUpsertIDs"
    private let deleteKey = "TripPushService.outboxDeleteIDs"

    private(set) var outboxUpsertIDs: Set<UUID> = []
    private(set) var outboxDeleteIDs: Set<UUID> = []

    /// True while a drain pass is mid-flight, so reconnect storms don't
    /// trigger overlapping drains.
    private var drainInProgress = false

    private init() {
        loadOutbox()
    }

    func configure(container: ModelContainer, streaming: AudioStreamingService) {
        self.container = container
        self.streamingService = streaming
    }

    // MARK: - Public API

    /// Mark a trip as needing to be pushed to the Mac. Idempotent — calling
    /// many times for the same trip while offline only causes one send on
    /// reconnect.
    func enqueueUpsert(tripID: UUID) {
        outboxUpsertIDs.insert(tripID)
        saveOutbox()
        logger.info("enqueueUpsert: \(tripID) (outbox now \(self.outboxUpsertIDs.count))")
        attemptDrain()
    }

    /// Tombstone a deleted trip. The trip row is presumed already gone from
    /// SwiftData; this just queues the delete-by-UUID message.
    func enqueueDelete(tripID: UUID) {
        // If the trip was queued for upsert but never sent, drop the upsert —
        // a delete supersedes any pending upsert.
        outboxUpsertIDs.remove(tripID)
        outboxDeleteIDs.insert(tripID)
        saveOutbox()
        logger.info("enqueueDelete: \(tripID) (outbox deletes now \(self.outboxDeleteIDs.count))")
        attemptDrain()
    }

    /// Try to send everything in the outbox. Safe to call from connect
    /// callbacks — no-ops if disconnected or already draining.
    func attemptDrain() {
        guard !drainInProgress else { return }
        guard let streaming = streamingService else { return }
        guard streaming.connectionState == .connected else { return }

        drainInProgress = true
        defer { drainInProgress = false }

        // Deletes first.
        let deletes = outboxDeleteIDs
        for tripID in deletes {
            let dto = TripDeleteDTO(tripID: tripID)
            if streaming.sendTripDelete(dto) {
                outboxDeleteIDs.remove(tripID)
            } else {
                logger.warning("drain: sendTripDelete failed for \(tripID); will retry")
                saveOutbox()
                return
            }
        }

        // Upserts next — re-fetch each from SwiftData so we send the latest
        // state, not whatever it was when we first enqueued.
        guard let container else {
            saveOutbox()
            return
        }
        let context = ModelContext(container)
        let upserts = outboxUpsertIDs
        for tripID in upserts {
            let descriptor = FetchDescriptor<SamTrip>(
                predicate: #Predicate { $0.id == tripID }
            )
            guard let trip = try? context.fetch(descriptor).first else {
                // Trip vanished — drop from outbox and move on.
                logger.warning("drain: trip \(tripID) not in store; dropping outbox entry")
                outboxUpsertIDs.remove(tripID)
                continue
            }
            let dto = TripUpsertDTO(trip: TripPushService.dto(from: trip))
            if streaming.sendTripUpsert(dto) {
                outboxUpsertIDs.remove(tripID)
            } else {
                logger.warning("drain: sendTripUpsert failed for \(tripID); will retry")
                saveOutbox()
                return
            }
        }

        saveOutbox()
        logger.info("drain complete; outbox upserts=\(self.outboxUpsertIDs.count) deletes=\(self.outboxDeleteIDs.count)")
    }

    // MARK: - DTO conversion

    /// Build a `SamTripDTO` from a phone-side SamTrip. Mirror of the Mac's
    /// `TripRepository.dto(from:)` — duplicated here because the two apps
    /// don't share a repository class (the phone has no TripRepository).
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

    // MARK: - Persistence

    private func loadOutbox() {
        if let raw = UserDefaults.standard.array(forKey: upsertKey) as? [String] {
            outboxUpsertIDs = Set(raw.compactMap(UUID.init(uuidString:)))
        }
        if let raw = UserDefaults.standard.array(forKey: deleteKey) as? [String] {
            outboxDeleteIDs = Set(raw.compactMap(UUID.init(uuidString:)))
        }
    }

    private func saveOutbox() {
        UserDefaults.standard.set(outboxUpsertIDs.map(\.uuidString), forKey: upsertKey)
        UserDefaults.standard.set(outboxDeleteIDs.map(\.uuidString), forKey: deleteKey)
    }
}
