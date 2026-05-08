//
//  TripsView.swift
//  SAM Field
//
//  Trip tracking tab — map, stops, controls, and IRS-compliant mileage history.
//

import SwiftUI
import SwiftData
import MapKit
import TipKit

// MARK: - Period Filter

private enum TripPeriod: String, CaseIterable {
    case today = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case all = "All"

    func includes(_ date: Date) -> Bool {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today: return cal.isDateInToday(date)
        case .week:  return cal.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .month: return cal.isDate(date, equalTo: now, toGranularity: .month)
        case .year:  return cal.isDate(date, equalTo: now, toGranularity: .year)
        case .all:   return true
        }
    }

    /// Whether this period should group trips into month sections.
    var groupsByMonth: Bool {
        self == .year || self == .all
    }
}

// MARK: - TripsView

struct TripsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var coordinator = TripCoordinator.shared
    @State private var selectedPeriod: TripPeriod = .month
    @State private var showExport = false
    @State private var showManualEntry = false
    @State private var showAddStop = false
    @State private var selectedTrip: SamTrip? = nil
    @State private var stopPurpose: StopPurpose = .prospecting
    @State private var stopName = ""
    @State private var stopNotes = ""

    @State private var startTip = TripStartTip()
    @State private var stopDetectionTip = TripStopDetectionTip()
    @State private var closeAtHomeTip = TripCloseAtHomeTip()
    @State private var swipeDeleteTip = TripSwipeDeleteTip()
    @State private var exportTip = TripExportTip()
    @State private var periodFilterTip = TripPeriodFilterTip()

    private var filteredTrips: [SamTrip] {
        coordinator.recentTrips.filter { selectedPeriod.includes($0.date) }
    }

    private var periodTotalMiles: Double {
        filteredTrips.reduce(0) { $0 + $1.totalDistanceMiles }
    }

    private var periodBusinessMiles: Double {
        filteredTrips.reduce(0) { $0 + $1.businessDistanceMiles }
    }

    var body: some View {
        Group {
            if coordinator.isTracking || coordinator.isPaused {
                activeTrip
            } else {
                idleTrips
            }
        }
        .navigationTitle("Trips")
        .toolbar {
            if !coordinator.isTracking && !coordinator.isPaused {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showExport = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .popoverTip(exportTip)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showManualEntry = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .onAppear {
            coordinator.configure(container: modelContext.container)
            Task { await FieldTipEvents.openedTripsTab.donate() }
        }
        .sheet(isPresented: $showExport) {
            MileageExportView()
        }
        .sheet(isPresented: $showManualEntry) {
            ManualTripEntryView()
        }
        .sheet(isPresented: $showAddStop) {
            addStopSheet
        }
        .sheet(isPresented: $coordinator.showTripSummary) {
            if let trip = coordinator.completedTrip {
                TripSummaryView(trip: trip)
            }
        }
        .onChange(of: coordinator.showTripSummary) { _, isPresented in
            if isPresented {
                Task { await FieldTipEvents.firstTripCompleted.donate() }
            }
        }
        .sheet(item: $selectedTrip) { trip in
            TripSummaryView(trip: trip)
        }
    }

    // MARK: - Active Trip

    private var activeTrip: some View {
        VStack(spacing: 0) {
            TripMapView(
                routePoints: coordinator.routePoints,
                stops: coordinator.currentTrip?.stops ?? [],
                currentLocation: coordinator.currentLocation
            )
            .frame(maxHeight: .infinity)

            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(coordinator.isPaused ? Color.orange : Color.green)
                                .frame(width: 8, height: 8)
                            Text(coordinator.isPaused ? "Paused" : "Tracking")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(coordinator.isPaused ? .orange : .green)
                        }
                        Text(String(format: "%.1f mi", coordinator.totalDistanceMiles))
                            .font(.title.monospacedDigit().bold())
                    }

                    Spacer()

                    if let trip = coordinator.currentTrip {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Stops")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(trip.stops.count)")
                                .font(.title.monospacedDigit().bold())
                        }
                    }
                }

                if let trip = coordinator.currentTrip, !trip.stops.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(trip.stops.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.id) { stop in
                                StopChip(stop: stop)
                            }
                        }
                    }
                    .popoverTip(stopDetectionTip)
                }

                HStack(spacing: 12) {
                    Button {
                        showAddStop = true
                    } label: {
                        Label("Add Stop", systemImage: "mappin.and.ellipse")
                    }

                    if coordinator.isTracking {
                        Button {
                            coordinator.pauseTrip()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                    } else {
                        Button {
                            coordinator.resumeTrip()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                    }

                    Button(role: .destructive) {
                        coordinator.stopTrip()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                if coordinator.hasHomeAddress {
                    Button {
                        Task { await coordinator.closeAtHome() }
                    } label: {
                        Label("Close at Home", systemImage: "house.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .popoverTip(closeAtHomeTip)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Idle

    private var idleTrips: some View {
        List {
            if FieldTipState.guidanceEnabled {
                Section {
                    TipView(startTip)
                        .tipViewStyle(FieldTipViewStyle())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                Button {
                    coordinator.startTrip()
                } label: {
                    Label("Start Trip", systemImage: "car.fill")
                        .font(.headline)
                }
                .disabled(!LocationService.shared.isAuthorized)
            }

            if !LocationService.shared.isAuthorized {
                Section {
                    Button("Enable Location Access") {
                        LocationService.shared.requestAuthorization()
                    }
                    .foregroundStyle(.blue)
                } footer: {
                    Text("Location access is required for trip tracking and mileage calculation.")
                }
            }

            Section {
                Picker("Period", selection: $selectedPeriod) {
                    ForEach(TripPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(.init())
                .popoverTip(periodFilterTip)
            } footer: {
                if filteredTrips.isEmpty {
                    Text("No trips recorded.")
                } else {
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f mi total", periodTotalMiles))
                        if periodBusinessMiles > 0 {
                            Text("·")
                            Text(String(format: "%.1f mi business", periodBusinessMiles))
                        }
                    }
                }
            }

            if !filteredTrips.isEmpty, FieldTipState.guidanceEnabled {
                Section {
                    TipView(swipeDeleteTip)
                        .tipViewStyle(FieldTipViewStyle())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }

            if !filteredTrips.isEmpty {
                if selectedPeriod.groupsByMonth {
                    ForEach(monthGroupedTrips, id: \.key) { group in
                        Section(group.title) {
                            ForEach(group.trips, id: \.id) { trip in
                                TripHistoryRow(trip: trip)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedTrip = trip }
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    coordinator.deleteTrip(group.trips[index], context: modelContext)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(filteredTrips, id: \.id) { trip in
                            TripHistoryRow(trip: trip)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedTrip = trip }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                coordinator.deleteTrip(filteredTrips[index], context: modelContext)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Month Grouping

    private struct MonthGroup {
        let key: Date      // first-of-month, for stable ordering
        let title: String  // "April 2026", or "April" if within current year
        let trips: [SamTrip]
    }

    private var monthGroupedTrips: [MonthGroup] {
        let cal = Calendar.current
        let currentYear = cal.component(.year, from: Date())
        let grouped = Dictionary(grouping: filteredTrips) { trip -> Date in
            let comps = cal.dateComponents([.year, .month], from: trip.date)
            return cal.date(from: comps) ?? trip.date
        }
        let formatter = DateFormatter()
        return grouped
            .map { (key, trips) -> MonthGroup in
                let year = cal.component(.year, from: key)
                formatter.dateFormat = year == currentYear ? "LLLL" : "LLLL yyyy"
                return MonthGroup(
                    key: key,
                    title: formatter.string(from: key),
                    trips: trips.sorted { $0.date > $1.date }
                )
            }
            .sorted { $0.key > $1.key }
    }

    // MARK: - Add Stop Sheet

    private var addStopSheet: some View {
        NavigationStack {
            Form {
                Picker("Purpose", selection: $stopPurpose) {
                    ForEach(StopPurpose.allCases, id: \.self) { purpose in
                        Label(purpose.displayName, systemImage: purpose.iconName)
                            .tag(purpose)
                    }
                }
                TextField("Business Name (optional)", text: $stopName)
                TextField("Notes (optional)", text: $stopNotes)
            }
            .navigationTitle("Add Stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddStop = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await coordinator.addStop(
                                purpose: stopPurpose,
                                name: stopName.isEmpty ? nil : stopName,
                                notes: stopNotes.isEmpty ? nil : stopNotes
                            )
                            stopName = ""
                            stopNotes = ""
                            showAddStop = false
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Trip Map View

struct TripMapView: View {
    let routePoints: [CLLocationCoordinate2D]
    let stops: [SamTripStop]
    let currentLocation: CLLocation?

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $position) {
            if routePoints.count >= 2 {
                MapPolyline(coordinates: routePoints)
                    .stroke(.blue, lineWidth: 4)
            }

            ForEach(stops.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.id) { stop in
                Annotation(
                    stop.locationName ?? stop.address ?? "Stop \(stop.sortOrder + 1)",
                    coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
                ) {
                    ZStack {
                        Circle()
                            .fill(stop.purpose.isBusiness ? .blue : .gray)
                            .frame(width: 28, height: 28)
                        Image(systemName: stop.purpose.iconName)
                            .font(.caption2)
                            .foregroundStyle(.white)
                    }
                }
            }

            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }
}

// MARK: - Stop Chip

private struct StopChip: View {
    let stop: SamTripStop

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: stop.purpose.iconName)
                    .font(.caption2)
                Text(stop.locationName ?? stop.address ?? "Stop \(stop.sortOrder + 1)")
                    .font(.caption)
                    .lineLimit(1)
            }
            if let outcome = stop.outcome {
                Text(outcome.displayName)
                    .font(.caption2)
                    .foregroundStyle(outcome.isPositiveContact ? .green : .secondary)
            } else {
                Text(stop.purpose.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Trip History Row

private struct TripHistoryRow: View {
    let trip: SamTrip

    private var timeRange: String {
        guard let start = trip.startedAt else {
            return trip.date.formatted(date: .abbreviated, time: .omitted)
        }
        let startStr = start.formatted(date: .omitted, time: .shortened)
        guard let end = trip.endedAt else { return startStr }
        return "\(startStr) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var locationSummary: String? {
        let from = trip.startAddress
        let sorted = trip.stops.sorted { $0.sortOrder < $1.sortOrder }
        let to = sorted.last.flatMap { $0.locationName ?? $0.address }
        if let from, let to { return "\(from) → \(to)" }
        if let from { return from }
        // Fallback: first → last stop
        let origin = sorted.first.flatMap { $0.locationName ?? $0.address }
        let dest = sorted.count > 1 ? sorted.last.flatMap { $0.locationName ?? $0.address } : nil
        if let origin, let dest { return "\(origin) → \(dest)" }
        return origin
    }

    private var primaryPurpose: String {
        if let tp = trip.tripPurpose { return tp.displayName }
        let business = trip.stops.filter { $0.purpose.isBusiness }.map { $0.purpose }
        guard !business.isEmpty else { return trip.stops.first?.purpose.displayName ?? "Trip" }
        let counts = Dictionary(grouping: business) { $0 }
        return counts.max(by: { $0.value.count < $1.value.count })?.key.displayName ?? "Business"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(timeRange)
                        .font(.subheadline.weight(.medium))
                    if trip.confirmedAt != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                if let loc = locationSummary {
                    Text(loc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(primaryPurpose)
                    if !trip.vehicle.isEmpty {
                        Text("·")
                        Text(trip.vehicle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f mi", trip.totalDistanceMiles))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                if trip.businessDistanceMiles > 0 && trip.businessDistanceMiles < trip.totalDistanceMiles {
                    Text(String(format: "%.1f biz", trip.businessDistanceMiles))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Trip Summary View

struct TripSummaryView: View {
    let trip: SamTrip
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var vehicle: String = "Personal Vehicle"
    @State private var selectedPurpose: StopPurpose = .clientMeeting
    @State private var isCommuting: Bool = false
    @State private var vehicles: [String] = VehicleStore.load()
    @State private var showAddVehicle = false
    @State private var newVehicleName = ""
    @State private var isConfirmed = false
    @State private var confirmedAt: Date?

    private var visitedStops: [SamTripStop] {
        trip.stops.filter { $0.linkedPerson != nil }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                tripDetailsSection
                if !visitedStops.isEmpty { visitedSection }
                mileageSection
                if trip.startedAt != nil { timeSection }
                if !trip.stops.isEmpty { stopsSection }
                confirmSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
        }
        .onAppear {
            vehicle = trip.vehicle.isEmpty ? (VehicleStore.load().first ?? "Personal Vehicle") : trip.vehicle
            selectedPurpose = trip.tripPurpose ?? .clientMeeting
            isCommuting = trip.isCommuting
            isConfirmed = trip.confirmedAt != nil
            confirmedAt = trip.confirmedAt
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack {
                Image(systemName: "car.fill").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trip Complete").font(.title2.bold())
                    Text(trip.date, style: .date).foregroundStyle(.secondary)
                }
                Spacer()
                if isConfirmed {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title2)
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private var tripDetailsSection: some View {
        Section("Trip Details") {
            Picker("Vehicle", selection: $vehicle) {
                ForEach(vehicles, id: \.self) { v in Text(v).tag(v) }
            }
            Button("Add Vehicle…") { showAddVehicle = true }
                .foregroundStyle(.blue)
            Picker("Purpose", selection: $selectedPurpose) {
                ForEach(StopPurpose.allCases.filter { $0.isBusiness }, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            Toggle(isOn: Binding(
                get: { isCommuting },
                set: { v in
                    isCommuting = v
                    trip.isCommuting = v
                    try? modelContext.save()
                    TripPushService.shared.enqueueUpsert(tripID: trip.id)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Commuting Trip")
                    Text("Home ↔ regular office. Not tax-deductible.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let addr = trip.startAddress {
                LabeledContent("From", value: addr)
                    .font(.subheadline)
            }
        }
    }

    private var visitedSection: some View {
        Section("Who Was Visited") {
            ForEach(visitedStops, id: \.id) { stop in
                if let person = stop.linkedPerson {
                    HStack(spacing: 10) {
                        Image(systemName: stop.purpose.iconName).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayNameCache ?? "Unknown").font(.subheadline.weight(.medium))
                            Text(stop.purpose.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let outcome = stop.outcome {
                            Text(outcome.displayName).font(.caption)
                                .foregroundStyle(outcome.isPositiveContact ? .green : .secondary)
                        }
                    }
                }
            }
        }
    }

    private var mileageSection: some View {
        Section("Mileage") {
            StatRow(label: "Total Distance", value: String(format: "%.1f mi", trip.totalDistanceMiles))
            if trip.businessDistanceMiles > 0 {
                StatRow(label: "Business Miles", value: String(format: "%.1f mi", trip.businessDistanceMiles))
            }
        }
    }

    private var timeSection: some View {
        Section("Time") {
            if let start = trip.startedAt {
                StatRow(label: "Started", value: start.formatted(date: .omitted, time: .shortened))
            }
            if let end = trip.endedAt {
                StatRow(label: "Ended", value: end.formatted(date: .omitted, time: .shortened))
                if let start = trip.startedAt {
                    let d = Int(end.timeIntervalSince(start))
                    let h = d / 3600, m = (d % 3600) / 60
                    StatRow(label: "Duration", value: h > 0 ? "\(h)h \(m)m" : "\(m)m")
                }
            }
        }
    }

    private var stopsSection: some View {
        Section("Stops (\(trip.stops.count))") {
            ForEach(trip.stops.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { stop in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: stop.purpose.iconName)
                            .foregroundStyle(stop.purpose.isBusiness ? .blue : .secondary)
                        Text(stop.locationName ?? stop.address ?? "Stop \(stop.sortOrder + 1)")
                            .font(.subheadline.weight(.medium))
                    }
                    HStack(spacing: 12) {
                        Text(stop.purpose.displayName)
                        if let outcome = stop.outcome {
                            Text(outcome.displayName)
                                .foregroundStyle(outcome.isPositiveContact ? .green : .secondary)
                        }
                        if let dist = stop.distanceFromPreviousMiles {
                            Text(String(format: "%.1f mi", dist))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let notes = stop.notes, !notes.isEmpty {
                        Text(notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var confirmSection: some View {
        Section {
            if isConfirmed, let at = confirmedAt {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trip Confirmed").font(.subheadline.weight(.medium))
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button {
                    confirmTrip()
                } label: {
                    Label("Confirm Trip", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } footer: {
            if !isConfirmed {
                Text("Confirming stamps the log with today's date and time, satisfying the IRS contemporaneous record requirement.")
            }
        }
    }

    // MARK: - Actions

    private func confirmTrip() {
        trip.vehicle = vehicle
        trip.tripPurpose = selectedPurpose
        trip.isCommuting = isCommuting
        trip.confirmedAt = .now
        trip.status = .confirmed
        try? modelContext.save()
        isConfirmed = true
        confirmedAt = trip.confirmedAt
        TripPushService.shared.enqueueUpsert(tripID: trip.id)
    }
}

// MARK: - Stat Row

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }
}

#Preview("Trips") {
    NavigationStack {
        TripsView()
    }
    .modelContainer(for: SamTrip.self, inMemory: true)
}
