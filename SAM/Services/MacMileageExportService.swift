//
//  MacMileageExportService.swift
//  SAM
//
//  macOS-side mileage export service.
//  Mirrors MileageExportService (SAMField) for use in MacTripsView.
//  Uses WKWebView PDF rendering (available on macOS via WebKit).
//

import Foundation
import WebKit

struct MacMileageExportService {

    // MARK: - CSV

    static func csv(for trips: [SamTrip], irsRatePerMile: Double) -> String {
        var rows: [String] = []

        rows.append([
            "Date", "Start Time", "End Time", "Vehicle",
            "From", "Destination", "Business Purpose",
            "Who Visited", "Business Miles", "Total Miles", "Confirmed", "Notes"
        ].csvRow())

        for trip in trips.sorted(by: { $0.date < $1.date }) {
            let stops = trip.stops.sorted { $0.sortOrder < $1.sortOrder }
            let businessStops = stops.filter { $0.purpose.isBusiness }

            let purposeText: String
            if trip.isCommuting {
                purposeText = "Commuting (non-deductible)"
            } else {
                purposeText = (trip.tripPurpose ?? primaryPurpose(from: businessStops)).map { $0.displayName } ?? ""
            }

            let bizMiles = trip.isCommuting ? "0.0" : String(format: "%.1f", trip.businessDistanceMiles)

            let confirmedText: String
            if let confirmedAt = trip.confirmedAt {
                confirmedText = confirmedAt.formatted(date: .abbreviated, time: .shortened)
            } else {
                confirmedText = "—"
            }

            let row = [
                trip.date.formatted(date: .numeric, time: .omitted),
                trip.startedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "",
                trip.endedAt.map   { $0.formatted(date: .omitted, time: .shortened) } ?? "",
                trip.vehicle,
                trip.startAddress ?? "",
                stops.last.flatMap { $0.locationName ?? $0.address } ?? "",
                purposeText,
                businessStops.compactMap { $0.locationName ?? $0.address }.joined(separator: "; "),
                bizMiles,
                String(format: "%.1f", trip.totalDistanceMiles),
                confirmedText,
                allNotes(for: trip, stops: stops)
            ]
            rows.append(row.csvRow())
        }

        let bizTotal  = trips.filter { !$0.isCommuting }.reduce(0) { $0 + $1.businessDistanceMiles }
        let allTotal  = trips.reduce(0) { $0 + $1.totalDistanceMiles }
        let deduction = bizTotal * irsRatePerMile
        let commutingCount = trips.filter { $0.isCommuting }.count
        rows.append("")
        rows.append([
            "TOTAL", "", "", "", "", "", "", "",
            String(format: "%.1f", bizTotal),
            String(format: "%.1f", allTotal),
            "",
            String(format: "Est. deduction @ $%.2f/mi: $%.2f", irsRatePerMile, deduction)
        ].csvRow())

        if commutingCount > 0 {
            rows.append([
                "NOTE: \(commutingCount) commuting trip(s) excluded from business miles total.", "", "", "", "", "", "", "", "", "", "", ""
            ].csvRow())
        }

        return "\u{FEFF}" + rows.joined(separator: "\n")
    }

    // MARK: - PDF

    @MainActor
    static func pdf(for trips: [SamTrip], irsRatePerMile: Double, periodLabel: String) async -> Data {
        let html = buildHTML(for: trips, irsRatePerMile: irsRatePerMile, periodLabel: periodLabel)
        let size = CGSize(width: 792, height: 612)
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        webView.loadHTMLString(html, baseURL: nil)
        try? await Task.sleep(for: .milliseconds(800))
        let config = WKPDFConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        return (try? await webView.pdf(configuration: config)) ?? Data()
    }

    // MARK: - Private helpers

    private static func primaryPurpose(from businessStops: [SamTripStop]) -> StopPurpose? {
        guard !businessStops.isEmpty else { return nil }
        let counts = Dictionary(grouping: businessStops) { $0.purpose }
        return counts.max(by: { $0.value.count < $1.value.count })?.key
    }

    private static func allNotes(for trip: SamTrip, stops: [SamTripStop]) -> String {
        var parts: [String] = []
        if let n = trip.notes, !n.isEmpty { parts.append(n) }
        for stop in stops {
            if let n = stop.notes, !n.isEmpty {
                let label = stop.locationName ?? stop.address ?? "Stop"
                parts.append("\(label): \(n)")
            }
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - HTML

    private static func buildHTML(for trips: [SamTrip], irsRatePerMile: Double, periodLabel: String) -> String {
        let sorted = trips.sorted { $0.date < $1.date }
        let bizTotal = sorted.filter { !$0.isCommuting }.reduce(0) { $0 + $1.businessDistanceMiles }
        let allTotal = sorted.reduce(0) { $0 + $1.totalDistanceMiles }
        let deduction = bizTotal * irsRatePerMile
        let commutingCount = sorted.filter { $0.isCommuting }.count

        var rows = ""
        for trip in sorted {
            let stops = trip.stops.sorted { $0.sortOrder < $1.sortOrder }
            let businessStops = stops.filter { $0.purpose.isBusiness }
            let purpose: String
            if trip.isCommuting {
                purpose = "Commuting"
            } else {
                purpose = trip.tripPurpose?.displayName
                    ?? primaryPurpose(from: businessStops)?.displayName
                    ?? ""
            }
            let whoVisited = businessStops.compactMap { $0.locationName ?? $0.address }.joined(separator: "; ")
            let timeRange: String = {
                guard let s = trip.startedAt else { return "" }
                let start = s.formatted(date: .omitted, time: .shortened)
                guard let e = trip.endedAt else { return start }
                return "\(start)–\(e.formatted(date: .omitted, time: .shortened))"
            }()
            let confirmedMark = trip.confirmedAt != nil ? "<span class=\"seal\">✓</span>" : ""
            let commutingMark = trip.isCommuting ? "<span class=\"commute\">C</span>" : ""
            let bizMilesDisplay = trip.isCommuting ? "—" : String(format: "%.1f", trip.businessDistanceMiles)
            let rowClass = trip.isCommuting ? " class=\"commuting-row\"" : ""

            rows += """
            <tr\(rowClass)>
              <td>\(trip.date.formatted(date: .numeric, time: .omitted)) \(confirmedMark) \(commutingMark)</td>
              <td>\(trip.vehicle.htmlEscaped)</td>
              <td>\(timeRange.htmlEscaped)</td>
              <td>\(trip.startAddress?.htmlEscaped ?? "")</td>
              <td>\(stops.last.flatMap { ($0.locationName ?? $0.address)?.htmlEscaped } ?? "")</td>
              <td>\(purpose.htmlEscaped)</td>
              <td>\(whoVisited.htmlEscaped)</td>
              <td class="num">\(bizMilesDisplay)</td>
              <td class="num">\(String(format: "%.1f", trip.totalDistanceMiles))</td>
            </tr>
            """
        }

        let generated = Date.now.formatted(date: .abbreviated, time: .shortened)
        let commutingNote = commutingCount > 0
            ? "<p style=\"margin-top:6px;\"><b>C</b> = Commuting trip (home ↔ regular office, non-deductible). \(commutingCount) commuting trip(s) excluded from business miles total.</p>"
            : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
          body { font-family: -apple-system, Helvetica Neue, Arial, sans-serif; font-size: 8.5pt; color: #1a1a1a; margin: 0; }
          h1 { font-size: 13pt; font-weight: 700; margin: 0 0 3px 0; }
          .meta { font-size: 7.5pt; color: #555; margin-bottom: 10px; }
          table { width: 100%; border-collapse: collapse; }
          th { background: #1c3557; color: #fff; font-size: 7.5pt; font-weight: 600; padding: 4px 5px; text-align: left; }
          td { font-size: 7.5pt; padding: 3px 5px; border-bottom: 1px solid #e5e5e5; vertical-align: top; }
          tr:nth-child(even) td { background: #f7f9fc; }
          .commuting-row td { background: #fdf3e7 !important; color: #a0522d; }
          .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
          tfoot td { background: #e8eef5; font-weight: 600; border-top: 2px solid #1c3557; }
          .footer { margin-top: 10px; font-size: 7pt; color: #888; }
          .seal { color: green; }
          .commute { color: #cc6600; font-weight: bold; font-size: 7pt; border: 1px solid #cc6600; border-radius: 2px; padding: 0 2px; }
        </style>
        </head>
        <body>
        <h1>Mileage Log — \(periodLabel.htmlEscaped)</h1>
        <div class="meta">IRS Rate: $\(String(format: "%.2f", irsRatePerMile))/mi &nbsp;·&nbsp; \(sorted.count) trips &nbsp;·&nbsp; Generated: \(generated)</div>
        <table>
        <thead>
          <tr>
            <th style="width:8%">Date</th>
            <th style="width:12%">Vehicle</th>
            <th style="width:10%">Time</th>
            <th style="width:14%">From</th>
            <th style="width:14%">To</th>
            <th style="width:11%">Purpose</th>
            <th style="width:18%">Who Visited</th>
            <th style="width:6%" class="num">Biz Mi</th>
            <th style="width:7%" class="num">Total Mi</th>
          </tr>
        </thead>
        <tbody>
        \(rows)
        </tbody>
        <tfoot>
          <tr>
            <td colspan="7">TOTAL (\(sorted.count) trips)</td>
            <td class="num">\(String(format: "%.1f", bizTotal))</td>
            <td class="num">\(String(format: "%.1f", allTotal))</td>
          </tr>
        </tfoot>
        </table>
        <div class="footer">
          Est. deduction: $\(String(format: "%.2f", deduction)) (\(String(format: "%.1f", bizTotal)) mi × $\(String(format: "%.2f", irsRatePerMile))/mi) — Verify with your tax advisor. Generated by SAM.
          \(commutingNote)
          <span class="seal">✓</span> = Confirmed trip record.
        </div>
        </body>
        </html>
        """
    }
}

// MARK: - CSV formatting

private extension [String] {
    func csvRow() -> String {
        map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: ",")
    }
}

// MARK: - HTML escaping

private extension String {
    var htmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
