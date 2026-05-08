//
//  TripIngestCoordinator.swift
//  SAM
//
//  Phase 0b: Trip Durability — Mac side.
//
//  Receives trip records pushed from SAM Field over the existing TCP/Bonjour
//  audio-streaming channel, applies them to the local SwiftData store via
//  TripRepository, and assembles sync bundles for the phone's first-launch
//  restore handshake.
//
//  All numerical reconciliation lives in TripRepository.upsert(dto:); this
//  coordinator is glue between AudioReceivingService callbacks and the
//  repository.
//

import Foundation
import SwiftData
import os.log

@MainActor
@Observable
final class TripIngestCoordinator {

    static let shared = TripIngestCoordinator()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TripIngestCoordinator")

    private var container: ModelContainer?

    /// Last successful ingest timestamp — surfaced in Settings/diagnostics.
    private(set) var lastIngestAt: Date?

    /// Count of trips ingested since launch (for telemetry).
    private(set) var ingestedCount: Int = 0

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Inbound (Phone → Mac)

    /// Apply an upserted trip from the phone. Idempotent.
    func handleUpsert(_ dto: TripUpsertDTO) {
        do {
            try TripRepository.shared.upsert(dto: dto.trip)
            lastIngestAt = .now
            ingestedCount += 1
        } catch {
            logger.error("handleUpsert failed for trip \(dto.trip.id): \(error)")
        }
    }

    /// Apply a tombstone — the user deleted the trip on the phone.
    func handleDelete(_ dto: TripDeleteDTO) {
        do {
            try TripRepository.shared.delete(tripID: dto.tripID)
            lastIngestAt = .now
        } catch {
            logger.error("handleDelete failed for trip \(dto.tripID): \(error)")
        }
    }

    // MARK: - Outbound (Mac → Phone)

    /// Build a sync bundle of every trip on the Mac, in response to a
    /// `tripSyncRequest` from a freshly-installed phone.
    func gatherSyncBundle() -> TripSyncBundleDTO {
        let trips = (try? TripRepository.shared.fetchAll()) ?? []
        let dtos = trips.map { TripRepository.dto(from: $0) }
        logger.info("Assembled sync bundle with \(dtos.count) trips")
        return TripSyncBundleDTO(trips: dtos)
    }
}
