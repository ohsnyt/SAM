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
        // Defer AI-heavy work while a recording session is active —
        // role deduction and insight generation use LLM calls that
        // compete with the streaming pipeline for CPU and memory.
        if TranscriptionSessionCoordinator.shared.isSessionActive {
            logger.debug("Post-import work deferred — recording session active")
            // Re-trigger after a delay so we don't lose the work entirely
            debounceTask = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await runPostImportWork()
            }
            return
        }

        logger.debug("Running debounced post-import work")

        Task(priority: .utility) {
            await RoleDeductionEngine.shared.deduceRoles()
        }
        Task(priority: .utility) {
            InsightGenerator.shared.startAutoGeneration()
        }

        OutgoingEventMatcher.shared.scanRecentOutgoing()

        // Generate or refresh the morning briefing now that calendar
        // events and contacts are imported. This ensures the briefing
        // includes today's meetings (previously it ran before calendar
        // import completed).
        if DailyBriefingCoordinator.shared.morningBriefing == nil {
            Task(priority: .utility) {
                await DailyBriefingCoordinator.shared.checkFirstOpenOfDay()
            }
        }

        logger.debug("Post-import work dispatched")
    }
}
