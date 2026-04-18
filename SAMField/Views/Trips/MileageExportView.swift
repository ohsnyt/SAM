//
//  MileageExportView.swift
//  SAM Field
//
//  Date range picker and CSV export for IRS mileage logs.
//

import SwiftUI
import SwiftData

struct MileageExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @AppStorage("sam.irsRatePerMile") private var irsRatePerMile: Double = 0.70

    private static let currentYear = Calendar.current.component(.year, from: .now)
    @State private var selectedYear: Int = currentYear
    @State private var useCustomRange = false
    @State private var customStart: Date = {
        Calendar.current.date(from: DateComponents(year: currentYear, month: 1, day: 1)) ?? .now
    }()
    @State private var customEnd: Date = .now
    @State private var trips: [SamTrip] = []
    @State private var exportItem: ExportItem?
    @State private var isExporting = false

    private enum ExportFormat: String, CaseIterable {
        case csv = "CSV"
        case pdf = "PDF"
    }
    @State private var exportFormat: ExportFormat = .csv

    private var availableYears: [Int] {
        [Self.currentYear, Self.currentYear - 1, Self.currentYear - 2]
    }

    private var dateRange: (start: Date, end: Date) {
        let cal = Calendar.current
        if useCustomRange {
            return (customStart, min(customEnd, .now))
        }
        let start = cal.date(from: DateComponents(year: selectedYear, month: 1, day: 1)) ?? .now
        let end   = cal.date(from: DateComponents(year: selectedYear + 1, month: 1, day: 1)) ?? .now
        return (start, end)
    }

    private var totalBusinessMiles: Double {
        trips.reduce(0) { $0 + $1.businessDistanceMiles }
    }

    private var estimatedDeduction: Double {
        totalBusinessMiles * irsRatePerMile
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section("Date Range") {
                    Toggle("Custom Range", isOn: $useCustomRange)

                    if useCustomRange {
                        DatePicker("From", selection: $customStart, displayedComponents: .date)
                        DatePicker("To", selection: $customEnd, in: customStart..., displayedComponents: .date)
                    } else {
                        Picker("Tax Year", selection: $selectedYear) {
                            ForEach(availableYears, id: \.self) { year in
                                Text(String(year)).tag(year)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("IRS Rate") {
                    HStack {
                        Text("Rate per mile")
                        Spacer()
                        TextField("0.70", value: $irsRatePerMile, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                    }
                    Text("Standard IRS mileage rate for this tax year. Update if the rate changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Summary") {
                    LabeledRow(label: "Trips", value: "\(trips.count)")
                    LabeledRow(label: "Business Miles", value: String(format: "%.1f mi", totalBusinessMiles))
                    LabeledRow(label: "Est. Deduction", value: String(format: "$%.2f", estimatedDeduction))
                }

                Section("Format") {
                    Picker("Format", selection: $exportFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(exportFormat == .csv
                         ? "CSV opens in Numbers or Excel. Best for accountants who work with spreadsheets."
                         : "PDF is a formatted, print-ready mileage log. Best for filing or emailing.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        if exportFormat == .csv {
                            exportCSV()
                        } else {
                            Task {
                                isExporting = true
                                await exportPDF()
                                isExporting = false
                            }
                        }
                    } label: {
                        if isExporting {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Generating PDF…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Export \(exportFormat.rawValue)", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(trips.isEmpty || isExporting)
                } footer: {
                    Text("Opens share sheet — save to Files, email to your accountant, or open in \(exportFormat == .csv ? "Numbers" : "Files").")
                }
            }
            .navigationTitle("Export Mileage Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { loadTrips() }
            .onChange(of: selectedYear) { _, _ in loadTrips() }
            .onChange(of: useCustomRange) { _, _ in loadTrips() }
            .onChange(of: customStart) { _, _ in loadTrips() }
            .onChange(of: customEnd) { _, _ in loadTrips() }
            .sheet(item: $exportItem) { item in
                ShareSheet(url: item.url)
            }
        }
    }

    // MARK: - Actions

    private func loadTrips() {
        let (start, end) = dateRange
        let descriptor = FetchDescriptor<SamTrip>(
            predicate: #Predicate<SamTrip> { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\SamTrip.date)]
        )
        trips = (try? modelContext.fetch(descriptor)) ?? []
    }

    private var periodLabel: String {
        useCustomRange
            ? "\(customStart.formatted(date: .abbreviated, time: .omitted)) – \(customEnd.formatted(date: .abbreviated, time: .omitted))"
            : String(selectedYear)
    }

    private func exportCSV() {
        let csv = MileageExportService.csv(for: trips, irsRatePerMile: irsRatePerMile)
        let year = useCustomRange ? Calendar.current.component(.year, from: customStart) : selectedYear
        let filename = "Mileage_Log_\(year).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        exportItem = ExportItem(url: url)
    }

    @MainActor
    private func exportPDF() async {
        let data = await MileageExportService.pdf(for: trips, irsRatePerMile: irsRatePerMile, periodLabel: periodLabel)
        let year = useCustomRange ? Calendar.current.component(.year, from: customStart) : selectedYear
        let filename = "Mileage_Log_\(year).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: url)
        exportItem = ExportItem(url: url)
    }
}

// MARK: - Helpers

private struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.headline.monospacedDigit())
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
