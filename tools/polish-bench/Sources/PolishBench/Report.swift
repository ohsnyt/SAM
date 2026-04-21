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
        let header = ["Model", "Nouns", "Jargon", "Numbers", "Len ratio",
                      "Spkr Δ", "Think leak", "Hedges", "Avg ms", "Errors"]
        let align: [Align] = [.left, .right, .right, .right, .right,
                              .right, .right, .right, .right, .right]

        var rows: [[String]] = []
        for modelID in modelIDs {
            let good = fixtures.compactMap { row(modelID: modelID, fixtureName: $0) }
                .filter { $0.error == nil }
            let errors = fixtures.compactMap { row(modelID: modelID, fixtureName: $0) }
                .filter { $0.error != nil }.count

            if good.isEmpty {
                rows.append([abbrev(modelID), "—", "—", "—", "—", "—", "—", "—", "—", "**\(errors)**"])
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

            rows.append([
                abbrev(modelID),
                pct(nouns), pct(jargon), pct(nums),
                String(format: "%.2fx", ratio),
                String(format: "%.2f", spkr),
                "\(think)", "\(hedges)",
                String(format: "%.0f", ms),
                "\(errors)",
            ])
        }

        return "## Overall (averaged across fixtures)\n\n" +
            formatTable(header: header, rows: rows, align: align) + "\n"
    }

    /// Per-fixture rows so the user can see outlier behavior — e.g. a
    /// model that averages 92% noun retention but drops to 40% on the
    /// "jargon-and-names" fixture is hiding a real regression.
    private func perFixtureTables() -> String {
        let header = ["Model", "Nouns", "Jargon", "Numbers", "Len ratio",
                      "Spkr Δ", "Think", "Hedges", "ms", "Error"]
        let align: [Align] = [.left, .right, .right, .right, .right,
                              .right, .right, .right, .right, .left]

        var out = "## Per-fixture breakdown\n\n"
        for fixture in fixtures {
            var rows: [[String]] = []
            for modelID in modelIDs {
                guard let r = row(modelID: modelID, fixtureName: fixture) else {
                    rows.append([abbrev(modelID), "—", "—", "—", "—", "—", "—", "—", "—", "missing"])
                    continue
                }
                if let err = r.error {
                    rows.append([abbrev(modelID), "—", "—", "—", "—", "—", "—", "—", "\(r.latencyMs)", err])
                    continue
                }
                rows.append([
                    abbrev(modelID),
                    pct(r.properNounRetention),
                    pct(r.jargonRetention),
                    pct(r.numberRetention),
                    String(format: "%.2fx", r.lengthRatio),
                    "\(r.speakerLabelDelta)",
                    "\(r.thinkLeakChars)",
                    "\(r.addedHedgeCount)",
                    "\(r.latencyMs)",
                    "",
                ])
            }
            out += "### \(fixture)\n\n"
            out += formatTable(header: header, rows: rows, align: align)
            out += "\n"
        }
        return out
    }

    // MARK: - Table formatting

    private enum Align { case left, right }

    /// Pads every cell so the raw markdown also reads as a column-aligned
    /// plain-text table. Picks width per column from the widest cell,
    /// pads with spaces, keeps the `---:` alignment hint in the separator
    /// so markdown renderers still right-align numeric columns.
    private func formatTable(header: [String], rows: [[String]], align: [Align]) -> String {
        let all = [header] + rows
        var widths = header.map(\.count)
        for r in all {
            for (i, cell) in r.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        func render(_ cells: [String]) -> String {
            var s = "|"
            for (i, cell) in cells.enumerated() {
                let w = widths[i]
                let padded: String
                switch align[i] {
                case .left:  padded = cell.padding(toLength: w, withPad: " ", startingAt: 0)
                case .right: padded = String(repeating: " ", count: w - cell.count) + cell
                }
                s += " \(padded) |"
            }
            return s
        }

        func separator() -> String {
            var s = "|"
            for (i, w) in widths.enumerated() {
                let dashes = String(repeating: "-", count: w)
                switch align[i] {
                case .left:  s += " \(dashes) |"
                case .right: s += " \(String(dashes.dropLast()))" + ": |"
                }
            }
            return s
        }

        var lines: [String] = []
        lines.append(render(header))
        lines.append(separator())
        for r in rows {
            // Pad short rows so render() doesn't index out of range.
            var padded = r
            while padded.count < header.count { padded.append("") }
            lines.append(render(padded))
        }
        return lines.joined(separator: "\n") + "\n"
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
