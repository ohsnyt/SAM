//
//  SavedAddressService.swift
//  SAM Field
//
//  Manages Home, favorites, and auto-captured recent addresses used by the
//  trip address autocomplete. Recents are pruned to a rolling cap.
//

import Foundation
import SwiftData
import CoreLocation
import os.log

@MainActor
@Observable
final class SavedAddressService {

    static let shared = SavedAddressService()

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "SavedAddressService")

    /// Maximum number of `.recent` addresses retained. Oldest are pruned.
    static let recentCap = 15

    private var container: ModelContainer?

    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Read

    /// The single Home address, if set.
    func home() -> SamSavedAddress? {
        guard let container else { return nil }
        let context = ModelContext(container)
        let homeRaw = SavedAddressKind.home.rawValue
        let descriptor = FetchDescriptor<SamSavedAddress>(
            predicate: #Predicate { $0.kindRawValue == homeRaw }
        )
        return (try? context.fetch(descriptor))?.first
    }

    /// All user-saved favorites, sorted by label.
    func favorites() -> [SamSavedAddress] {
        guard let container else { return [] }
        let context = ModelContext(container)
        let favRaw = SavedAddressKind.favorite.rawValue
        let descriptor = FetchDescriptor<SamSavedAddress>(
            predicate: #Predicate { $0.kindRawValue == favRaw },
            sortBy: [SortDescriptor(\SamSavedAddress.label)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Recent addresses, newest first, capped at `limit`.
    func recents(limit: Int = 5) -> [SamSavedAddress] {
        guard let container else { return [] }
        let context = ModelContext(container)
        let recentRaw = SavedAddressKind.recent.rawValue
        var descriptor = FetchDescriptor<SamSavedAddress>(
            predicate: #Predicate { $0.kindRawValue == recentRaw },
            sortBy: [SortDescriptor(\SamSavedAddress.lastUsedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Write

    /// Set or replace the Home address.
    func setHome(formattedAddress: String, coordinate: CLLocationCoordinate2D) {
        guard let container else { return }
        let context = ModelContext(container)
        let homeRaw = SavedAddressKind.home.rawValue
        let existing = (try? context.fetch(FetchDescriptor<SamSavedAddress>(
            predicate: #Predicate { $0.kindRawValue == homeRaw }
        ))) ?? []
        for row in existing {
            context.delete(row)
        }
        let home = SamSavedAddress(
            label: "Home",
            formattedAddress: formattedAddress,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            kind: .home
        )
        context.insert(home)
        try? context.save()
    }

    /// Clear the Home address.
    func clearHome() {
        guard let container else { return }
        let context = ModelContext(container)
        let homeRaw = SavedAddressKind.home.rawValue
        let existing = (try? context.fetch(FetchDescriptor<SamSavedAddress>(
            predicate: #Predicate { $0.kindRawValue == homeRaw }
        ))) ?? []
        for row in existing { context.delete(row) }
        try? context.save()
    }

    /// Add a new favorite.
    func addFavorite(label: String, formattedAddress: String, coordinate: CLLocationCoordinate2D) {
        guard let container else { return }
        let context = ModelContext(container)
        let fav = SamSavedAddress(
            label: label,
            formattedAddress: formattedAddress,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            kind: .favorite
        )
        context.insert(fav)
        try? context.save()
    }

    /// Promote a recent entry to a favorite with a user-chosen label.
    func promoteToFavorite(_ address: SamSavedAddress, label: String) {
        guard let container else { return }
        let context = ModelContext(container)
        address.kind = .favorite
        address.label = label
        try? context.save()
    }

    /// Delete a saved address.
    func delete(_ address: SamSavedAddress) {
        guard let container else { return }
        let context = ModelContext(container)
        let targetID = address.id
        if let fetched = try? context.fetch(FetchDescriptor<SamSavedAddress>(
            predicate: #Predicate { $0.id == targetID }
        )).first {
            context.delete(fetched)
            try? context.save()
        }
    }

    /// Remove all `.recent` entries.
    func clearRecents() {
        guard let container else { return }
        let context = ModelContext(container)
        let recentRaw = SavedAddressKind.recent.rawValue
        let all = (try? context.fetch(FetchDescriptor<SamSavedAddress>(
            predicate: #Predicate { $0.kindRawValue == recentRaw }
        ))) ?? []
        for row in all { context.delete(row) }
        try? context.save()
    }

    /// Record that an address was used. If a matching `.home` or `.favorite`
    /// already exists (by coordinates within ~30m), bump its `lastUsedAt`.
    /// Otherwise upsert into `.recent` and prune to `recentCap`.
    func recordUse(formattedAddress: String, coordinate: CLLocationCoordinate2D) {
        guard let container else { return }
        let context = ModelContext(container)

        // Match by coordinate proximity (~30m)
        let all = (try? context.fetch(FetchDescriptor<SamSavedAddress>())) ?? []
        let match = all.first { row in
            let dLat = abs(row.latitude - coordinate.latitude)
            let dLon = abs(row.longitude - coordinate.longitude)
            return dLat < 0.0003 && dLon < 0.0003
        }

        if let match {
            match.lastUsedAt = .now
            match.useCount += 1
            try? context.save()
            return
        }

        // New recent
        let recent = SamSavedAddress(
            label: formattedAddress,
            formattedAddress: formattedAddress,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            kind: .recent
        )
        context.insert(recent)
        try? context.save()

        pruneRecents(context: context)
    }

    private func pruneRecents(context: ModelContext) {
        let recentRaw = SavedAddressKind.recent.rawValue
        let descriptor = FetchDescriptor<SamSavedAddress>(
            predicate: #Predicate { $0.kindRawValue == recentRaw },
            sortBy: [SortDescriptor(\SamSavedAddress.lastUsedAt, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        guard rows.count > Self.recentCap else { return }
        for row in rows[Self.recentCap...] {
            context.delete(row)
        }
        try? context.save()
    }
}
