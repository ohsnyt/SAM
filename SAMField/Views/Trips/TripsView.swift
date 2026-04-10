//
//  TripsView.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F3: Trip Tracking
//
//  Trip tracking tab — map, stops, controls, mileage summaries.
//

import SwiftUI
import SwiftData
import MapKit

struct TripsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var coordinator = TripCoordinator.shared
    @State private var showAddStop = false
    @State private var stopPurpose: StopPurpose = .prospecting
    @State private var stopName = ""
    @State private var stopNotes = ""

    var body: some View {
        Group {
            if coordinator.isTracking || coordinator.isPaused {
                activeTrip
            } else {
                idleTrips
            }
        }
        .navigationTitle("Trips")
        .onAppear {
            coordinator.configure(container: modelContext.container)
        }
        .sheet(isPresented: $showAddStop) {
            addStopSheet
        }
        .sheet(isPresented: $coordinator.showTripSummary) {
            if let trip = coordinator.completedTrip {
                TripSummaryView(trip: trip)
            }
        }
    }

    // MARK: - Active Trip (Map + Controls)

    private var activeTrip: some View {
        VStack(spacing: 0) {
            // Map
            TripMapView(
                routePoints: coordinator.routePoints,
                stops: coordinator.currentTrip?.stops ?? [],
                currentLocation: coordinator.currentLocation
            )
            .frame(maxHeight: .infinity)

            // Bottom panel
            VStack(spacing: 12) {
                // Stats bar
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.isPaused ? "Paused" : "Tracking")
                            .font(.caption)
                            .foregroundStyle(coordinator.isPaused ? .orange : .green)
                        Text(String(format: "%.1f mi", coordinator.totalDistanceMiles))
                            .font(.title.monospacedDigit().bold())
                    }

                    Spacer()

                    if let trip = coordinator.currentTrip {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Stops")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(trip.stops.count)")
                                .font(.title.monospacedDigit().bold())
                        }
                    }
                }

                // Stop list (scrollable if many)
                if let trip = coordinator.currentTrip, !trip.stops.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(trip.stops.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.id) { stop in
                                StopChip(stop: stop)
                            }
                        }
                    }
                }

                // Controls
                HStack(spacing: 12) {
                    Button {
                        showAddStop = true
                    } label: {
                        Image(systemName: "mappin.and.ellipse")
                    }

                    if coordinator.isTracking {
                        Button {
                            coordinator.pauseTrip()
                        } label: {
                            Image(systemName: "pause.fill")
                        }
                    } else {
                        Button {
                            coordinator.resumeTrip()
                        } label: {
                            Image(systemName: "play.fill")
                        }
                    }

                    Button(role: .destructive) {
                        coordinator.stopTrip()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Idle (Start + History)

    private var idleTrips: some View {
        List {
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

            // Stats
            Section("Mileage Summary") {
                StatRow(label: "This Month (Business)", value: String(format: "%.1f mi", coordinator.monthBusinessMiles))
                StatRow(label: "Tax Deduction (Month)", value: String(format: "$%.2f", coordinator.monthTaxDeduction))
                StatRow(label: "Year to Date (Business)", value: String(format: "%.1f mi", coordinator.ytdBusinessMiles))
            }

            // Trip history
            if !coordinator.recentTrips.isEmpty {
                Section("Recent Trips") {
                    ForEach(coordinator.recentTrips.prefix(20), id: \.id) { trip in
                        TripHistoryRow(trip: trip)
                    }
                }
            }
        }
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
            // Route line
            if routePoints.count >= 2 {
                MapPolyline(coordinates: routePoints)
                    .stroke(.blue, lineWidth: 4)
            }

            // Stop pins
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

            // Current location
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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.date, style: .date)
                    .font(.headline)
                HStack(spacing: 8) {
                    Label("\(trip.stops.count)", systemImage: "mappin")
                    if trip.businessDistanceMiles > 0 {
                        Label(String(format: "%.1f biz mi", trip.businessDistanceMiles), systemImage: "briefcase")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.1f mi", trip.totalDistanceMiles))
                    .font(.headline.monospacedDigit())
                if trip.taxDeduction > 0 {
                    Text(String(format: "$%.2f", trip.taxDeduction))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

// MARK: - Trip Summary View

struct TripSummaryView: View {
    let trip: SamTrip
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Overview
                Section {
                    HStack {
                        Image(systemName: "car.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Trip Complete")
                                .font(.title2.bold())
                            Text(trip.date, style: .date)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                // Mileage
                Section("Mileage") {
                    StatRow(label: "Total Distance", value: String(format: "%.1f mi", trip.totalDistanceMiles))
                    StatRow(label: "Business Miles", value: String(format: "%.1f mi", trip.businessDistanceMiles))
                    StatRow(label: "Personal Miles", value: String(format: "%.1f mi", trip.personalDistanceMiles))
                    StatRow(label: "Tax Deduction", value: String(format: "$%.2f", trip.taxDeduction))
                }

                // Duration
                if let start = trip.startedAt, let end = trip.endedAt {
                    Section("Time") {
                        StatRow(label: "Started", value: start.formatted(date: .omitted, time: .shortened))
                        StatRow(label: "Ended", value: end.formatted(date: .omitted, time: .shortened))
                        let duration = end.timeIntervalSince(start)
                        let hours = Int(duration) / 3600
                        let minutes = (Int(duration) % 3600) / 60
                        StatRow(label: "Duration", value: hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
                    }
                }

                // Stops
                if !trip.stops.isEmpty {
                    Section("Stops (\(trip.stops.count))") {
                        ForEach(trip.stops.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.id) { stop in
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
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let notes = stop.notes, !notes.isEmpty {
                                    Text(notes)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
