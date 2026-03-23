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
        logger.debug("Running debounced post-import work")

        // Dispatch AI-heavy work to background so it doesn't block the main actor.
        // Both engines are @MainActor @Observable, but their heavy lifting (LLM calls,
        // SwiftData queries) should yield back to the main actor between steps.
        // By not awaiting them here, the UI stays responsive during processing.
        Task(priority: .utility) {
            await RoleDeductionEngine.shared.deduceRoles()
        }
        Task(priority: .utility) {
            InsightGenerator.shared.startAutoGeneration()
        }

        // Scan outgoing messages for event-related content and suggest participant additions.
        OutgoingEventMatcher.shared.scanRecentOutgoing()

        logger.debug("Post-import work dispatched")
    }
}
