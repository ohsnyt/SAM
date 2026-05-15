//
//  InferenceFailureCapture.swift
//  SAM
//
//  DEBUG-ONLY inference failure logger. Captures the full prompt, system
//  prompt, raw model output (before <think> stripping), error class, and
//  diagnostic flags any time an MLX generation fails — so the underlying
//  cause can be diagnosed offline and folded back into the codebase.
//
//  Captures land at:
//      ~/Library/Containers/sam.SAM/Data/Library/Application Support/
//          Diagnostics/InferenceCaptures/*.json
//
//  Throttling: max 3 captures per day per (task.label, errorClass) pair,
//  plus a 10-minute debounce between consecutive captures for the same pair.
//  Lighter failures inside the debounce / over the daily cap are silently
//  dropped so a single bad batch doesn't fill the disk with duplicates.
//
//  Entire file compiles out in Release builds (`#if DEBUG`) so Sarah's
//  build never produces these captures and never carries the code.
//

#if DEBUG

import Foundation
import os.log

/// Serialized actor that writes full inference-failure JSON to disk for
/// later analysis. See file header for storage path and throttling rules.
actor InferenceFailureCapture {

    static let shared = InferenceFailureCapture()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "InferenceFailureCapture")

    enum ErrorClass: String, Codable, Sendable {
        case emptyResponse       // stream completed but post-strip output was empty
        case modelUnavailable    // ensureMLXModelLoaded threw before generation started
        case streamError         // exception from container.generate / stream iteration
        case other
    }

    // MARK: - Public API

    /// Visible path to the captures directory. Created on first access.
    /// `nonisolated` so callers (Settings UI, the analyze-inference-failures
    /// skill, the debugger) can reach it without hopping onto the actor.
    nonisolated static var capturesDirectoryURL: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("InferenceCaptures", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Record an MLX inference failure. Honors the daily cap + debounce.
    /// Safe to call from any actor; file I/O happens on this actor.
    func record(
        task: InferenceTask,
        backend: String,
        modelID: String?,
        errorClass: ErrorClass,
        errorMessage: String,
        durationSeconds: Double,
        maxTokensRequested: Int,
        hadThinkBlock: Bool,
        endedInsideThink: Bool,
        outputCharsBeforeStrip: Int,
        outputCharsAfterStrip: Int,
        systemPrompt: String?,
        userPrompt: String,
        rawOutput: String?
    ) {
        let now = Date()
        let key = throttleKey(taskLabel: task.label, errorClass: errorClass)
        let dayKey = Self.dayKey(for: now)

        ensureStateLoaded()

        var entry = throttleState.entries[key] ?? ThrottleEntry(
            lastCapturedAt: .distantPast,
            dayKey: dayKey,
            todayCount: 0
        )

        if entry.dayKey != dayKey {
            entry.dayKey = dayKey
            entry.todayCount = 0
        }

        if entry.todayCount >= Self.maxCapturesPerDay {
            logger.debug("InferenceFailureCapture: \(key, privacy: .public) over daily cap — dropped")
            return
        }
        if now.timeIntervalSince(entry.lastCapturedAt) < Self.debounceInterval {
            logger.debug("InferenceFailureCapture: \(key, privacy: .public) within debounce — dropped")
            return
        }

        let record = CapturedInferenceFailure(
            schemaVersion: Self.schemaVersion,
            id: UUID().uuidString,
            capturedAt: now,
            task: .init(label: task.label, source: task.source, priority: priorityString(task.priority)),
            backend: backend,
            modelID: modelID,
            errorClass: errorClass,
            errorMessage: errorMessage,
            durationSeconds: durationSeconds,
            maxTokensRequested: maxTokensRequested,
            diagnostics: .init(
                hadThinkBlock: hadThinkBlock,
                endedInsideThink: endedInsideThink,
                outputCharsBeforeStrip: outputCharsBeforeStrip,
                outputCharsAfterStrip: outputCharsAfterStrip,
                systemPromptChars: systemPrompt?.count ?? 0,
                userPromptChars: userPrompt.count,
                systemPromptApproxTokens: (systemPrompt?.count ?? 0) / 4,
                userPromptApproxTokens: userPrompt.count / 4
            ),
            prompts: .init(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                rawOutput: rawOutput
            )
        )

        let url = captureFileURL(for: record)

        do {
            let data = try Self.encoder.encode(record)
            try data.write(to: url, options: .atomic)

            entry.lastCapturedAt = now
            entry.todayCount += 1
            throttleState.entries[key] = entry
            persistState()

            logger.warning("InferenceFailureCapture: wrote \(url.lastPathComponent, privacy: .public) (\(record.task.label, privacy: .public) / \(record.errorClass.rawValue, privacy: .public))")
        } catch {
            logger.error("InferenceFailureCapture: write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Constants

    private static let schemaVersion = 1
    private static let maxCapturesPerDay = 3
    private static let debounceInterval: TimeInterval = 600  // 10 minutes

    // MARK: - Throttle state

    private struct ThrottleEntry: Codable {
        var lastCapturedAt: Date
        var dayKey: String
        var todayCount: Int
    }

    private struct ThrottleState: Codable {
        var entries: [String: ThrottleEntry] = [:]
    }

    private var throttleState = ThrottleState()
    private var stateLoaded = false

    private func ensureStateLoaded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        let url = Self.throttleStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            throttleState = try Self.decoder.decode(ThrottleState.self, from: data)
        } catch {
            logger.warning("InferenceFailureCapture: throttle state unreadable, starting fresh: \(error.localizedDescription, privacy: .public)")
            throttleState = ThrottleState()
        }
    }

    private func persistState() {
        let url = Self.throttleStateURL
        do {
            let data = try Self.encoder.encode(throttleState)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("InferenceFailureCapture: throttle state write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static var throttleStateURL: URL {
        capturesDirectoryURL.appendingPathComponent("_throttle_state.json")
    }

    // MARK: - Helpers

    private func throttleKey(taskLabel: String, errorClass: ErrorClass) -> String {
        "\(taskLabel)|\(errorClass.rawValue)"
    }

    private nonisolated static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private nonisolated static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private func captureFileURL(for record: CapturedInferenceFailure) -> URL {
        let timestamp = Self.filenameFormatter.string(from: record.capturedAt)
        let labelSlug = slug(record.task.label)
        let uuidShort = String(record.id.prefix(8))
        let name = "\(timestamp)_\(labelSlug)_\(record.errorClass.rawValue)_\(uuidShort).json"
        return Self.capturesDirectoryURL.appendingPathComponent(name)
    }

    private nonisolated func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch.isWhitespace || ch == "-" || ch == "_" {
                if !out.hasSuffix("-") { out.append("-") }
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private nonisolated func priorityString(_ p: AIService.Priority) -> String {
        switch p {
        case .interactive: return "interactive"
        case .background:  return "background"
        }
    }

    // MARK: - JSON codec

    private nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Captured payload

/// On-disk format for a captured inference failure. Stable, versioned.
struct CapturedInferenceFailure: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let capturedAt: Date
    let task: TaskInfo
    let backend: String
    let modelID: String?
    let errorClass: InferenceFailureCapture.ErrorClass
    let errorMessage: String
    let durationSeconds: Double
    let maxTokensRequested: Int
    let diagnostics: Diagnostics
    let prompts: Prompts

    struct TaskInfo: Codable, Sendable {
        let label: String
        let source: String
        let priority: String
    }

    struct Diagnostics: Codable, Sendable {
        let hadThinkBlock: Bool
        let endedInsideThink: Bool
        let outputCharsBeforeStrip: Int
        let outputCharsAfterStrip: Int
        let systemPromptChars: Int
        let userPromptChars: Int
        let systemPromptApproxTokens: Int
        let userPromptApproxTokens: Int
    }

    struct Prompts: Codable, Sendable {
        let systemPrompt: String?
        let userPrompt: String
        let rawOutput: String?
    }
}

#endif
