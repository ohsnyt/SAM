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
    func settle(timeout: TimeInterval = 15) async -> Bool {
        isShuttingDown = true
        progress = "Finishing background work..."
        blockedBy = BackgroundWorkProbe.currentBlockers()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let blockers = BackgroundWorkProbe.currentBlockers()
            if blockers.isEmpty {
                blockedBy = []
                progress = "Saving..."
                logger.info("Background work settled — proceeding with quit")
                return true
            }
            blockedBy = blockers
            try? await Task.sleep(for: .milliseconds(250))
        }
        logger.warning("Shutdown settle timeout after \(Int(timeout))s — force-exiting (some work may still be in flight)")
        return false
    }
}
