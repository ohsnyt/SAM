//
//  TripSettingsView.swift
//  SAM Field
//
//  Settings for trip logging: Home address, favorite addresses, recent-address
//  cache, and the contact search radius used by the "From a contact" fill.
//

import SwiftUI
import SwiftData
import MapKit
import CoreLocation

/// AppStorage key for the contact search radius (miles) used when ranking
/// nearby contacts for the trip stop address fill.
///
/// Default is 75mi to suit rural agents; urban agents should lower it.
struct TripSettingsKeys {
    static let contactRadiusMiles = "sam.field.contactRadiusMiles"
    static let defaultContactRadiusMiles: Double = 75
}

struct TripSettingsView: View {
    @State private var service = SavedAddressService.shared
    @State private var home: SamSavedAddress?
    @State private var favorites: [SamSavedAddress] = []
    @State private var recents: [SamSavedAddress] = []

    @AppStorage(TripSettingsKeys.contactRadiusMiles)
    private var contactRadiusMiles: Double = TripSettingsKeys.defaultContactRadiusMiles

    @State private var showHomeEditor = false
    @State private var showAddFavorite = false
    @State private var favoriteToDelete: SamSavedAddress?
    @State private var showClearRecentsConfirm = false

    var body: some View {
        Form {
            // Home
            Section {
                if let home {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(home.formattedAddress)
                            .font(.body)
                        Text("Used to close round trips and detect commutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Change Home Address") { showHomeEditor = true }
                    Button("Clear Home Address", role: .destructive) {
                        service.clearHome()
                        refresh()
                    }
                } else {
                    Button {
                        showHomeEditor = true
                    } label: {
                        Label("Set Home Address", systemImage: "house.fill")
                    }
                }
            } header: {
                Text("Home")
            } footer: {
                Text("Your home address anchors round-trip close and commute detection.")
            }

            // Favorites
            Section {
                if favorites.isEmpty {
                    Text("No favorites yet. Save a frequently-visited address for one-tap selection during trip entry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(favorites, id: \.id) { fav in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fav.label).font(.body)
                            Text(fav.formattedAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                favoriteToDelete = fav
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    showAddFavorite = true
                } label: {
                    Label("Add Favorite", systemImage: "star")
                }
            } header: {
                Text("Favorite Addresses")
            } footer: {
                Text("Favorites appear at the top of address suggestions during trip entry.")
            }

            // Recents
            Section {
                if recents.isEmpty {
                    Text("Recently used addresses will appear here automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recents, id: \.id) { r in
                        Text(r.formattedAddress)
                            .font(.subheadline)
                    }
                    Button("Clear All Recent Addresses", role: .destructive) {
                        showClearRecentsConfirm = true
                    }
                }
            } header: {
                Text("Recent Addresses (\(recents.count))")
            }

            // Contact radius
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Search radius")
                        Spacer()
                        Text("\(Int(contactRadiusMiles)) mi")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $contactRadiusMiles, in: 5...150, step: 5)
                }
            } header: {
                Text("Nearby Contacts")
            } footer: {
                Text("When filling a stop address from a contact, SAM includes contacts whose addresses fall within this radius of your current location. Increase for rural areas; decrease for dense cities.")
            }
        }
        .navigationTitle("Trip Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(isPresented: $showHomeEditor, onDismiss: refresh) {
            SavedAddressEditorView(mode: .home)
        }
        .sheet(isPresented: $showAddFavorite, onDismiss: refresh) {
            SavedAddressEditorView(mode: .favorite)
        }
        .confirmationDialog(
            favoriteToDelete.map { "Delete \($0.label)?" } ?? "Delete favorite",
            isPresented: Binding(
                get: { favoriteToDelete != nil },
                set: { if !$0 { favoriteToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: favoriteToDelete
        ) { fav in
            Button("Delete", role: .destructive) {
                service.delete(fav)
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Clear all recent addresses?",
            isPresented: $showClearRecentsConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                service.clearRecents()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func refresh() {
        home = service.home()
        favorites = service.favorites()
        recents = service.recents(limit: 10)
    }
}

// MARK: - Editor

/// Modal for setting Home or adding a Favorite. Geocodes the typed address
/// via Apple Maps and lets the user confirm the resolved result.
struct SavedAddressEditorView: View {
    enum Mode { case home, favorite }

    @Environment(\.dismiss) private var dismiss
    @State private var service = SavedAddressService.shared

    let mode: Mode

    @State private var label: String = ""
    @State private var addressText: String = ""
    @State private var resolvedAddress: String?
    @State private var resolvedCoordinate: CLLocationCoordinate2D?
    @State private var isGeocoding = false
    @State private var errorMessage: String?

    private var title: String {
        mode == .home ? "Set Home Address" : "Add Favorite"
    }

    private var canSave: Bool {
        resolvedCoordinate != nil &&
        (mode == .home || !label.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if mode == .favorite {
                    Section("Label") {
                        TextField("e.g. Plano Office", text: $label)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.words)
                    }
                }

                Section("Address") {
                    HStack {
                        TextField("Street, city, state", text: $addressText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.words)
                            .onSubmit { Task { await geocode() } }
                        if isGeocoding {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Button {
                                Task { await geocode() }
                            } label: {
                                Image(systemName: "location.magnifyingglass")
                            }
                            .disabled(addressText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let resolvedAddress {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Found:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(resolvedAddress)
                                .font(.subheadline)
                        }
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func geocode() async {
        let q = addressText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isGeocoding = true
        errorMessage = nil
        defer { isGeocoding = false }

        guard let request = MKGeocodingRequest(addressString: q) else {
            errorMessage = "Couldn't build geocoding request."
            return
        }
        do {
            guard let item = try await request.mapItems.first else {
                errorMessage = "No matching address found."
                return
            }
            resolvedCoordinate = item.location.coordinate
            resolvedAddress = Self.formatted(item)
        } catch {
            errorMessage = "Lookup failed. Check your connection and try again."
        }
    }

    private static func formatted(_ item: MKMapItem) -> String {
        item.address?.fullAddress ?? item.name ?? "Unknown location"
    }

    private func save() {
        guard let coord = resolvedCoordinate,
              let addr = resolvedAddress else { return }
        switch mode {
        case .home:
            service.setHome(formattedAddress: addr, coordinate: coord)
        case .favorite:
            let finalLabel = label.trimmingCharacters(in: .whitespaces)
            service.addFavorite(label: finalLabel, formattedAddress: addr, coordinate: coord)
        }
        dismiss()
    }
}

#Preview {
    NavigationStack {
        TripSettingsView()
    }
}
