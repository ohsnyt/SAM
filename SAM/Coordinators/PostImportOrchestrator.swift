//
//  PostImportOrchestrator.swift
//  SAM
//
//  Debounces post-import work (role deduction, insight generation, outcome refresh)
//  across all import coordinators. When multiple importers finish within a short window,
//  the work runs once instead of N times.
//

import Foundation
import os.log

@MainActor
@Observable
final class PostImportOrchestrator {
    static let shared = PostImportOrchestrator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PostImportOrchestrator")
    private var debounceTask: Task<Void, Never>?

    /// Debounce interval — waits this long after the last trigger before running.
    private static let debounceSeconds: TimeInterval = 3

    private init() {}

    /// Called by any import coordinator after its import completes.
    /// Debounces: if called again within 3 seconds, resets the timer.
    func importDidComplete(source: String) {
        logger.debug("Post-import trigger from \(source)")
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(Self.debounceSeconds))
            guard !Task.isCancelled else { return }
            await runPostImportWork()
        }
    }

    private func runPostImportWork() async {
        logger.info("Running debounced post-import work")

        // Role deduction (already has its own 10-minute throttle)
        await RoleDeductionEngine.shared.deduceRoles()

        // Insight generation (already has its own throttle after our fix)
        InsightGenerator.shared.startAutoGeneration()

        logger.info("Post-import work complete")
    }
}
