//
//  Report.swift
//  polish-bench
//
//  Aggregates per-(model, fixture) MetricRows into:
//    - `run.json` — machine-readable, full fidelity
//    - `summary.md` — human-readable side-by-side table the user can scan
//      in a single glance. Each fixture gets one row per model so the
//      same-row-different-model comparison is obvious.
//

import Foundation

struct BenchReport: Codable, Sendable {
    let modelIDs: [String]
    let fixtures: [String]
    /// Keyed by "modelID|fixtureName" so JSON round-trips cleanly.
    var rows: [String: MetricRow] = [:]

    mutating func record(modelID: String, fixtureName: String, row: MetricRow) {
        rows["\(modelID)|\(fixtureName)"] = row
    }

    func row(modelID: String, fixtureName: String) -> MetricRow? {
        rows["\(modelID)|\(fixtureName)"]
    }

    // MARK: - Markdown

    func asMarkdown() -> String {
        var out = "# polish-bench results\n\n"
        out += "Models: \(modelIDs.joined(separator: ", "))\n"
        out += "Fixtures: \(fixtures.count)\n\n"

        out += overallTable()
        out += "\n"
        out += perFixtureTables()
        return out
    }

    /// Model-level averages so "which model is better overall" is a single
    /// scan. Excludes rows with errors from the averages — errored rows are
    /// reported separately as a failure count.
    private func overallTable() -> String {
        var lines: [String] = []
        lines.append("## Overall (averaged across fixtures)")
        lines.append("")
        lines.append("| Model | Nouns | Jargon | Numbers | Len ratio | Spkr Δ | Think leak | Hedges | Avg ms | Errors |")
        lines.append("|-------|------:|-------:|--------:|----------:|-------:|-----------:|-------:|-------:|-------:|")

        for modelID in modelIDs {
            let good = fixtures.compactMap { row(modelID: modelID, fixtureName: $0) }
                .filter { $0.error == nil }
            let errors = fixtures.compactMap { row(modelID: modelID, fixtureName: $0) }
                .filter { $0.error != nil }.count

            if good.isEmpty {
                lines.append("| \(abbrev(modelID)) | — | — | — | — | — | — | — | — | **\(errors)** |")
                continue
            }

            let nouns  = mean(good.map(\.properNounRetention))
            let jargon = mean(good.map(\.jargonRetention))
            let nums   = mean(good.map(\.numberRetention))
            let ratio  = mean(good.map(\.lengthRatio))
            let spkr   = mean(good.map { Double($0.speakerLabelDelta) })
            let think  = good.map(\.thinkLeakChars).reduce(0, +)
            let hedges = good.map(\.addedHedgeCount).reduce(0, +)
            let ms     = mean(good.map { Double($0.latencyMs) })

            lines.append(
                "| \(abbrev(modelID)) | " +
                "\(pct(nouns)) | \(pct(jargon)) | \(pct(nums)) | " +
                String(format: "%.2fx", ratio) + " | " +
                String(format: "%.2f", spkr) + " | " +
                "\(think) | \(hedges) | " +
                String(format: "%.0f", ms) + " | " +
                "\(errors) |"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Per-fixture rows so the user can see outlier behavior — e.g. a
    /// model that averages 92% noun retention but drops to 40% on the
    /// "jargon-and-names" fixture is hiding a real regression.
    private func perFixtureTables() -> String {
        var lines: [String] = []
        lines.append("## Per-fixture breakdown")
        lines.append("")

        for fixture in fixtures {
            lines.append("### \(fixture)")
            lines.append("")
            lines.append("| Model | Nouns | Jargon | Numbers | Len ratio | Spkr Δ | Think | Hedges | ms | Error |")
            lines.append("|-------|------:|-------:|--------:|----------:|-------:|------:|-------:|---:|-------|")
            for modelID in modelIDs {
                guard let r = row(modelID: modelID, fixtureName: fixture) else {
                    lines.append("| \(abbrev(modelID)) | — | — | — | — | — | — | — | — | missing |")
                    continue
                }
                if let err = r.error {
                    lines.append("| \(abbrev(modelID)) | — | — | — | — | — | — | — | \(r.latencyMs) | \(err) |")
                    continue
                }
                lines.append(
                    "| \(abbrev(modelID)) | " +
                    "\(pct(r.properNounRetention)) | \(pct(r.jargonRetention)) | \(pct(r.numberRetention)) | " +
                    String(format: "%.2fx", r.lengthRatio) + " | " +
                    "\(r.speakerLabelDelta) | \(r.thinkLeakChars) | \(r.addedHedgeCount) | \(r.latencyMs) |  |"
                )
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting helpers

    private func abbrev(_ modelID: String) -> String {
        modelID.split(separator: "/").last.map(String.init) ?? modelID
    }

    private func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    private func pct(_ x: Double) -> String {
        String(format: "%3.0f%%", x * 100)
    }
}
