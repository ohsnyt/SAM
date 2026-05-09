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
        // events and contacts are imported. Wait for the launch storm
        // (role deduction + insight generation + outcome engine) to
        // settle before kicking off the briefing — otherwise the briefing
        // pre-narrative wall-clock balloons from main-actor contention
        // (saw +29s on a freshly-launched run with all of these in flight).
        if DailyBriefingCoordinator.shared.morningBriefing == nil {
            Task(priority: .utility) {
                await Self.waitForLaunchStormToSettle()
                await DailyBriefingCoordinator.shared.checkFirstOpenOfDay()
            }
        }

        logger.debug("Post-import work dispatched")
    }

    /// Polls AIService until inference has been idle for `requiredIdleSeconds`
    /// consecutive seconds, or `maxWaitSeconds` elapses (failsafe). Used to
    /// avoid kicking off the morning briefing while role deduction, insight
    /// generation, and the outcome engine's initial pass are still consuming
    /// the inference gate and main actor.
    private static func waitForLaunchStormToSettle(
        requiredIdleSeconds: Int = 3,
        maxWaitSeconds: Int = 60
    ) async {
        var consecutiveIdle = 0
        for _ in 0..<maxWaitSeconds {
            try? await Task.sleep(for: .seconds(1))
            let idle = await AIService.shared.isFullyIdle
            if idle {
                consecutiveIdle += 1
                if consecutiveIdle >= requiredIdleSeconds { return }
            } else {
                consecutiveIdle = 0
            }
        }
    }
}
