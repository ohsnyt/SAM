//
//  ModalCoordinator.swift
//  SAM
//
//  Two responsibilities, one type:
//
//  1. Lock arbitration (original purpose): tracks every active modal
//     (alert, confirmation, sheet, popover, NSPanel) so AppLockService can
//     dismiss them on lock and re-present a curated subset on unlock.
//
//  2. Presentation arbitration: serializes sheet presentations across the
//     app so two sheets never try to present at the same time. SwiftUI on
//     macOS can only show one sheet per window — when a second sheet's
//     binding flips to true at a different hierarchy level, SwiftUI tears
//     down the first to present the second. This bit Sarah on Apr 24: a
//     post-call capture sheet appeared mid-LinkedIn-import and the import
//     UI was gone afterward. The arbiter routes every presentation through
//     a single active-slot + priority queue so this can't happen.
//
//  Call sites use the `managedSheet` ViewModifier (Views/Shared/
//  ManagedSheetModifier.swift) rather than calling `requestPresentation`
//  directly — the modifier handles the binding handshake.
//
//  The split between this and `LockOverlayCoordinator` is by *what each
//  layer can reach*. `LockOverlayCoordinator` puts a child window over each
//  parent NSWindow's content + chrome + attached sheet. That covers SwiftUI
//  content visually, but it can't reach `NSAlert`, `NSOpenPanel`, or
//  popovers — those are independent windows in their own right. Instead of
//  trying to cover them, we dismiss them.
//
//  Three legacy registration paths reflect the three modal categories used
//  before the presentation arbiter existed:
//    • restorable: sheets/popovers we want to bring back on unlock with
//      the same data. Caller supplies a dismiss closure and a restore
//      closure; we snapshot the latter and replay it after unlock.
//    • dismissOnly: alerts/confirmations. The user re-triggers if needed —
//      restoring "Are you sure?" prompts has no value, only confusion.
//    • panel: system file pickers. Cancel them; cancelling is non-destructive.
//
//  Managed sheets (via `requestPresentation`) handle lock + restore
//  inline — callers don't need to additionally register via the legacy
//  paths.
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

    // MARK: - Presentation Arbiter State

    /// Priority of a managed sheet presentation. Higher beats lower for
    /// `replaceLowerPriority` conflicts; ties queue in arrival order.
    enum Priority: Int, Comparable, Sendable {
        /// Background-triggered prompts: post-call capture, post-meeting
        /// capture, deceased detection, unknown-sender quick-add. Dropped
        /// from the queue on lock (will re-fire from their source timers).
        case opportunistic = 0
        /// SAM-initiated coaching: outcome review, briefing prompts.
        /// Restored on unlock if active when lock fired.
        case coaching = 1
        /// User explicitly invoked: File menu imports, ⌘N flows, etc.
        /// Always restored on unlock.
        case userInitiated = 2
        /// Errors and unrecoverable-state prompts. Always restored.
        case critical = 3

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// How a presentation request behaves when another modal is active.
    enum ConflictPolicy: Sendable {
        /// Wait for the active modal to dismiss, then present.
        case queue
        /// Skip silently if anything else is active. Used for low-stakes
        /// background prompts that aren't worth queueing.
        case dropIfBusy
        /// If the active modal is strictly lower priority, displace it.
        /// Otherwise queue.
        case replaceLowerPriority
    }

    /// Returned to the caller of `requestPresentation`. Caller invokes
    /// `dismissed()` when their sheet's binding goes false for any reason
    /// (user closed, ESC, programmatic dismissal). Idempotent.
    struct PresentationToken: Sendable {
        let id: UUID
        fileprivate let release: @Sendable () -> Void
        public func dismissed() { release() }
    }

    private struct PresentationEntry {
        let id: UUID
        let identifier: String
        let priority: Priority
        let present: () -> Void
        let dismissActive: () -> Void
        /// Optional probe into the active sheet's coordinator. When this
        /// returns `true`, the soft-displacement policy keeps the active
        /// sheet on screen and queues incoming `.replaceLowerPriority`
        /// requests instead of bumping it. Only `.critical` priority can
        /// override the block — errors and unrecoverable-state prompts
        /// must always reach the user. Used to prevent autonomous
        /// coaching/briefing sheets from blowing away a form Sarah is
        /// actively typing into.
        let hasUserContentProvider: (() -> Bool)?
        /// Optional gate checked at dequeue time. When this returns
        /// `false`, the entry is dropped from the queue without
        /// presenting. Used to prevent stale background prompts (an
        /// evening briefing that's now 4 hours old, a post-meeting
        /// capture for a meeting that ended at lunch) from cascading out
        /// of the queue when Sarah finally finishes her current work.
        let isStillRelevant: (() -> Bool)?
    }

    /// The single modal currently presenting (or about to). `nil` means the
    /// slot is free.
    private var activeEntry: PresentationEntry?

    /// FIFO within each priority. Higher-priority entries jump the line at
    /// dequeue time (see `advanceQueue`).
    private var pendingQueue: [PresentationEntry] = []

    /// Snapshot of the active managed presentation at lock time, restored
    /// on unlock if its priority warrants it (everything except
    /// `.opportunistic`).
    private var pendingManagedRestore: PresentationEntry?

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

    // MARK: - Public API: Presentation Arbiter

    /// Request to present a sheet. The coordinator decides *when* to invoke
    /// `present()` based on what's currently active and the `policy`:
    ///
    /// - If the slot is free → invoke `present()` synchronously, return
    ///   token (active).
    /// - If something is active and `policy == .queue` → enqueue, return
    ///   token (queued); `present()` fires when the active slot frees up.
    /// - If `policy == .dropIfBusy` → return a no-op token; caller's
    ///   intent is silently dropped. Useful for "would be nice" prompts
    ///   that shouldn't pile up.
    /// - If `policy == .replaceLowerPriority` and the active entry is
    ///   strictly lower priority → call its `dismissActive()`, then
    ///   present the new entry.
    ///
    /// `dismissActive` is what the coordinator calls to push the sheet
    /// back off-screen — typically `{ isPresented = false }` or
    /// `{ item = nil }`. Required even though most callers only "dismiss"
    /// via user action, because the coordinator may need to displace this
    /// entry for a higher-priority one or to clear the slot on lock.
    ///
    /// `present` is the closure that flips the caller's binding to true.
    /// It runs on the main actor.
    func requestPresentation(
        identifier: String,
        priority: Priority,
        policy: ConflictPolicy = .queue,
        present: @escaping () -> Void,
        dismissActive: @escaping () -> Void,
        hasUserContentProvider: (() -> Bool)? = nil,
        isStillRelevant: (() -> Bool)? = nil
    ) -> PresentationToken {
        let id = UUID()
        let entry = PresentationEntry(
            id: id,
            identifier: identifier,
            priority: priority,
            present: present,
            dismissActive: dismissActive,
            hasUserContentProvider: hasUserContentProvider,
            isStillRelevant: isStillRelevant
        )
        let token = makeToken(id: id)

        if activeEntry == nil {
            // Slot free — present immediately.
            activeEntry = entry
            logger.debug("Presenting '\(identifier, privacy: .public)' (priority \(priority.rawValue))")
            present()
            return token
        }

        // Slot busy — apply policy.
        switch policy {
        case .queue:
            insertIntoQueueByPriority(entry)
            logger.debug("Queued '\(identifier, privacy: .public)' behind '\(self.activeEntry?.identifier ?? "?", privacy: .public)'")
            return token

        case .dropIfBusy:
            logger.debug("Dropped '\(identifier, privacy: .public)' — slot busy with '\(self.activeEntry?.identifier ?? "?", privacy: .public)'")
            // Token's release is a no-op since we never put it in the queue.
            return token

        case .replaceLowerPriority:
            if let active = activeEntry, entry.priority > active.priority {
                // Soft-displacement guard: if the active sheet's
                // coordinator reports the user is typing real content,
                // don't bump them — queue the incoming request instead.
                // `.critical` priority overrides this (errors/lock must
                // reach the user no matter what), but `.userInitiated`
                // and below will wait.
                if entry.priority < .critical,
                   active.hasUserContentProvider?() == true {
                    insertIntoQueueByPriority(entry)
                    logger.debug("Soft-queued '\(identifier, privacy: .public)' behind active '\(active.identifier, privacy: .public)' (active has unsaved user content)")
                    return token
                }
                logger.debug("Replacing '\(active.identifier, privacy: .public)' with '\(identifier, privacy: .public)' (priority \(entry.priority.rawValue) > \(active.priority.rawValue))")
                // Push the displaced entry back to the head of the queue so
                // it re-presents when the new entry dismisses. Detach
                // active first so the displaced entry's eventual
                // `token.dismissed()` call (when SwiftUI tears it down) is
                // a no-op rather than freeing the slot under us.
                let displaced = active
                activeEntry = entry
                pendingQueue.insert(displaced, at: 0)
                displaced.dismissActive()
                present()
                return token
            } else {
                insertIntoQueueByPriority(entry)
                logger.debug("Queued '\(identifier, privacy: .public)' (no lower-priority active to displace)")
                return token
            }
        }
    }

    // MARK: - Presentation Arbiter Internals

    private func insertIntoQueueByPriority(_ entry: PresentationEntry) {
        // Insert at the position that keeps the queue sorted by priority
        // (high first) while preserving FIFO within a priority band.
        let insertIndex = pendingQueue.firstIndex(where: { $0.priority < entry.priority })
            ?? pendingQueue.endIndex
        pendingQueue.insert(entry, at: insertIndex)
    }

    private func makeToken(id: UUID) -> PresentationToken {
        PresentationToken(id: id) { [weak self] in
            Task { @MainActor [weak self] in
                self?.releaseToken(id: id)
            }
        }
    }

    /// Called when the caller's sheet has dismissed (binding observed
    /// false). Frees the slot if `id` is the active entry; otherwise
    /// removes it from the queue (caller gave up before presenting).
    /// Idempotent: re-entering with the same id is a no-op.
    private func releaseToken(id: UUID) {
        if activeEntry?.id == id {
            let leaving = activeEntry?.identifier ?? "?"
            activeEntry = nil
            logger.debug("Released active '\(leaving, privacy: .public)'")
            advanceQueue()
            return
        }
        if let queuedIndex = pendingQueue.firstIndex(where: { $0.id == id }) {
            let leaving = pendingQueue[queuedIndex].identifier
            pendingQueue.remove(at: queuedIndex)
            logger.debug("Withdrew queued '\(leaving, privacy: .public)' before presentation")
        }
        // else: token already released, or was dropped via .dropIfBusy.
    }

    private func advanceQueue() {
        guard activeEntry == nil else { return }
        // Skip entries whose relevance gate now returns false. A queued
        // post-meeting prompt for a meeting that ended hours ago, or an
        // evening briefing that's already morning, has no business
        // surfacing the moment Sarah finishes the current sheet. The
        // gate is opt-in; entries without one are always considered
        // relevant.
        while let next = pendingQueue.first {
            pendingQueue.removeFirst()
            if let stillRelevant = next.isStillRelevant, !stillRelevant() {
                logger.debug("Dropping stale queued '\(next.identifier, privacy: .public)' on dequeue")
                continue
            }
            activeEntry = next
            logger.debug("Advancing queue: presenting '\(next.identifier, privacy: .public)'")
            next.present()
            return
        }
    }

    // MARK: - Lock Transitions

    /// Called by `AppLockService` from `lock()` and the success branch of
    /// `authenticate()`. Imperative call instead of observation so the
    /// timing is tight against the state transition — the same reason
    /// `LockOverlayCoordinator` uses the same pattern.
    func handleLockStateChange(isLocked: Bool) {
        if isLocked {
            dismissAll()
            snapshotAndDismissManaged()
        } else {
            restorePending()
            restoreManaged()
        }
    }

    /// On lock: snapshot the active managed entry (if its priority warrants
    /// restoration), then dismiss it. Clear the queue — queued opportunistic
    /// prompts shouldn't pile up across lock cycles, and queued
    /// user-initiated requests are rare enough that re-triggering manually
    /// is fine.
    private func snapshotAndDismissManaged() {
        guard let active = activeEntry else {
            pendingQueue.removeAll()
            return
        }
        if active.priority >= .coaching {
            pendingManagedRestore = active
        }
        active.dismissActive()
        activeEntry = nil
        pendingQueue.removeAll()
    }

    /// On unlock: if we snapshotted a managed entry on lock, restore it.
    /// The slot is free at this point (we cleared it on lock), so just
    /// re-set active and call present().
    private func restoreManaged() {
        guard let entry = pendingManagedRestore else { return }
        pendingManagedRestore = nil
        activeEntry = entry
        logger.debug("Restoring managed '\(entry.identifier, privacy: .public)' after unlock")
        entry.present()
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

    // MARK: - Test Support

    #if DEBUG
    /// Wipes active + queued + lock-snapshot state. Test-only; production
    /// code must go through `requestPresentation` and token release so the
    /// arbiter's logging and state machine stay coherent.
    func resetForTesting() {
        activeEntry = nil
        pendingQueue.removeAll()
        pendingManagedRestore = nil
        entries.removeAll()
        pendingRestores.removeAll()
    }
    #endif

    private func restorePending() {
        guard !pendingRestores.isEmpty else { return }

        let toRestore = pendingRestores
        pendingRestores.removeAll()
        for restore in toRestore {
            restore()
        }
    }
}
