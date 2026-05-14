//
//  ShutdownCoordinator.swift
//  SAM
//
//  Drives the graceful-quit flow. AppDelegate's applicationShouldTerminate
//  consults BackgroundWorkProbe — if any coordinator is busy, it returns
//  .terminateLater, flips ShutdownCoordinator.isShuttingDown so the UI
//  swaps to the BlockingActivityOverlay, then awaits `settle(timeout:)`
//  before completing teardown and replying.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ShutdownCoordinator")

@MainActor
@Observable
final class ShutdownCoordinator {

    static let shared = ShutdownCoordinator()
    private init() {}

    /// True from the moment AppDelegate decides we have to wait, until the
    /// process actually exits. Drives the BlockingActivityOverlay swap.
    var isShuttingDown: Bool = false

    /// Current human-readable phase shown in the overlay.
    var progress: String = ""

    /// Names of coordinators we're still waiting on (refreshed each settle poll).
    var blockedBy: [String] = []

    /// Poll background coordinators until they're all idle, with a hard
    /// timeout so a stuck coordinator can't block quit forever. Returns
    /// `true` if everything settled cleanly, `false` on timeout.
    ///
    /// Default timeout is 5 minutes — MLX briefing/digest generation can
    /// legitimately take several minutes on first run, and forcing teardown
    /// mid-inference crashes on the dropped model container.
    func settle(timeout: TimeInterval = 300) async -> Bool {
        isShuttingDown = true
        progress = "Finishing background work..."
        blockedBy = BackgroundWorkProbe.currentBlockers()

        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline {
            var blockers = BackgroundWorkProbe.currentBlockers()
            // Defense-in-depth against probe gaps: also wait for any in-flight
            // AI generation / MLX stream regardless of which coordinator
            // launched it. Without this, a call site that forgets to register
            // with the probe (or runs ad-hoc inference) can race the C++
            // static destructors at exit() and crash on the dropped
            // CompilerCache / scheduler.
            let aiIdle = await AIService.shared.isFullyIdle
            if !aiIdle {
                blockers.append("AI inference")
            }
            if blockers.isEmpty {
                blockedBy = []
                progress = "Saving..."
                logger.info("Background work settled — proceeding with quit")
                return true
            }
            blockedBy = blockers
            let elapsed = Int(Date().timeIntervalSince(start))
            progress = "Waiting for AI tasks to finish (\(elapsed)s elapsed)..."
            try? await Task.sleep(for: .milliseconds(250))
        }
        logger.warning("Shutdown settle timeout after \(Int(timeout))s — force-exiting (some work may still be in flight)")
        return false
    }
}
