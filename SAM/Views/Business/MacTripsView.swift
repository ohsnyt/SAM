//
//  MacTripsView.swift
//  SAM
//
//  macOS trip log viewer with year filter, stats, and CSV/PDF export.
//  Mirrors the iOS TripsView but uses NSSavePanel for export and
//  shows a detail sheet on row tap.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct MacTripsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SamTrip.date, order: .reverse) private var allTrips: [SamTrip]

    @AppStorage("sam.irsRatePerMile") private var irsRatePerMile: Double = 0.70

    @State private var selectedYear = Calendar.current.component(.year, from: .now)
    @State private var selectedTripID: SamTrip.ID? = nil
    @State private var isExportingPDF = false

    // MARK: - Computed

    private var availableYears: [Int] {
        let years = Set(allTrips.map { Calendar.current.component(.year, from: $0.date) })
        let current = Calendar.current.component(.year, from: .now)
        return Array(years.union([current, current - 1])).sorted(by: >)
    }

    private var filteredTrips: [SamTrip] {
        allTrips.filter { Calendar.current.component(.year, from: $0.date) == selectedYear }
    }

    private var totalBusinessMiles: Double {
        filteredTrips.filter { !$0.isCommuting }.reduce(0) { $0 + $1.businessDistanceMiles }
    }

    private var totalMiles: Double {
        filteredTrips.reduce(0) { $0 + $1.totalDistanceMiles }
    }

    private var unconfirmedCount: Int {
        filteredTrips.filter { $0.confirmedAt == nil }.count
    }

    private var selectedTrip: SamTrip? {
        guard let id = selectedTripID else { return nil }
        return filteredTrips.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Stats header
            statsHeader
                .padding()

            Divider()

            // Year picker
            HStack {
                Picker("Year", selection: $selectedYear) {
                    ForEach(availableYears, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Spacer()
                if unconfirmedCount > 0 {
                    Label("\(unconfirmedCount) unconfirmed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Trips list
            if filteredTrips.isEmpty {
                ContentUnavailableView(
                    "No Trips in \(selectedYear.formatted(.number.grouping(.never)))",
                    systemImage: "car.fill",
                    description: Text("Record trips in SAM Field on your iPhone.")
                )
            } else {
                List(filteredTrips, id: \.id, selection: $selectedTripID) { trip in
                    MacTripRow(trip: trip)
                        .tag(trip.id)
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "tablecells")
                }
                .disabled(filteredTrips.isEmpty)
                .help("Export mileage log as CSV")
            }
            ToolbarItem {
                Button {
                    Task { @MainActor in
                        isExportingPDF = true
                        await exportPDF()
                        isExportingPDF = false
                    }
                } label: {
                    if isExportingPDF {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Label("Export PDF", systemImage: "doc.fill")
                    }
                }
                .disabled(filteredTrips.isEmpty || isExportingPDF)
                .help("Export mileage log as PDF")
            }
        }
        .sheet(item: Binding(
            get: { selectedTrip },
            set: { newVal in selectedTripID = newVal?.id }
        )) { trip in
            MacTripDetailView(trip: trip)
                .frame(minWidth: 500, minHeight: 500)
        }
        .restoreOnUnlock(item: Binding(
            get: { selectedTrip },
            set: { newVal in selectedTripID = newVal?.id }
        ))
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        HStack(spacing: 24) {
            MacStatPill(
                value: String(format: "%.1f", totalBusinessMiles),
                label: "Business Miles",
                color: .blue
            )
            MacStatPill(
                value: String(format: "%.1f", totalMiles),
                label: "Total Miles",
                color: .secondary
            )
            MacStatPill(
                value: "\(filteredTrips.count)",
                label: "Trips",
                color: .secondary
            )
            MacStatPill(
                value: String(format: "$%.2f", totalBusinessMiles * irsRatePerMile),
                label: "Est. Deduction",
                color: .green
            )
            Spacer()
        }
    }

    // MARK: - Export

    private func exportCSV() {
        let csv = MacMileageExportService.csv(for: filteredTrips, irsRatePerMile: irsRatePerMile)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mileage_Log_\(selectedYear.formatted(.number.grouping(.never))).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    private func exportPDF() async {
        let label = String(selectedYear)
        let data = await MacMileageExportService.pdf(for: filteredTrips, irsRatePerMile: irsRatePerMile, periodLabel: label)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mileage_Log_\(selectedYear.formatted(.number.grouping(.never))).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}

// MARK: - Mac Trip Row

private struct MacTripRow: View {
    let trip: SamTrip

    private var timeRange: String {
        guard let start = trip.startedAt else {
            return trip.date.formatted(date: .abbreviated, time: .omitted)
        }
        let startStr = start.formatted(date: .abbreviated, time: .shortened)
        guard let end = trip.endedAt else { return startStr }
        return "\(startStr) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var purposeLabel: String {
        if trip.isCommuting { return "Commuting" }
        if let tp = trip.tripPurpose { return tp.displayName }
        let business = trip.stops.filter { $0.purpose.isBusiness }.map { $0.purpose }
        guard !business.isEmpty else { return trip.stops.first?.purpose.displayName ?? "Trip" }
        let counts = Dictionary(grouping: business) { $0 }
        return counts.max(by: { $0.value.count < $1.value.count })?.key.displayName ?? "Business"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(timeRange)
                        .font(.subheadline.weight(.medium))
                    if trip.confirmedAt != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if trip.isCommuting {
                        Text("Commuting")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                HStack(spacing: 6) {
                    Text(purposeLabel)
                    if !trip.vehicle.isEmpty {
                        Text("·")
                        Text(trip.vehicle)
                    }
                    if trip.confirmedAt == nil {
                        Text("· Unconfirmed")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1f mi", trip.totalDistanceMiles))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                if !trip.isCommuting && trip.businessDistanceMiles > 0 {
                    Text(String(format: "%.1f biz", trip.businessDistanceMiles))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if trip.isCommuting {
                    Text("non-deductible")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Mac Stat Pill

private struct MacStatPill: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Mac Trip Detail View

struct MacTripDetailView: View {
    let trip: SamTrip
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var vehicle: String
    @State private var selectedPurpose: StopPurpose
    @State private var isCommuting: Bool
    @State private var vehicles: [String]
    @State private var showAddVehicle = false
    @State private var newVehicleName = ""
    @State private var isConfirmed: Bool
    @State private var confirmedAt: Date?

    init(trip: SamTrip) {
        self.trip = trip
        _vehicle = State(initialValue: trip.vehicle.isEmpty ? "Personal Vehicle" : trip.vehicle)
        _selectedPurpose = State(initialValue: trip.tripPurpose ?? .clientMeeting)
        _isCommuting = State(initialValue: trip.isCommuting)
        _vehicles = State(initialValue: MacTripDetailView.loadVehicles())
        _isConfirmed = State(initialValue: trip.confirmedAt != nil)
        _confirmedAt = State(initialValue: trip.confirmedAt)
    }

    private static func loadVehicles() -> [String] {
        UserDefaults.standard.stringArray(forKey: "sam.vehicles") ?? ["Personal Vehicle", "Rental"]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.date, style: .date)
                        .font(.title2.bold())
                    HStack(spacing: 6) {
                        if isConfirmed {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("Confirmed")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "clock")
                                .foregroundStyle(.orange)
                            Text("Awaiting Confirmation")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.subheadline)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // Content
            Form {
                // Trip Details
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
                    }
                }

                // Mileage
                Section("Mileage") {
                    LabeledContent("Total Distance") {
                        Text(String(format: "%.1f mi", trip.totalDistanceMiles))
                            .font(.headline.monospacedDigit())
                    }
                    if !isCommuting && trip.businessDistanceMiles > 0 {
                        LabeledContent("Business Miles") {
                            Text(String(format: "%.1f mi", trip.businessDistanceMiles))
                                .font(.headline.monospacedDigit())
                        }
                    }
                    if isCommuting {
                        Text("Commuting trips are excluded from business miles totals.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                // Time
                if let start = trip.startedAt {
                    Section("Time") {
                        LabeledContent("Started", value: start.formatted(date: .omitted, time: .shortened))
                        if let end = trip.endedAt {
                            LabeledContent("Ended", value: end.formatted(date: .omitted, time: .shortened))
                            let d = Int(end.timeIntervalSince(start))
                            let h = d / 3600, m = (d % 3600) / 60
                            LabeledContent("Duration", value: h > 0 ? "\(h)h \(m)m" : "\(m)m")
                        }
                    }
                }

                // Stops
                if !trip.stops.isEmpty {
                    Section("Stops (\(trip.stops.count))") {
                        ForEach(trip.stops.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { stop in
                            HStack(spacing: 10) {
                                Image(systemName: stop.purpose.iconName)
                                    .foregroundStyle(stop.purpose.isBusiness ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stop.locationName ?? stop.address ?? "Stop \(stop.sortOrder + 1)")
                                        .font(.subheadline.weight(.medium))
                                    HStack(spacing: 8) {
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
                                }
                            }
                        }
                    }
                }

                // Confirmation
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
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Confirming stamps the log with today's date and time, satisfying the IRS contemporaneous record requirement.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .dismissOnLock(isPresented: $showAddVehicle)
        .alert("Add Vehicle", isPresented: $showAddVehicle) {
            TextField("Vehicle name", text: $newVehicleName)
            Button("Add") {
                let trimmed = newVehicleName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !vehicles.contains(trimmed) {
                    vehicles.append(trimmed)
                    UserDefaults.standard.set(vehicles, forKey: "sam.vehicles")
                    vehicle = trimmed
                }
                newVehicleName = ""
            }
            Button("Cancel", role: .cancel) { newVehicleName = "" }
        }
    }

    private func confirmTrip() {
        trip.vehicle = vehicle
        trip.tripPurpose = selectedPurpose
        trip.isCommuting = isCommuting
        trip.confirmedAt = .now
        trip.status = .confirmed
        try? modelContext.save()
        isConfirmed = true
        confirmedAt = trip.confirmedAt
    }
}
