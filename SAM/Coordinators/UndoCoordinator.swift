//
//  UndoCoordinator.swift
//  SAM
//
//  Created by Assistant on 2/25/26.
//  Phase P: Universal Undo System
//
//  Manages undo toast display state with auto-dismiss timer.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "UndoCoordinator")

@MainActor
@Observable
final class UndoCoordinator {

    // MARK: - Singleton

    static let shared = UndoCoordinator()

    private init() {}

    // MARK: - Toast State

    /// When non-nil, the undo toast is visible.
    var currentEntry: SamUndoEntry?

    /// Auto-dismiss timer handle.
    private var dismissTask: Task<Void, Never>?

    // MARK: - Actions

    /// Show a toast for the given undo entry. Replaces any existing toast.
    func showToast(for entry: SamUndoEntry) {
        dismissTask?.cancel()
        currentEntry = entry

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            currentEntry = nil
        }
    }

    /// Perform undo on the current toast entry.
    func performUndo() {
        guard let entry = currentEntry else { return }
        dismissTask?.cancel()
        currentEntry = nil

        do {
            try UndoRepository.shared.restore(entry: entry)
            logger.info("Undo performed: \(entry.entityType.rawValue) '\(entry.entityDisplayName)'")
        } catch {
            logger.error("Undo failed: \(error.localizedDescription)")
        }
    }

    /// Dismiss the toast manually (X button).
    func dismiss() {
        dismissTask?.cancel()
        currentEntry = nil
    }
}
