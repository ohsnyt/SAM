//
//  HangWatchdog.swift
//  SAM
//
//  Phase 1a — main-actor responsiveness watchdog.
//
//  Two cooperating timers on a private background queue:
//
//  1. **Pinger** — every 250 ms, schedules a tiny block on `DispatchQueue.main`
//     that calls `store.recordHeartbeat()`. The block only runs when the main
//     queue is free; if the main thread is blocked, heartbeats stop landing.
//
//  2. **Watcher** — every 250 ms on the background queue, checks how long
//     ago the last heartbeat landed. If > 1.0 s and we are not already in a
//     hang, captures a snapshot and writes `hang-{ISO}.json`. When the next
//     heartbeat eventually lands, we exit the hang state.
//
//  Why DispatchSourceTimer instead of `Task.sleep`:
//  - Deterministic 250 ms cadence even under thermal pressure.
//  - Watcher must run off the main thread; using a detached Task that may
//    end up scheduled on the same cooperative queue as our own work would
//    defeat the point.
//  - The pinger's main-queue block is the canonical "is the main thread
//    actually free?" probe.
//
//  Cost: two timers, an unfair lock, ~0.1% CPU at idle.
//
//  Not in v1 (deferred):
//  - Cross-thread main-thread call-stack capture (Mach `task_threads` +
//    `thread_get_state`). The active-operation beacon + recent-completed
//    history covers most "what was running?" questions without the
//    bookkeeping overhead. Add later if real reports show the beacon is
//    blank too often.
//  - MetricKit subscription (Phase 1c).
//  - Auto-delivery to a webhook (Phase 1d).
//

import Dispatch
import Foundation
import os.log

/// Background-queue watchdog. One instance, started once at launch.
nonisolated final class HangWatchdog: @unchecked Sendable {

    static let shared = HangWatchdog()

    /// Heartbeat cadence. Both timers fire on this interval.
    private static let interval: DispatchTimeInterval = .milliseconds(250)

    /// How long the main thread must be unresponsive before we record a hang.
    private static let hangThreshold: TimeInterval = 1.0

    private let queue = DispatchQueue(
        label: "com.matthewsessions.SAM.HangWatchdog",
        qos: .utility
    )

    private let store: HeartbeatStore

    /// Set under `queue`. Both timers are owned here so we can cancel cleanly.
    private var pinger: DispatchSourceTimer?
    private var watcher: DispatchSourceTimer?
    private var started = false

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "HangWatchdog")

    /// Default singleton uses the module-level heartbeat store, reachable
    /// from non-isolated callers without hopping through `@MainActor`.
    init() {
        self.store = _samPerformanceStore
    }

    /// Test-only initializer.
    init(store: HeartbeatStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true

            // Seed the heartbeat so the watcher doesn't immediately fire on launch.
            store.recordHeartbeat()

            startPinger()
            startWatcher()
            logger.debug("HangWatchdog started (250ms interval, 1.0s threshold)")
        }
    }

    func stop() {
        queue.async { [self] in
            pinger?.cancel(); pinger = nil
            watcher?.cancel(); watcher = nil
            started = false
            logger.debug("HangWatchdog stopped")
        }
    }

    // MARK: - Pinger

    /// Posts a tiny block onto `DispatchQueue.main` every 250 ms. The block
    /// records the heartbeat — it only runs when the main thread is free.
    private func startPinger() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.interval,
            repeating: Self.interval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [store] in
            DispatchQueue.main.async {
                store.recordHeartbeat()
            }
        }
        timer.resume()
        pinger = timer
    }

    // MARK: - Watcher

    /// Checks heartbeat age. Records a hang when it crosses the threshold;
    /// records a recovery log line when the next heartbeat arrives.
    private func startWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.interval,
            repeating: Self.interval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [self] in
            evaluate(at: Date())
        }
        timer.resume()
        watcher = timer
    }

    /// Single tick of the watcher loop. Pulled out of the closure for clarity
    /// and for future test coverage.
    private func evaluate(at now: Date) {
        let snapshot = store.snapshot()
        let age = now.timeIntervalSince(snapshot.lastHeartbeatAt)

        // Did a heartbeat land while we were in a hang? Record recovery.
        if snapshot.inHang, age < Self.hangThreshold,
           let recoverySeconds = store.clearHangIfNeeded(now: now) {
            logger.debug("HangWatchdog: main thread responsive again after \(recoverySeconds, format: .fixed(precision: 2))s")
            return
        }

        // Are we crossing into a new hang?
        guard age >= Self.hangThreshold, !snapshot.inHang else { return }

        if let report = store.tryRecordHangStart(stalledFor: age, firedAt: now) {
            HangReportWriter.write(report)
        }
    }
}
