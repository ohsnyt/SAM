//
//  main.swift
//  polish-bench
//
//  A/B harness for the transcript-polish pipeline. Runs a curated set of
//  speaker-attributed transcripts through one or more MLX models using the
//  same system prompt the production app uses, then scores each run on
//  objective metrics (proper-noun retention, number retention, length
//  ratio, speaker-label integrity, <think> leakage, latency).
//
//  Usage:
//    polish-bench \
//      --models mlx-community/Qwen3-8B-4bit,mlx-community/Qwen3.5-9B-Instruct-4bit \
//      --fixtures ../test-kit/scenarios \
//      [--output ~/Downloads/polish-bench-<ts>]
//
//  The bench is deliberately dumb: no circuit breaker, no fallback to
//  FoundationModels, no chunk caching. If a model fails, the failure shows
//  up as a metric row with `error` populated. This keeps the comparison
//  clean — same inputs, same prompt, same chunking, only the model varies.
//

import Foundation

@main
struct PolishBenchMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let parsed: CLIArgs
        do {
            parsed = try CLIArgs.parse(args)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n\n\(CLIArgs.usage)\n".utf8))
            exit(2)
        }

        let runRoot = parsed.outputDir ?? defaultRunRoot()
        do {
            try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("failed to create output dir: \(error)\n".utf8))
            exit(1)
        }

        let fixtures: [Fixture]
        do {
            fixtures = try FixtureLoader.loadAll(at: parsed.fixturesDir)
        } catch {
            FileHandle.standardError.write(Data("failed to load fixtures at \(parsed.fixturesDir.path): \(error)\n".utf8))
            exit(1)
        }

        guard !fixtures.isEmpty else {
            FileHandle.standardError.write(Data("no fixtures found in \(parsed.fixturesDir.path)\n".utf8))
            exit(1)
        }

        print("polish-bench")
        print("  models:   \(parsed.modelIDs.joined(separator: ", "))")
        print("  fixtures: \(fixtures.count) in \(parsed.fixturesDir.path)")
        print("  output:   \(runRoot.path)")
        print("")

        var report = BenchReport(modelIDs: parsed.modelIDs, fixtures: fixtures.map(\.name))

        for modelID in parsed.modelIDs {
            let modelSlug = slug(modelID)
            print("=== model: \(modelID) ===")
            let modelDir = runRoot.appendingPathComponent(modelSlug)
            try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            let backend: MLXBackend
            do {
                backend = try await MLXBackend.load(modelID: modelID)
            } catch {
                print("  ✘ model load failed: \(error.localizedDescription)")
                for fixture in fixtures {
                    report.record(
                        modelID: modelID,
                        fixtureName: fixture.name,
                        row: MetricRow(error: "model load failed: \(error.localizedDescription)")
                    )
                }
                continue
            }

            for fixture in fixtures {
                print("  • \(fixture.name) (\(fixture.rawTranscript.count) chars)...", terminator: "")
                fflush(stdout)

                let start = Date()
                do {
                    let polished = try await PolishPipeline.run(
                        transcript: fixture.rawTranscript,
                        knownNouns: fixture.knownNouns,
                        backend: backend
                    )
                    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

                    let outURL = modelDir.appendingPathComponent("\(fixture.name).polished.txt")
                    try polished.write(to: outURL, atomically: true, encoding: .utf8)

                    let row = Metrics.score(
                        original: fixture.rawTranscript,
                        polished: polished,
                        knownNouns: fixture.knownNouns,
                        jargon: fixture.jargon,
                        latencyMs: elapsedMs
                    )
                    let metricsURL = modelDir.appendingPathComponent("\(fixture.name).metrics.json")
                    try JSONEncoder.pretty.encode(row).write(to: metricsURL)

                    report.record(modelID: modelID, fixtureName: fixture.name, row: row)
                    print(" \(elapsedMs)ms  nouns=\(pct(row.properNounRetention))  nums=\(pct(row.numberRetention))  len=\(lenRatio(row.lengthRatio))")
                } catch {
                    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                    report.record(
                        modelID: modelID,
                        fixtureName: fixture.name,
                        row: MetricRow(latencyMs: elapsedMs, error: error.localizedDescription)
                    )
                    print(" ✘ \(error.localizedDescription)")
                }
            }

            await backend.unload()
            print("")
        }

        let runJSON = runRoot.appendingPathComponent("run.json")
        let summaryMD = runRoot.appendingPathComponent("summary.md")

        do {
            try JSONEncoder.pretty.encode(report).write(to: runJSON)
            try report.asMarkdown().write(to: summaryMD, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("warning: failed to write report: \(error)\n".utf8))
        }

        print(report.asMarkdown())
        print("")
        print("Artifacts: \(runRoot.path)")

        if parsed.modelIDs.count == 2 {
            writeDiffs(
                modelA: parsed.modelIDs[0],
                modelB: parsed.modelIDs[1],
                fixtures: fixtures,
                root: runRoot
            )
        }
    }

    private static func defaultRunRoot() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return downloads.appendingPathComponent("polish-bench-\(ts)")
    }

    private static func pct(_ x: Double) -> String {
        String(format: "%3.0f%%", x * 100)
    }

    private static func lenRatio(_ x: Double) -> String {
        String(format: "%.2fx", x)
    }

    /// Emit unified diffs (original → polished) for each model, and a
    /// between-models diff of the two polished outputs, to help a human
    /// eyeball where the models actually disagree.
    private static func writeDiffs(modelA: String, modelB: String, fixtures: [Fixture], root: URL) {
        let diffDir = root.appendingPathComponent("diff-\(slug(modelA))-vs-\(slug(modelB))")
        try? FileManager.default.createDirectory(at: diffDir, withIntermediateDirectories: true)

        for fixture in fixtures {
            let a = root.appendingPathComponent(slug(modelA)).appendingPathComponent("\(fixture.name).polished.txt")
            let b = root.appendingPathComponent(slug(modelB)).appendingPathComponent("\(fixture.name).polished.txt")
            guard FileManager.default.fileExists(atPath: a.path),
                  FileManager.default.fileExists(atPath: b.path) else { continue }

            let diffURL = diffDir.appendingPathComponent("\(fixture.name).diff.txt")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            task.arguments = ["-u", a.path, b.path]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                try data.write(to: diffURL)
            } catch {
                // Silently skip — diff artifacts are best-effort, not a failure mode.
            }
        }
    }
}

// MARK: - Helpers

func slug(_ s: String) -> String {
    s.replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: " ", with: "_")
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
