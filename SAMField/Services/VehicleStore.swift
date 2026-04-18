//
//  VehicleStore.swift
//  SAM Field
//
//  UserDefaults-backed list of vehicles for mileage tracking.
//  "Personal Vehicle" and "Rental" are always present and cannot be removed.
//

import Foundation

enum VehicleStore {
    static let key = "sam.vehicles"
    static let systemVehicles = ["Personal Vehicle", "Rental"]

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? systemVehicles
    }

    static func save(_ list: [String]) {
        UserDefaults.standard.set(list, forKey: key)
    }

    static func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var list = load()
        guard !list.contains(trimmed) else { return }
        list.append(trimmed)
        save(list)
    }

    static func remove(at offsets: IndexSet) {
        var list = load()
        let protected = Set(systemVehicles)
        let toRemove = Set(offsets.map { list[$0] }.filter { !protected.contains($0) })
        list.removeAll { toRemove.contains($0) }
        save(list)
    }
}
