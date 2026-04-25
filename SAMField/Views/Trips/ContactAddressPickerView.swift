//
//  ContactAddressPickerView.swift
//  SAM Field
//
//  Ranked picker for filling a trip-stop address from a SAM contact.
//  Prioritizes today's calendar attendees, then nearby contacts (within
//  the user's configured radius), then alphabetical. Search escape hatch.
//

import SwiftUI
import SwiftData
import Contacts
import CoreLocation
import MapKit

struct ContactAddressPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var onPicked: (PickedAddress) -> Void

    @AppStorage(TripSettingsKeys.contactRadiusMiles)
    private var contactRadiusMiles: Double = TripSettingsKeys.defaultContactRadiusMiles

    @State private var isLoading = true
    @State private var candidates: [ContactCandidate] = []
    @State private var searchText = ""
    @State private var userLocation: CLLocation?

    /// One row in the picker — a SAM contact with at least one postal address.
    struct ContactCandidate: Identifiable {
        let id: String                  // contactIdentifier
        let displayName: String
        let address: String
        let coordinate: CLLocationCoordinate2D?
        let distanceMiles: Double?
        let isTodayAttendee: Bool
    }

    /// Filtered and grouped rows: today's attendees first, then within radius,
    /// then the rest. Search overrides all grouping.
    private var grouped: [(title: String, rows: [ContactCandidate])] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            let matches = candidates.filter {
                $0.displayName.lowercased().contains(query) ||
                $0.address.lowercased().contains(query)
            }
            return [(title: "Matches", rows: matches)]
        }

        let todays = candidates.filter { $0.isTodayAttendee }
        let nearby = candidates.filter {
            !$0.isTodayAttendee &&
            ($0.distanceMiles.map { $0 <= contactRadiusMiles } ?? false)
        }
        let rest = candidates.filter {
            !$0.isTodayAttendee &&
            !($0.distanceMiles.map { $0 <= contactRadiusMiles } ?? false)
        }

        var sections: [(title: String, rows: [ContactCandidate])] = []
        if !todays.isEmpty {
            sections.append(("Today's Meetings", todays))
        }
        if !nearby.isEmpty {
            let label = "Nearby (within \(Int(contactRadiusMiles)) mi)"
            sections.append((label, nearby.sorted {
                ($0.distanceMiles ?? .greatestFiniteMagnitude) < ($1.distanceMiles ?? .greatestFiniteMagnitude)
            }))
        }
        if !rest.isEmpty {
            sections.append(("All Contacts", rest.sorted { $0.displayName < $1.displayName }))
        }
        return sections
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack {
                        ProgressView("Loading contacts…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(grouped, id: \.title) { section in
                            Section(section.title) {
                                ForEach(section.rows) { row in
                                    Button {
                                        pick(row)
                                    } label: {
                                        rowView(row)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, prompt: "Search contacts")
                }
            }
            .navigationTitle("From a Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No contacts with postal addresses")
                .font(.headline)
            Text("Add postal addresses to your SAM contacts in the Contacts app to use this shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func rowView(_ row: ContactCandidate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.isTodayAttendee ? "calendar" : "mappin.and.ellipse")
                .foregroundStyle(row.isTodayAttendee ? .blue : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .foregroundStyle(.primary)
                Text(row.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let miles = row.distanceMiles {
                Text(String(format: "%.0f mi", miles))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func pick(_ row: ContactCandidate) {
        guard let coord = row.coordinate else {
            // Address without geocode — best effort
            onPicked(PickedAddress(
                formattedAddress: row.address,
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                locationName: row.displayName
            ))
            dismiss()
            return
        }
        onPicked(PickedAddress(
            formattedAddress: row.address,
            coordinate: coord,
            locationName: row.displayName
        ))
        SavedAddressService.shared.recordUse(
            formattedAddress: row.address,
            coordinate: coord
        )
        dismiss()
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        // 1) Current location for distance ranking
        userLocation = await LocationService.shared.requestCurrentLocation()

        // 2) Today's calendar attendee names
        let todayNames = Set(
            FieldCalendarService.shared.fetchEvents(for: .now)
                .flatMap { $0.attendees.map { $0.name.lowercased() } }
        )

        // 3) Active SAM persons with a contactIdentifier
        let descriptor = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.lifecycleStatusRawValue == "active" && $0.contactIdentifier != nil }
        )
        let people = (try? modelContext.fetch(descriptor)) ?? []

        // 4) Resolve CNContact postal addresses and build candidates
        let built = await buildCandidates(
            from: people,
            todayNames: todayNames,
            fromLocation: userLocation
        )
        candidates = built
    }

    private func buildCandidates(
        from people: [SamPerson],
        todayNames: Set<String>,
        fromLocation: CLLocation?
    ) async -> [ContactCandidate] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor
        ]

        var results: [ContactCandidate] = []
        for person in people {
            guard let id = person.contactIdentifier else { continue }
            guard let contact = try? store.unifiedContact(withIdentifier: id, keysToFetch: keys) else { continue }
            guard let addr = contact.postalAddresses.first?.value else { continue }

            let formatted = formatAddress(addr)
            guard !formatted.isEmpty else { continue }

            let joinedName = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let displayName = person.displayNameCache?.nilIfEmpty()
                ?? joinedName.nilIfEmpty()
                ?? contact.organizationName
            guard !displayName.isEmpty else { continue }

            let coord = await geocode(addr)
            let miles = coord.flatMap { c -> Double? in
                guard let from = fromLocation else { return nil }
                let loc = CLLocation(latitude: c.latitude, longitude: c.longitude)
                return from.distance(from: loc) / 1609.344
            }
            let isAttendee = todayNames.contains(displayName.lowercased())
            results.append(ContactCandidate(
                id: id,
                displayName: displayName,
                address: formatted,
                coordinate: coord,
                distanceMiles: miles,
                isTodayAttendee: isAttendee
            ))
        }
        return results
    }

    private func formatAddress(_ addr: CNPostalAddress) -> String {
        let parts = [
            addr.street,
            addr.city,
            addr.state,
            addr.postalCode
        ].filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }

    private func geocode(_ addr: CNPostalAddress) async -> CLLocationCoordinate2D? {
        let query = formatAddress(addr)
        guard !query.isEmpty else { return nil }
        guard let request = MKGeocodingRequest(addressString: query),
              let item = try? await request.mapItems.first else { return nil }
        return item.location.coordinate
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
