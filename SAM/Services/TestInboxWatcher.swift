//
//  TestInboxWatcher.swift
//  SAM
//
//  DEBUG-only test harness that lets the development cycle bypass the
//  iPhone, network, and microphone entirely. Polls a directory for
//  WAV+metadata pairs, runs each through the same `PendingReprocessService`
//  pipeline as a real iPhone upload, and writes detailed JSON results +
//  per-cycle metrics to disk.
//
//  Workflow:
//    1. Developer drops a fixture into ~/Documents/SAM-TestKit/inbox/:
//         - foo.wav  (audio to test)
//         - foo.json (metadata: scenarioID, expectedSpeakers, etc.)
//    2. Watcher detects the pair within 1 second
//    3. Pipeline runs (transcribe → diarize → polish → summarize)
//    4. Result JSON written to ~/Documents/SAM-TestKit/outbox/foo-result.json
//    5. Metrics line appended to ~/Documents/SAM-TestKit/metrics/cycles.jsonl
//    6. Source files moved to ~/Documents/SAM-TestKit/processed/
//
//  This is gated to DEBUG builds only — production builds don't include
//  the watcher at all, so there's zero risk of accidentally activating it
//  in shipped versions.
//

#if DEBUG

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "TestInboxWatcher")

@MainActor
@Observable
final class TestInboxWatcher {

    static let shared = TestInboxWatcher()

    private init() {}

    // MARK: - State

    enum WatcherState: Sendable, Equatable {
        case stopped
        case watching
        case processing(scenarioID: String)
    }

    private(set) var state: WatcherState = .stopped
    private(set) var scenariosProcessed: Int = 0

    // MARK: - Configuration

    private var modelContainer: ModelContainer?
    private var pollTask: Task<Void, Never>?

    /// Root directory for the test harness. All inputs and outputs live here.
    private var rootDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("SAM-TestKit", isDirectory: true)
        return dir
    }

    private var inboxDirectory: URL { rootDirectory.appendingPathComponent("inbox", isDirectory: true) }
    private var outboxDirectory: URL { rootDirectory.appendingPathComponent("outbox", isDirectory: true) }
    private var processedDirectory: URL { rootDirectory.appendingPathComponent("processed", isDirectory: true) }
    private var metricsDirectory: URL { rootDirectory.appendingPathComponent("metrics", isDirectory: true) }
    private var logsDirectory: URL { rootDirectory.appendingPathComponent("logs", isDirectory: true) }
    private var promptsDirectory: URL { rootDirectory.appendingPathComponent("prompts", isDirectory: true) }
    private var promptsDefaultsDirectory: URL { promptsDirectory.appendingPathComponent("defaults", isDirectory: true) }

    private var metricsFile: URL { metricsDirectory.appendingPathComponent("cycles.jsonl") }

    // MARK: - Lifecycle

    /// Configure with a SwiftData container so the pipeline can persist
    /// transcripts the same way the live path does.
    func configure(container: ModelContainer) {
        self.modelContainer = container
    }

    /// Start watching the inbox. Idempotent.
    func start() {
        guard state == .stopped else { return }

        // Ensure the directory tree exists. The user (or a Bash script)
        // can drop files in inbox/ even if SAM hasn't created it yet.
        for dir in [inboxDirectory, outboxDirectory, processedDirectory, metricsDirectory, logsDirectory, promptsDirectory, promptsDefaultsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Opt this DEBUG-only process into the stage cache. The cache is
        // disabled by default in PendingReprocessService — this single line
        // is what makes the test harness reuse Whisper/diarize/polish/summary
        // outputs across runs when their inputs haven't changed.
        StageCache.enabled = true

        // Export the live default prompts to disk so the prompts.sh helper
        // can read them as a single source of truth. Always overwrite —
        // these are read-only references and the user's working copies live
        // in the parent prompts/ directory.
        exportDefaultPrompts()

        state = .watching
        logger.notice("📬 TestInboxWatcher started — polling \(self.inboxDirectory.path)")
        logger.notice("💾 StageCache enabled — re-runs will skip stages with unchanged inputs")
        logger.notice("📝 Default prompts exported to \(self.promptsDefaultsDirectory.path)")

        // Poll once a second for new fixtures. Polling is simpler than
        // FSEvents for our use case (low frequency, predictable inputs)
        // and the latency cost is negligible compared to pipeline processing.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.scanInbox()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        state = .stopped
        logger.info("TestInboxWatcher stopped")
    }

    // MARK: - Prompt Defaults Export

    /// Write the live default polish + summary prompts to disk so the
    /// `prompts.sh` helper script can use them as a starting point. These
    /// files are read-only reference copies — user edits live in the parent
    /// `prompts/` directory and are written to UserDefaults via the script.
    private func exportDefaultPrompts() {
        let polishURL = promptsDefaultsDirectory.appendingPathComponent("polish.txt")
        let summaryURL = promptsDefaultsDirectory.appendingPathComponent("summary.txt")

        do {
            try TranscriptPolishService.systemInstruction()
                .write(to: polishURL, atomically: true, encoding: .utf8)
            try MeetingSummaryService.systemInstruction()
                .write(to: summaryURL, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("Failed to export default prompts: \(error.localizedDescription)")
        }
    }

    // MARK: - Scan

    /// Look for `<name>.json` files in the inbox. For each, check if a
    /// matching `<name>.wav` exists; if so, queue them for processing.
    private func scanInbox() async {
        // Skip if we're already processing — keep things serial.
        if case .processing = state { return }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: inboxDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let metadataFiles = contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { lhs, rhs in
                // Process oldest first
                let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
                let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
                return lDate < rDate
            }

        for jsonURL in metadataFiles {
            let basename = jsonURL.deletingPathExtension().lastPathComponent
            let wavURL = inboxDirectory.appendingPathComponent("\(basename).wav")
            guard FileManager.default.fileExists(atPath: wavURL.path) else { continue }

            await processFixture(jsonURL: jsonURL, wavURL: wavURL)
            // Process one at a time; loop will pick up the next on next tick
            return
        }
    }

    // MARK: - Process Fixture

    private func processFixture(jsonURL: URL, wavURL: URL) async {
        let basename = jsonURL.deletingPathExtension().lastPathComponent

        guard let container = modelContainer else {
            logger.error("processFixture: no model container — skipping \(basename)")
            return
        }

        // Parse the metadata file
        guard let metadataData = try? Data(contentsOf: jsonURL),
              let metadata = try? JSONDecoder().decode(TestFixtureMetadata.self, from: metadataData) else {
            logger.error("processFixture: could not parse metadata for \(basename)")
            await moveFixtureToFailed(jsonURL: jsonURL, wavURL: wavURL, reason: "metadata parse failed")
            return
        }

        state = .processing(scenarioID: metadata.scenarioID)
        logger.notice("🧪 Processing fixture: \(metadata.scenarioID) (\(metadata.durationSeconds)s)")

        let cycleStart = Date()

        // Build a PendingUploadMetadata for the reprocess service
        let sessionID = metadata.sessionID ?? UUID()
        let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path)
        let byteSize = (attrs?[.size] as? Int64) ?? 0

        let uploadMeta = PendingUploadMetadata(
            sessionID: sessionID.uuidString,
            recordedAt: metadata.recordedAt ?? .now,
            durationSeconds: metadata.durationSeconds,
            sampleRate: metadata.sampleRate,
            channels: metadata.channels,
            byteSize: byteSize
        )

        // Run the pipeline
        let result = await PendingReprocessService.shared.reprocess(
            wavURL: wavURL,
            metadata: uploadMeta,
            modelContainer: container
        )

        let cycleElapsed = Date().timeIntervalSince(cycleStart)

        // Fetch the saved session to extract detailed results
        var resultPayload = await buildResultPayload(
            scenarioID: metadata.scenarioID,
            sessionID: sessionID,
            container: container,
            success: result.success,
            error: result.reason,
            cycleElapsed: cycleElapsed,
            metadata: metadata
        )

        // Breakthrough #3: if the test runner dropped a `<basename>.golden.json`
        // alongside the fixture, run the regression judge against it.
        let goldenURL = inboxDirectory.appendingPathComponent("\(basename).golden.json")
        if FileManager.default.fileExists(atPath: goldenURL.path),
           result.success {
            if let goldenData = try? Data(contentsOf: goldenURL),
               let golden = try? jsonDecoder().decode(TestResultPayload.self, from: goldenData) {
                let verdict = await RegressionJudgeService.shared.judge(
                    scenarioID: metadata.scenarioID,
                    golden: golden,
                    current: resultPayload
                )
                resultPayload.regression = verdict
                logger.notice("⚖️ Regression: \(verdict.overallKind.rawValue) — \(verdict.summary)")
            } else {
                logger.warning("⚖️ Found golden but failed to decode: \(goldenURL.lastPathComponent)")
            }
            // Clean up the inbox golden — it's transient
            try? FileManager.default.removeItem(at: goldenURL)
        }

        // Write the result JSON to the outbox
        let resultURL = outboxDirectory.appendingPathComponent("\(basename)-result.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(resultPayload)
            try data.write(to: resultURL)
            logger.notice("📄 Result written: \(resultURL.lastPathComponent)")
        } catch {
            logger.error("Could not write result: \(error.localizedDescription)")
        }

        // Append a metrics line
        appendMetricsLine(resultPayload)

        // Move the source files to processed/
        await moveFixtureToProcessed(jsonURL: jsonURL, wavURL: wavURL, basename: basename)

        scenariosProcessed += 1
        state = .watching
        logger.notice("✅ Done: \(metadata.scenarioID) — \(String(format: "%.1f", cycleElapsed))s wall clock, success=\(result.success)")
    }

    // MARK: - Result Payload

    private func buildResultPayload(
        scenarioID: String,
        sessionID: UUID,
        container: ModelContainer,
        success: Bool,
        error: String?,
        cycleElapsed: TimeInterval,
        metadata: TestFixtureMetadata
    ) async -> TestResultPayload {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        let session = try? context.fetch(descriptor).first

        var transcriptText: String? = nil
        var polishedText: String? = nil
        var segmentCount = 0
        var speakerCount = 0
        var detectedLanguage: String? = nil
        var summary: MeetingSummary? = nil

        if let session {
            segmentCount = session.segments?.count ?? 0
            speakerCount = session.speakerCount
            detectedLanguage = session.detectedLanguage
            polishedText = session.polishedText

            if let json = session.meetingSummaryJSON {
                summary = MeetingSummary.from(jsonString: json)
            }

            let segments = session.sortedSegments
            if !segments.isEmpty {
                transcriptText = segments.prefix(50).map {
                    "[\(formatTimestamp($0.startTime))] \($0.speakerLabel): \($0.text)"
                }.joined(separator: "\n")
            }
        }

        return TestResultPayload(
            scenarioID: scenarioID,
            sessionID: sessionID.uuidString,
            timestamp: Date(),
            success: success,
            error: error,
            wallClockSeconds: cycleElapsed,
            input: TestResultPayload.Input(
                durationSeconds: metadata.durationSeconds,
                sampleRate: metadata.sampleRate,
                channels: metadata.channels,
                expectedTopics: metadata.expectedTopics,
                expectedActionItems: metadata.expectedActionItems,
                expectedSpeakers: metadata.expectedSpeakers,
                description: metadata.description
            ),
            output: TestResultPayload.Output(
                segmentCount: segmentCount,
                speakerCount: speakerCount,
                detectedLanguage: detectedLanguage,
                summaryActionItems: summary?.actionItems.count ?? 0,
                summaryDecisions: summary?.decisions.count ?? 0,
                summaryFollowUps: summary?.followUps.count ?? 0,
                summaryTopics: summary?.topics.count ?? 0,
                summaryLifeEvents: summary?.lifeEvents.count ?? 0,
                summaryComplianceFlags: summary?.complianceFlags.count ?? 0,
                summaryTLDR: summary?.tldr,
                transcriptSample: transcriptText,
                polishedSample: polishedText.map { String($0.prefix(2000)) }
            )
        )
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    /// Decoder configured to read TestResultPayload JSON written by the
    /// outbox encoder (ISO8601 dates, sorted keys, pretty printed).
    private func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Metrics

    private func appendMetricsLine(_ result: TestResultPayload) {
        // JSONL: one JSON object per line. Easy to grep and aggregate.
        let metric = MetricsRecord(
            scenarioID: result.scenarioID,
            timestamp: result.timestamp,
            wallClockSeconds: result.wallClockSeconds,
            success: result.success,
            segmentCount: result.output.segmentCount,
            speakerCount: result.output.speakerCount,
            inputDurationSeconds: result.input.durationSeconds,
            realtimeRatio: result.input.durationSeconds > 0 ? result.wallClockSeconds / result.input.durationSeconds : 0,
            error: result.error
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metric),
              let line = String(data: data, encoding: .utf8) else {
            return
        }

        let lineWithNewline = line + "\n"
        if let handle = try? FileHandle(forWritingTo: metricsFile) {
            handle.seekToEndOfFile()
            handle.write(Data(lineWithNewline.utf8))
            handle.closeFile()
        } else {
            try? lineWithNewline.write(to: metricsFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - File Movement

    private func moveFixtureToProcessed(jsonURL: URL, wavURL: URL, basename: String) async {
        // Date-stamped subdirectory so processed fixtures are easy to clean up
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = processedDirectory.appendingPathComponent("\(stamp)_\(basename)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let destJSON = dest.appendingPathComponent("\(basename).json")
        let destWAV = dest.appendingPathComponent("\(basename).wav")

        try? FileManager.default.moveItem(at: jsonURL, to: destJSON)
        try? FileManager.default.moveItem(at: wavURL, to: destWAV)

        // Clean up any leftover golden file from this fixture (Breakthrough
        // #3). The judge block in processFixture removes it when used; this
        // catches the case where the judge wasn't run (no golden expected,
        // or run against an old build that didn't know about goldens).
        let goldenURL = inboxDirectory.appendingPathComponent("\(basename).golden.json")
        try? FileManager.default.removeItem(at: goldenURL)
    }

    private func moveFixtureToFailed(jsonURL: URL, wavURL: URL, reason: String) async {
        let failedDir = processedDirectory.appendingPathComponent("_failed", isDirectory: true)
        try? FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: jsonURL, to: failedDir.appendingPathComponent(jsonURL.lastPathComponent))
        try? FileManager.default.moveItem(at: wavURL, to: failedDir.appendingPathComponent(wavURL.lastPathComponent))
        logger.error("Moved to _failed: \(jsonURL.lastPathComponent) (\(reason))")
    }
}

// MARK: - Fixture Metadata (input)

struct TestFixtureMetadata: Codable, Sendable {
    /// Stable identifier for this scenario, e.g. "short-single-point".
    var scenarioID: String

    /// Optional session ID — if nil, watcher generates a fresh one.
    var sessionID: UUID?

    /// Audio metadata
    var durationSeconds: TimeInterval
    var sampleRate: UInt32
    var channels: UInt16

    /// Optional original recording timestamp (defaults to now).
    var recordedAt: Date?

    /// Documentation: what this scenario is testing.
    var description: String?

    /// Optional expectations for verification + reporting.
    var expectedTopics: Int?
    var expectedActionItems: Int?
    var expectedSpeakers: Int?
}

// MARK: - Result Payload (output)

struct TestResultPayload: Codable, Sendable {
    var scenarioID: String
    var sessionID: String
    var timestamp: Date
    var success: Bool
    var error: String?
    var wallClockSeconds: TimeInterval
    var input: Input
    var output: Output
    var regression: RegressionJudgeService.Verdict? = nil

    struct Input: Codable, Sendable {
        var durationSeconds: TimeInterval
        var sampleRate: UInt32
        var channels: UInt16
        var expectedTopics: Int?
        var expectedActionItems: Int?
        var expectedSpeakers: Int?
        var description: String?
    }

    struct Output: Codable, Sendable {
        var segmentCount: Int
        var speakerCount: Int
        var detectedLanguage: String?
        var summaryActionItems: Int
        var summaryDecisions: Int
        var summaryFollowUps: Int
        var summaryTopics: Int
        var summaryLifeEvents: Int
        var summaryComplianceFlags: Int
        var summaryTLDR: String?
        var transcriptSample: String?
        var polishedSample: String?
    }
}

// MARK: - Metrics Record (one line per cycle)

struct MetricsRecord: Codable, Sendable {
    var scenarioID: String
    var timestamp: Date
    var wallClockSeconds: TimeInterval
    var success: Bool
    var segmentCount: Int
    var speakerCount: Int
    var inputDurationSeconds: TimeInterval
    /// Wall clock / input duration. <1.0 means faster than realtime, which
    /// is the bar we want for testing throughput.
    var realtimeRatio: Double
    var error: String?
}

#endif
