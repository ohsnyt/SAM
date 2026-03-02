// BackgroundTaskMonitor.swift
// SAM — DEBUG-only monitor for draining background work before seeder termination.
//
// Aggregates active work from:
//   • All 5 import coordinators (via importStatus == .importing)
//   • EvernoteImportCoordinator.analysisTaskCount
//   • AIService.activeGenerationCount
//
// seedFresh() opens a progress window and calls waitUntilIdle(), which
// suspends until all counts reach zero before the process terminates.

#if DEBUG
import Foundation
import os.log

@MainActor
@Observable
final class BackgroundTaskMonitor {

    static let shared = BackgroundTaskMonitor()
    private let logger = Logger(subsystem: "com.sam", category: "BackgroundTaskMonitor")

    private init() {}

    // MARK: - Observable State

    /// Human-readable list of what is still running.
    private(set) var activeDescriptions: [String] = []

    /// Total number of active background items across all sources.
    var totalActive: Int { activeDescriptions.count }

    var isIdle: Bool { activeDescriptions.isEmpty }

    // MARK: - Polling

    private var pollingTask: Task<Void, Never>?

    /// Begin polling all sources at ~100ms interval.
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Suspend until all background sources report idle.
    func waitUntilIdle() async {
        startPolling()
        while !isIdle {
            try? await Task.sleep(for: .milliseconds(100))
        }
        stopPolling()
    }

    // MARK: - Refresh

    private func refresh() async {
        var items: [String] = []

        if ContactsImportCoordinator.shared.importStatus == .importing {
            items.append("Contacts import")
        }
        if CalendarImportCoordinator.shared.importStatus == .importing {
            items.append("Calendar import")
        }
        if MailImportCoordinator.shared.importStatus == .importing {
            items.append("Mail import")
        }
        if CommunicationsImportCoordinator.shared.importStatus == .importing {
            items.append("Messages import")
        }

        // Evernote has both a top-level status and per-note analysis tasks
        if EvernoteImportCoordinator.shared.importStatus == .importing ||
           EvernoteImportCoordinator.shared.importStatus == .parsing {
            items.append("Evernote import")
        }
        let evernoteCount = EvernoteImportCoordinator.shared.analysisTaskCount
        if evernoteCount > 0 {
            items.append("Evernote analysis (\(evernoteCount))")
        }

        // AI generation calls live on the AIService actor — hop to read
        let aiCount = await AIService.shared.activeGenerationCount
        if aiCount > 0 {
            items.append(aiCount == 1 ? "AI generation" : "AI generation (\(aiCount))")
        }

        activeDescriptions = items
    }
}
#endif
