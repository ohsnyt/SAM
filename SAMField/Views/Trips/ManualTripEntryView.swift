//
//  ManualTripEntryView.swift
//  SAM Field
//
//  Route-based manual trip entry. User enters start + stop addresses;
//  the app geocodes each point and computes driving distances via MKDirections
//  — the same way a live-tracked trip accumulates mileage, so IRS mileage
//  is derived (not self-reported).
//

import SwiftUI
import SwiftData
import MapKit
import CoreLocation

// MARK: - ManualStop

private struct ManualStop: Identifiable {
    var id = UUID()
    var addressText = ""
    var coordinate: CLLocationCoordinate2D?
    var geocodedAddress: String?
    var locationName = ""
    var purpose: StopPurpose = .prospecting
    var notes = ""
    var distanceFromPreviousMiles: Double?
    var segmentWaypoints: [CLLocationCoordinate2D] = []
    var isGeocoding = false
}

// MARK: - ManualTripEntryView

struct ManualTripEntryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // MARK: Trip metadata
    @State private var tripDate = Date.now
    @State private var startTime = Date.now
    @State private var endTime = Date.now
    @State private var vehicle: String
    @State private var tripPurpose: StopPurpose = .clientMeeting
    @State private var vehicles: [String]

    // MARK: Start location
    @State private var startAddressText = ""
    @State private var startCoordinate: CLLocationCoordinate2D?
    @State private var startGeocodedAddress: String?
    @State private var isGeocodingStart = false

    // MARK: Stops
    @State private var stops: [ManualStop] = [ManualStop()]

    // MARK: Map
    @State private var mapPosition: MapCameraPosition = .userLocation(fallback: .automatic)

    // MARK: UI
    @State private var showAddVehicle = false
    @State private var newVehicleName = ""
    @State private var isSaving = false
    @State private var validationError: String?

    init() {
        let loaded = VehicleStore.load()
        _vehicles = State(initialValue: loaded)
        _vehicle = State(initialValue: loaded.first ?? "Personal Vehicle")
    }

    // MARK: - Derived

    private var allPins: [CLLocationCoordinate2D] {
        ([startCoordinate] + stops.map { $0.coordinate }).compactMap { $0 }
    }

    private var routeWaypoints: [CLLocationCoordinate2D] {
        stops.flatMap { $0.segmentWaypoints }
    }

    private var totalMiles: Double {
        stops.compactMap { $0.distanceFromPreviousMiles }.reduce(0, +)
    }

    private var businessMiles: Double {
        stops.filter { $0.purpose.isBusiness }
            .compactMap { $0.distanceFromPreviousMiles }
            .reduce(0, +)
    }

    private var canSave: Bool {
        startCoordinate != nil && stops.contains { $0.coordinate != nil }
    }

    private var businessPurposes: [StopPurpose] {
        StopPurpose.allCases.filter { $0.isBusiness }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                mapSection
                tripInfoSection
                startSection
                stopsSection
                if totalMiles > 0 { mileageSummarySection }
            }
            .navigationTitle("New Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .alert("Add Vehicle", isPresented: $showAddVehicle) {
                TextField("Vehicle name", text: $newVehicleName)
                Button("Add") {
                    VehicleStore.add(newVehicleName)
                    vehicles = VehicleStore.load()
                    if !newVehicleName.trimmingCharacters(in: .whitespaces).isEmpty {
                        vehicle = newVehicleName.trimmingCharacters(in: .whitespaces)
                    }
                    newVehicleName = ""
                }
                Button("Cancel", role: .cancel) { newVehicleName = "" }
            }
            .alert("Cannot Save", isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) {
                Button("OK", role: .cancel) { validationError = nil }
            } message: {
                Text(validationError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var mapSection: some View {
        Section {
            Map(position: $mapPosition) {
                if let coord = startCoordinate {
                    Annotation("Start", coordinate: coord) {
                        ZStack {
                            Circle().fill(Color.green).frame(width: 26, height: 26)
                            Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.white)
                        }
                    }
                }
                ForEach(stops.filter { $0.coordinate != nil }, id: \.id) { stop in
                    Annotation(stop.locationName.isEmpty ? (stop.geocodedAddress ?? "") : stop.locationName,
                               coordinate: stop.coordinate!) {
                        ZStack {
                            Circle()
                                .fill(stop.purpose.isBusiness ? Color.blue : Color.gray)
                                .frame(width: 24, height: 24)
                            Image(systemName: stop.purpose.iconName)
                                .font(.caption2).foregroundStyle(.white)
                        }
                    }
                }
                if routeWaypoints.count >= 2 {
                    MapPolyline(coordinates: routeWaypoints)
                        .stroke(.blue, lineWidth: 3)
                }
            }
            .frame(height: 220)
            .listRowInsets(.init())
        }
    }

    private var tripInfoSection: some View {
        Section("Trip Info") {
            DatePicker("Date", selection: $tripDate, displayedComponents: .date)
            DatePicker("Depart", selection: $startTime, displayedComponents: .hourAndMinute)
            DatePicker("Return", selection: $endTime, displayedComponents: .hourAndMinute)

            Picker("Vehicle", selection: $vehicle) {
                ForEach(vehicles, id: \.self) { v in Text(v).tag(v) }
            }
            Button("Add Vehicle…") { showAddVehicle = true }
                .foregroundStyle(.blue)

            Picker("Purpose", selection: $tripPurpose) {
                ForEach(businessPurposes, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
        }
    }

    private var startSection: some View {
        Section("Starting From") {
            HStack {
                TextField("Address or place", text: $startAddressText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                if isGeocodingStart {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button {
                        Task { await geocodeStart() }
                    } label: {
                        Image(systemName: "location.magnifyingglass")
                    }
                    .disabled(startAddressText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let addr = startGeocodedAddress {
                Text(addr)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stopsSection: some View {
        Section("Stops") {
            ForEach($stops) { $stop in
                stopRow(stop: $stop)
            }
            .onDelete { offsets in
                stops.remove(atOffsets: offsets)
                Task { await recomputeAllSegments() }
            }
            Button {
                stops.append(ManualStop())
            } label: {
                Label("Add Stop", systemImage: "mappin.and.ellipse")
            }
        }
    }

    private func stopRow(stop: Binding<ManualStop>) -> some View {
        let s = stop.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            // Address row
            HStack {
                TextField("Address or place", text: stop.addressText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                if s.isGeocoding {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button {
                        Task { await geocodeStop(id: s.id) }
                    } label: {
                        Image(systemName: "location.magnifyingglass")
                    }
                    .disabled(s.addressText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let addr = s.geocodedAddress {
                Text(addr).font(.caption).foregroundStyle(.secondary)
            }

            // Purpose + distance
            HStack {
                Picker("", selection: stop.purpose) {
                    ForEach(StopPurpose.allCases, id: \.self) { p in
                        Label(p.displayName, systemImage: p.iconName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Spacer()

                if let dist = s.distanceFromPreviousMiles {
                    Text(String(format: "%.1f mi", dist))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Optional location name
            TextField("Business name (optional)", text: stop.locationName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Optional notes
            TextField("Notes (optional)", text: stop.notes)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var mileageSummarySection: some View {
        Section("Mileage") {
            LabeledContent("Business Miles") {
                Text(String(format: "%.1f mi", businessMiles))
                    .font(.headline.monospacedDigit())
            }
            LabeledContent("Total Miles") {
                Text(String(format: "%.1f mi", totalMiles))
                    .font(.headline.monospacedDigit())
            }
        }
    }

    // MARK: - Geocoding

    private func geocodeStart() async {
        let query = startAddressText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isGeocodingStart = true
        defer { isGeocodingStart = false }

        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.geocodeAddressString(query).first,
              let loc = placemark.location else { return }

        startCoordinate = loc.coordinate
        startGeocodedAddress = formatted(placemark)

        // Recompute first stop's segment if it has a coordinate
        if !stops.isEmpty, let firstCoord = stops[0].coordinate {
            await computeSegment(from: loc.coordinate, forStopAt: 0, to: firstCoord)
        }
        updateMapCamera()
    }

    private func geocodeStop(id: UUID) async {
        guard let idx = stops.firstIndex(where: { $0.id == id }) else { return }
        let query = stops[idx].addressText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        stops[idx].isGeocoding = true
        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.geocodeAddressString(query).first,
              let loc = placemark.location else {
            stops[idx].isGeocoding = false
            return
        }

        // Re-find index after await in case list changed
        guard let newIdx = stops.firstIndex(where: { $0.id == id }) else { return }
        stops[newIdx].coordinate = loc.coordinate
        stops[newIdx].geocodedAddress = formatted(placemark)
        if stops[newIdx].locationName.isEmpty {
            stops[newIdx].locationName = placemark.name ?? ""
        }
        stops[newIdx].isGeocoding = false

        // Segment from previous point to this stop
        let prevCoord = previousCoordinate(for: newIdx)
        if let from = prevCoord {
            await computeSegment(from: from, forStopAt: newIdx, to: loc.coordinate)
        }

        // Recompute next stop's segment (its "from" just changed)
        let nextIdx = newIdx + 1
        if nextIdx < stops.count, let nextCoord = stops[nextIdx].coordinate {
            await computeSegment(from: loc.coordinate, forStopAt: nextIdx, to: nextCoord)
        }

        updateMapCamera()
    }

    // MARK: - Routing

    private func computeSegment(from: CLLocationCoordinate2D, forStopAt idx: Int, to: CLLocationCoordinate2D) async {
        guard idx < stops.count else { return }

        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = .automobile

        if let resp = try? await MKDirections(request: req).calculate(),
           let route = resp.routes.first {
            let waypoints = UnsafeBufferPointer(start: route.polyline.points(),
                                                count: route.polyline.pointCount).map { $0.coordinate }
            stops[idx].distanceFromPreviousMiles = route.distance / 1609.344
            stops[idx].segmentWaypoints = waypoints
        } else {
            // Offline fallback: straight-line distance
            let straightLine = CLLocation(latitude: from.latitude, longitude: from.longitude)
                .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
            stops[idx].distanceFromPreviousMiles = straightLine / 1609.344
            stops[idx].segmentWaypoints = [from, to]
        }
    }

    private func recomputeAllSegments() async {
        for i in stops.indices {
            guard let coord = stops[i].coordinate,
                  let from = previousCoordinate(for: i) else { continue }
            await computeSegment(from: from, forStopAt: i, to: coord)
        }
        updateMapCamera()
    }

    private func previousCoordinate(for stopIndex: Int) -> CLLocationCoordinate2D? {
        stopIndex == 0 ? startCoordinate : stops[stopIndex - 1].coordinate
    }

    // MARK: - Map

    private func updateMapCamera() {
        guard !allPins.isEmpty else { return }
        if allPins.count == 1 {
            mapPosition = .region(MKCoordinateRegion(
                center: allPins[0],
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
            return
        }
        let lats = allPins.map { $0.latitude }
        let lons = allPins.map { $0.longitude }
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 1.5),
            longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.5))
        mapPosition = .region(MKCoordinateRegion(center: center, span: span))
    }

    // MARK: - Save

    private func save() async {
        guard let startCoord = startCoordinate else {
            validationError = "Please geocode your starting address before saving."
            return
        }
        guard stops.contains(where: { $0.coordinate != nil }) else {
            validationError = "Please geocode at least one stop before saving."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let cal = Calendar.current
        let startDT = combining(date: tripDate, time: startTime, using: cal)
        let endDT   = combining(date: tripDate, time: endTime, using: cal)

        let trip = SamTrip(
            date: tripDate,
            totalDistanceMiles: totalMiles,
            businessDistanceMiles: businessMiles,
            personalDistanceMiles: totalMiles - businessMiles,
            status: .confirmed,
            startedAt: startDT,
            endedAt: endDT,
            startAddress: startGeocodedAddress ?? startAddressText,
            vehicle: vehicle,
            tripPurpose: tripPurpose,
            confirmedAt: .now
        )
        modelContext.insert(trip)

        for (i, stop) in stops.enumerated() {
            guard let coord = stop.coordinate else { continue }
            let s = SamTripStop(
                latitude: coord.latitude,
                longitude: coord.longitude,
                address: stop.geocodedAddress ?? stop.addressText,
                locationName: stop.locationName.isEmpty ? nil : stop.locationName,
                arrivedAt: tripDate,
                distanceFromPreviousMiles: stop.distanceFromPreviousMiles,
                purpose: stop.purpose,
                notes: stop.notes.isEmpty ? nil : stop.notes,
                sortOrder: i
            )
            s.trip = trip
            modelContext.insert(s)
        }

        // Add start as first annotation stop for map/export completeness
        _ = startCoord // already stored in trip.startAddress

        try? modelContext.save()
        dismiss()
    }

    // MARK: - Helpers

    private func formatted(_ placemark: CLPlacemark) -> String {
        [placemark.subThoroughfare,
         placemark.thoroughfare,
         placemark.locality,
         placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func combining(date: Date, time: Date, using cal: Calendar) -> Date {
        let tc = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: tc.hour ?? 0, minute: tc.minute ?? 0, second: 0, of: date) ?? date
    }
}
