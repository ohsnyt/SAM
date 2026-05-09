//
//  ModalCoordinator.swift
//  SAM
//
//  Tracks every active modal presentation (alert, confirmation, sheet,
//  popover, NSPanel) so AppLockService can dismiss them all when the app
//  locks and re-present a curated subset on unlock.
//
//  The split between this and `LockOverlayCoordinator` is by *what each
//  layer can reach*. `LockOverlayCoordinator` puts a child window over each
//  parent NSWindow's content + chrome + attached sheet. That covers SwiftUI
//  content visually, but it can't reach `NSAlert`, `NSOpenPanel`, or
//  popovers — those are independent windows in their own right. Instead of
//  trying to cover them, we dismiss them.
//
//  Three registration paths reflect the three modal categories:
//    • restorable: sheets/popovers we want to bring back on unlock with
//      the same data. Caller supplies a dismiss closure and a restore
//      closure; we snapshot the latter and replay it after unlock.
//    • dismissOnly: alerts/confirmations. The user re-triggers if needed —
//      restoring "Are you sure?" prompts has no value, only confusion.
//    • panel: system file pickers. Cancel them; cancelling is non-destructive.
//

import AppKit
import Foundation
import os.log

@MainActor
@Observable
final class ModalCoordinator {

    static let shared = ModalCoordinator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ModalCoordinator")

    // MARK: - Registration

    /// Opaque handle returned to the caller. Calling `unregister()` removes
    /// the entry from the coordinator. Callers stash it in `@State` and
    /// release it when the modal disappears (whether dismissed by the
    /// coordinator or by the user).
    struct Registration {
        let token: UUID
        let unregister: () -> Void
    }

    /// What the coordinator does to this entry on lock.
    private enum Kind {
        case restorable(dismiss: () -> Void, restore: () -> Void)
        case dismissOnly(dismiss: () -> Void)
        case panel(panel: NSPanel)
    }

    private struct Entry {
        let token: UUID
        let kind: Kind
    }

    private var entries: [Entry] = []

    /// Pending re-presentations, captured when lock fires and replayed on
    /// unlock. Cleared after replay so a subsequent lock doesn't drag old
    /// snapshots forward.
    private var pendingRestores: [() -> Void] = []

    private init() {}

    // MARK: - Public API

    /// Register a sheet/popover that should be brought back on unlock.
    /// `dismiss` runs on lock; `restore` runs on unlock. Both run on the
    /// main actor.
    func registerRestorable(
        token: UUID = UUID(),
        dismiss: @escaping () -> Void,
        restore: @escaping () -> Void
    ) -> Registration {
        let entry = Entry(token: token, kind: .restorable(dismiss: dismiss, restore: restore))
        entries.append(entry)
        return makeRegistration(for: token)
    }

    /// Register an alert/confirmation that should be dismissed on lock and
    /// not restored. The user re-triggers if they still want the prompt.
    func registerDismissOnly(
        token: UUID = UUID(),
        dismiss: @escaping () -> Void
    ) -> Registration {
        let entry = Entry(token: token, kind: .dismissOnly(dismiss: dismiss))
        entries.append(entry)
        return makeRegistration(for: token)
    }

    /// Register a system file picker so it gets cancelled on lock. Pass the
    /// `NSOpenPanel`/`NSSavePanel`/`NSPanel` instance; the coordinator
    /// holds a strong reference until `unregister()` is called.
    func registerPanel(_ panel: NSPanel) -> Registration {
        let token = UUID()
        let entry = Entry(token: token, kind: .panel(panel: panel))
        entries.append(entry)
        return makeRegistration(for: token)
    }

    // MARK: - Lock Transitions

    /// Called by `AppLockService` from `lock()` and the success branch of
    /// `authenticate()`. Imperative call instead of observation so the
    /// timing is tight against the state transition — the same reason
    /// `LockOverlayCoordinator` uses the same pattern.
    func handleLockStateChange(isLocked: Bool) {
        if isLocked {
            dismissAll()
        } else {
            restorePending()
        }
    }

    // MARK: - Internals

    private func makeRegistration(for token: UUID) -> Registration {
        Registration(token: token) { [weak self] in
            Task { @MainActor [weak self] in
                self?.removeEntry(token: token)
            }
        }
    }

    private func removeEntry(token: UUID) {
        entries.removeAll { $0.token == token }
    }

    private func dismissAll() {
        guard !entries.isEmpty else { return }

        for entry in entries {
            switch entry.kind {
            case .restorable(let dismiss, let restore):
                pendingRestores.append(restore)
                dismiss()
            case .dismissOnly(let dismiss):
                dismiss()
            case .panel(let panel):
                // `cancel(_:)` on NSOpenPanel/NSSavePanel ends the modal
                // session with cancel response code; `close()` is the
                // generic fallback for other NSPanel subclasses.
                if let openPanel = panel as? NSOpenPanel {
                    openPanel.cancel(nil)
                } else if let savePanel = panel as? NSSavePanel {
                    savePanel.cancel(nil)
                } else {
                    panel.close()
                }
            }
        }

        // Clear the entries roster — restorables that we'll re-present
        // will re-register themselves when their views reappear after unlock.
        entries.removeAll()
    }

    private func restorePending() {
        guard !pendingRestores.isEmpty else { return }

        let toRestore = pendingRestores
        pendingRestores.removeAll()
        for restore in toRestore {
            restore()
        }
    }
}
