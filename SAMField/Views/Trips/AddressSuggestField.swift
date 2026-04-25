//
//  AddressSuggestField.swift
//  SAM Field
//
//  Reusable address entry with live Apple Maps autocomplete, Home chip,
//  saved favorites, and recent addresses pinned above live suggestions.
//  Replaces the free-text + magnifying-glass pattern in trip entry.
//

import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - Completer wrapper

/// Wraps `MKLocalSearchCompleter` in an `@Observable` model that publishes
/// typed-ahead results as the query changes.
@MainActor
@Observable
final class AddressCompleterModel: NSObject {
    private let completer = MKLocalSearchCompleter()

    /// Current auto-complete suggestions from Apple Maps.
    private(set) var suggestions: [MKLocalSearchCompletion] = []

    /// The last query string submitted to the completer.
    private(set) var lastQuery: String = ""

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.delegate = self
    }

    func update(query: String) {
        lastQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            suggestions = []
            completer.cancel()
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
        completer.cancel()
    }
}

extension AddressCompleterModel: @preconcurrency MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        self.suggestions = Array(completer.results.prefix(6))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        self.suggestions = []
    }
}

// MARK: - Picked address payload

struct PickedAddress {
    let formattedAddress: String
    let coordinate: CLLocationCoordinate2D
    let locationName: String?
}

// MARK: - Field

/// Address TextField + dropdown list of Home, favorites, recents, and live
/// Apple Maps results. The parent owns the resolved coordinate via `onPicked`.
struct AddressSuggestField: View {
    @Binding var text: String
    /// Called when the user picks any row (favorite, recent, or live suggestion).
    /// The caller is responsible for routing recompute + updating coordinate.
    var onPicked: (PickedAddress) -> Void

    /// Placeholder text for the TextField.
    var placeholder: String = "Address or place"

    /// Whether to show the Home row + chip at the top of the dropdown.
    var showsHome: Bool = true

    @State private var completer = AddressCompleterModel()
    @State private var service = SavedAddressService.shared
    @State private var home: SamSavedAddress?
    @State private var favorites: [SamSavedAddress] = []
    @State private var recents: [SamSavedAddress] = []
    @State private var isResolving = false

    @FocusState private var focused: Bool

    private var liveSuggestions: [MKLocalSearchCompletion] { completer.suggestions }

    private var showDropdown: Bool {
        focused && (
            !liveSuggestions.isEmpty ||
            home != nil ||
            !favorites.isEmpty ||
            !recents.isEmpty
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(placeholder, text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .focused($focused)
                    .onChange(of: text) { _, new in
                        completer.update(query: new)
                    }
                if isResolving {
                    ProgressView().scaleEffect(0.8)
                }
            }

            if showDropdown {
                dropdown
                    .padding(.top, 2)
            }
        }
        .onAppear(perform: refreshSaved)
        .onChange(of: focused) { _, isFocused in
            if isFocused { refreshSaved() }
        }
    }

    // MARK: - Dropdown

    @ViewBuilder
    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHome, let home {
                row(
                    title: home.label,
                    subtitle: home.formattedAddress,
                    systemImage: "house.fill",
                    tint: .blue
                ) {
                    pickSaved(home)
                }
                divider
            }
            if !favorites.isEmpty {
                sectionHeader("Favorites")
                ForEach(favorites, id: \.id) { fav in
                    row(
                        title: fav.label,
                        subtitle: fav.formattedAddress,
                        systemImage: "star.fill",
                        tint: .yellow
                    ) {
                        pickSaved(fav)
                    }
                }
                divider
            }
            if !recents.isEmpty && liveSuggestions.isEmpty {
                sectionHeader("Recent")
                ForEach(recents, id: \.id) { r in
                    row(
                        title: r.formattedAddress,
                        subtitle: nil,
                        systemImage: "clock",
                        tint: .secondary
                    ) {
                        pickSaved(r)
                    }
                }
                if !liveSuggestions.isEmpty { divider }
            }
            if !liveSuggestions.isEmpty {
                sectionHeader("Suggestions")
                ForEach(liveSuggestions, id: \.self) { s in
                    row(
                        title: s.title,
                        subtitle: s.subtitle.isEmpty ? nil : s.subtitle,
                        systemImage: "mappin",
                        tint: .secondary
                    ) {
                        Task { await pickCompletion(s) }
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }

    private var divider: some View {
        Divider().padding(.leading, 40)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func row<Tint: ShapeStyle>(
        title: String,
        subtitle: String?,
        systemImage: String,
        tint: Tint,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func refreshSaved() {
        home = service.home()
        favorites = service.favorites()
        recents = service.recents(limit: 5)
    }

    private func pickSaved(_ saved: SamSavedAddress) {
        text = saved.formattedAddress
        focused = false
        completer.clear()
        let coord = CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude)
        onPicked(PickedAddress(
            formattedAddress: saved.formattedAddress,
            coordinate: coord,
            locationName: saved.kind == .favorite ? saved.label : nil
        ))
        service.recordUse(formattedAddress: saved.formattedAddress, coordinate: coord)
    }

    private func pickCompletion(_ completion: MKLocalSearchCompletion) async {
        isResolving = true
        defer { isResolving = false }

        // MKLocalSearchCompletion only provides title/subtitle; we need coords
        // and a canonical address. Resolve via MKLocalSearch.
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else {
            return
        }
        let addr = item.address?.fullAddress ?? "\(completion.title), \(completion.subtitle)"
        let coord = item.location.coordinate

        text = addr
        focused = false
        completer.clear()
        onPicked(PickedAddress(
            formattedAddress: addr,
            coordinate: coord,
            locationName: item.name
        ))
        service.recordUse(formattedAddress: addr, coordinate: coord)
    }
}
