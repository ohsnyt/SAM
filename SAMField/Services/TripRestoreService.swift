//
//  TripRestoreService.swift
//  SAM Field
//
//  Phase 0b: Trip Durability — first-launch restore handshake.
//
//  When the user reinstalls SAM Field, the local SwiftData store starts
//  empty. The Mac, however, still has every trip the phone ever pushed.
//  This service asks the Mac for that history once, applies it, and marks
//  the restore as complete so we don't ask again on every connect.
//
//  The handshake is gated on three conditions:
//    1. We've never completed a restore on this install (UserDefaults flag).
//    2. The local trip count is zero. If the user already created trips
//       offline before the Mac ever connected, we don't want to clobber them
//       with whatever the Mac has — that data flows the other way via
//       TripPushService.
//    3. The streaming service is connected and authenticated (caller's
//       responsibility — typically wired from `onAuthenticated`).
//

import Foundation
import SwiftData
import os.log

@MainActor
@Observable
final class TripRestoreService {

    static let shared = TripRestoreService()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "TripRestoreService")

    private let restoreCompleteKey = "TripRestoreService.restoreComplete"

    private init() {}

    /// True if the first-launch restore has already finished. Set after the
    /// Mac responds with a sync bundle (even an empty one — that's a valid
    /// answer).
    var hasCompletedRestore: Bool {
        UserDefaults.standard.bool(forKey: restoreCompleteKey)
    }

    /// Ask the Mac for a sync bundle if conditions warrant it. Called from
    /// `AudioStreamingService.onAuthenticated`.
    func requestSyncIfNeeded(
        container: ModelContainer,
        streaming: AudioStreamingService
    ) async {
        guard !hasCompletedRestore else { return }

        // Only restore into an empty store — never clobber local edits.
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<SamTrip>()
        let count = (try? context.fetchCount(descriptor)) ?? 0
        guard count == 0 else {
            logger.info("Skipping restore — local store has \(count) trips already; marking complete")
            UserDefaults.standard.set(true, forKey: restoreCompleteKey)
            return
        }

        let phoneID = DevicePairingService.shared.phoneDeviceID
        logger.info("Requesting trip sync bundle from Mac (phoneID=\(phoneID.uuidString))")
        _ = streaming.sendTripSyncRequest(phoneDeviceID: phoneID)
    }

    /// Apply the Mac's response. Idempotent — if the user has somehow added
    /// trips between sending the request and the response arriving, we
    /// upsert by UUID and don't lose their work. Marks the restore complete
    /// regardless of bundle size (an empty bundle is a valid answer that
    /// just means "the Mac has nothing to give you").
    func applySyncBundle(_ bundle: TripSyncBundleDTO, container: ModelContainer) {
        let context = ModelContext(container)
        var inserted = 0
        var updated = 0

        for tripDTO in bundle.trips {
            let tripID = tripDTO.id
            let descriptor = FetchDescriptor<SamTrip>(
                predicate: #Predicate { $0.id == tripID }
            )
            let existing = (try? context.fetch(descriptor).first)

            let trip: SamTrip
            if let existing {
                trip = existing
                updated += 1
            } else {
                trip = SamTrip(id: tripDTO.id, date: tripDTO.date)
                context.insert(trip)
                inserted += 1
            }

            trip.date = tripDTO.date
            trip.totalDistanceMiles = tripDTO.totalDistanceMiles
            trip.businessDistanceMiles = tripDTO.businessDistanceMiles
            trip.personalDistanceMiles = tripDTO.personalDistanceMiles
            trip.startOdometer = tripDTO.startOdometer
            trip.endOdometer = tripDTO.endOdometer
            trip.statusRawValue = tripDTO.statusRawValue
            trip.notes = tripDTO.notes
            trip.startedAt = tripDTO.startedAt
            trip.endedAt = tripDTO.endedAt
            trip.startAddress = tripDTO.startAddress
            trip.vehicle = tripDTO.vehicle
            trip.tripPurposeRawValue = tripDTO.tripPurposeRawValue
            trip.confirmedAt = tripDTO.confirmedAt
            trip.isCommuting = tripDTO.isCommuting

            // Reconcile stops by UUID
            let incomingByID = Dictionary(uniqueKeysWithValues: tripDTO.stops.map { ($0.id, $0) })
            let existingByID = Dictionary(uniqueKeysWithValues: trip.stops.map { ($0.id, $0) })

            for stopDTO in tripDTO.stops {
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

            for existingStop in trip.stops where incomingByID[existingStop.id] == nil {
                context.delete(existingStop)
            }
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: restoreCompleteKey)
        logger.info("Applied trip sync bundle: \(inserted) inserted, \(updated) updated")
    }
}
