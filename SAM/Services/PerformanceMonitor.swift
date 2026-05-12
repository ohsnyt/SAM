//
//  PerformanceMonitor.swift
//  SAM
//
//  Phase 1a — main-actor responsiveness monitor.
//
//  See `1_Documentation/roadmap/scaling-roadmap.md` Phase 1. This file holds the
//  cross-thread heartbeat store and the public `measure` API used to mark
//  long-running operations. The actual ping/watch loops live in
//  `HangWatchdog.swift`; the JSON writer lives in this file too because it
//  is small and only called from the watchdog.
//
//  Concurrency model:
//  - `HeartbeatStore` is a Sendable reference type guarded by
//    `OSAllocatedUnfairLock`. Both the main thread (recording heartbeats,
//    pushing/popping operations) and a background watcher (reading the
//    snapshot) touch it. No `nonisolated(unsafe)` — every access goes
//    through the lock.
//  - `PerformanceMonitor.measure(...)` is `@MainActor` because every site
//    that calls it is already on the main actor, and we want zero hop cost
//    when wrapping fast operations.
//

import Foundation
import os
import os.log

// MARK: - Public records

/// Snapshot of the most recent activity, captured at the moment a hang fires.
nonisolated struct HangReport: Codable, Sendable {
    let firedAt: Date
    /// Time elapsed between the last main-actor heartbeat and detection.
    let stalledForSeconds: Double
    /// The operation that was running when the hang began, if any.
    let activeOperation: String?
    /// How long the active operation had been running when the hang fired.
    let activeOperationElapsedSeconds: Double?
    /// Operation stack at the moment of detection (deepest last).
    let activeStack: [String]
    /// Most recent completed operations, oldest first. Useful for "we just
    /// finished X, then started Y, then hung."
    let recentCompleted: [CompletedOperation]
    let appVersion: String
    let schemaVersion: String

    nonisolated struct CompletedOperation: Codable, Sendable {
        let name: String
        let startedAt: Date
        let durationSeconds: Double
    }
}

/// Live snapshot of the in-process state. Read by both the watchdog (when a
/// hang fires) and the Settings UI (to show recent activity).
nonisolated struct PerformanceSnapshot: Sendable {
    let lastHeartbeatAt: Date
    let activeStack: [ActiveOperation]
    let recentCompleted: [HangReport.CompletedOperation]
    let inHang: Bool
    let hangCount: Int
    let lastHang: HangReport?

    nonisolated struct ActiveOperation: Sendable {
        let name: String
        let startedAt: Date
    }
}

// MARK: - Heartbeat store

/// Lock-protected state shared between the main actor and the watchdog.
/// All mutation routes through `withLock` so we satisfy Swift 6 strict
/// concurrency without any `nonisolated(unsafe)` escape hatches.
nonisolated final class HeartbeatStore: Sendable {

    /// History caps. Generous enough to be useful, small enough to stay cheap.
    static let recentCompletedCap = 32
    static let hangHistoryCap = 50

    private struct State {
        var lastHeartbeatAt: Date = .distantPast
        var activeStack: [PerformanceSnapshot.ActiveOperation] = []
        var recentCompleted: [HangReport.CompletedOperation] = []
        var inHang: Bool = false
        var hangCount: Int = 0
        var lastHang: HangReport? = nil
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func recordHeartbeat(_ now: Date = Date()) {
        lock.withLock { $0.lastHeartbeatAt = now }
    }

    func beginOperation(_ name: String, startedAt: Date = Date()) {
        lock.withLock {
            $0.activeStack.append(.init(name: name, startedAt: startedAt))
        }
    }

    func endOperation(_ name: String, endedAt: Date = Date()) {
        lock.withLock { state in
            // Pop the most recent matching frame. Mismatches are tolerated —
            // we'd rather record imperfect data than crash on instrumentation.
            if let idx = state.activeStack.lastIndex(where: { $0.name == name }) {
                let frame = state.activeStack.remove(at: idx)
                let duration = endedAt.timeIntervalSince(frame.startedAt)
                state.recentCompleted.append(.init(
                    name: name,
                    startedAt: frame.startedAt,
                    durationSeconds: duration
                ))
                if state.recentCompleted.count > Self.recentCompletedCap {
                    state.recentCompleted.removeFirst(
                        state.recentCompleted.count - Self.recentCompletedCap
                    )
                }
            }
        }
    }

    /// Atomically check whether a hang should be recorded. Returns the report
    /// to write iff this call transitioned us from "responsive" to "hung."
    /// Subsequent calls during the same hang return nil.
    func tryRecordHangStart(stalledFor: Double, firedAt: Date) -> HangReport? {
        lock.withLock { state -> HangReport? in
            guard !state.inHang else { return nil }
            state.inHang = true
            state.hangCount += 1

            let active = state.activeStack.last
            let report = HangReport(
                firedAt: firedAt,
                stalledForSeconds: stalledFor,
                activeOperation: active?.name,
                activeOperationElapsedSeconds: active.map {
                    firedAt.timeIntervalSince($0.startedAt)
                },
                activeStack: state.activeStack.map(\.name),
                recentCompleted: state.recentCompleted,
                appVersion: PerformanceMonitor.appVersion,
                schemaVersion: PerformanceMonitor.schemaVersion
            )
            state.lastHang = report
            return report
        }
    }

    /// Called when a heartbeat lands after a hang. Returns the recovery
    /// duration (how long we were stuck) iff we were actually in a hang.
    func clearHangIfNeeded(now: Date = Date()) -> Double? {
        lock.withLock { state -> Double? in
            guard state.inHang else { return nil }
            state.inHang = false
            return now.timeIntervalSince(state.lastHeartbeatAt)
        }
    }

    func snapshot() -> PerformanceSnapshot {
        lock.withLock { state in
            PerformanceSnapshot(
                lastHeartbeatAt: state.lastHeartbeatAt,
                activeStack: state.activeStack,
                recentCompleted: state.recentCompleted,
                inHang: state.inHang,
                hangCount: state.hangCount,
                lastHang: state.lastHang
            )
        }
    }
}

// MARK: - Module-level singletons

/// Single store shared by `PerformanceMonitor` (writers, on the main actor)
/// and `HangWatchdog` (reader, on a background queue). Pulled out of the
/// monitor class so it is reachable from non-isolated callers without
/// hopping through `@MainActor`.
nonisolated let _samPerformanceStore = HeartbeatStore()

// MARK: - Public monitor

/// Public façade. Coordinators wrap their hot operations in `measure`. The
/// watchdog reads `store.snapshot()` to figure out what was running when the
/// main thread froze.
@MainActor
final class PerformanceMonitor {

    static let shared = PerformanceMonitor()

    nonisolated var store: HeartbeatStore { _samPerformanceStore }
    let signposter = OSSignposter(
        subsystem: "com.matthewsessions.SAM",
        category: "Performance"
    )

    nonisolated static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }()

    /// Mirrors the schema constant used in `SAMModelContainer`. Hard-coded
    /// rather than introspected to avoid a load-order dependency.
    nonisolated static let schemaVersion: String = "SAM_v34"

    private init() {}

    // MARK: - Async measurement

    /// Wrap an async operation. Pushes a frame onto the active stack,
    /// emits a signpost interval (visible in Instruments), and pops on exit
    /// regardless of throw or cancellation.
    @discardableResult
    func measure<T>(
        _ name: StaticString,
        perform: () async throws -> T
    ) async rethrows -> T {
        let interval = signposter.beginInterval(name)
        let nameString = String("\(name)")
        store.beginOperation(nameString)
        defer {
            store.endOperation(nameString)
            signposter.endInterval(name, interval)
        }
        return try await perform()
    }

    /// Synchronous variant for non-async hot paths.
    @discardableResult
    func measureSync<T>(
        _ name: StaticString,
        perform: () throws -> T
    ) rethrows -> T {
        let interval = signposter.beginInterval(name)
        let nameString = String("\(name)")
        store.beginOperation(nameString)
        defer {
            store.endOperation(nameString)
            signposter.endInterval(name, interval)
        }
        return try perform()
    }

    /// Single-event signpost — for "we just reached point X" markers that
    /// don't have a matching duration.
    func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    // MARK: - Diagnostics directory

    nonisolated static func diagnosticsDirectoryURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appendingPathComponent("SAM/diagnostics", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        return dir
    }
}

// MARK: - Hang JSON writer

/// File writer used by the watchdog. Lives next to the monitor because it's
/// trivial and only ever called from the background watcher loop.
nonisolated enum HangReportWriter {

    private static let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "HangWatchdog")

    /// Writes the report and returns the URL on success.
    @discardableResult
    static func write(_ report: HangReport) -> URL? {
        guard let dir = PerformanceMonitor.diagnosticsDirectoryURL() else {
            logger.debug("HangReportWriter: no diagnostics directory")
            return nil
        }

        // Filename: hang-2026-05-08T13-22-04Z.json
        let stamp = ISO8601DateFormatter().string(from: report.firedAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("hang-\(stamp).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
            pruneOldReports(in: dir)
            logger.debug("HangReportWriter: wrote \(url.lastPathComponent, privacy: .public) (active: \(report.activeOperation ?? "<unknown>", privacy: .public), stalled \(report.stalledForSeconds, format: .fixed(precision: 2))s)")
            return url
        } catch {
            logger.debug("HangReportWriter: encode/write failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Keep at most `HeartbeatStore.hangHistoryCap` files; oldest go first.
    private static func pruneOldReports(in dir: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let hangFiles = entries
            .filter { $0.lastPathComponent.hasPrefix("hang-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lDate < rDate
            }

        let surplus = hangFiles.count - HeartbeatStore.hangHistoryCap
        guard surplus > 0 else { return }
        for url in hangFiles.prefix(surplus) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Reads recent reports for the Settings UI. Newest first.
    static func loadRecent(limit: Int = 10) -> [HangReport] {
        guard let dir = PerformanceMonitor.diagnosticsDirectoryURL() else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let sorted = entries
            .filter { $0.lastPathComponent.hasPrefix("hang-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return lDate > rDate
            }
            .prefix(limit)

        return sorted.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(HangReport.self, from: data)
        }
    }
}
