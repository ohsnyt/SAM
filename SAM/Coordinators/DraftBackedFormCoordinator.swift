//
//  DraftBackedFormCoordinator.swift
//  SAM
//
//  Phase 1 of the sheet-tear-down work loss fix.
//
//  Adopted by `@MainActor @Observable` form coordinators that hold
//  typed, in-progress user input. The protocol gives a coordinator
//  three guarantees:
//
//    1. **Sheet-flip recovery** — when ModalCoordinator displaces a
//       lower-priority sheet, the coordinator instance survives because
//       it's owned outside the view. State is preserved in memory; no
//       I/O involved.
//
//    2. **Crash / quit recovery** — every edit triggers a debounced
//       flush (~1.5s) of a JSON-encoded `Payload` to a `FormDraft` row.
//       On coordinator init, `restoreFromDraft()` rehydrates from disk
//       if a draft exists for the same (formKind, subjectID).
//
//    3. **Submit-success-before-clear** — `submitAndClear` only deletes
//       the draft after the user-supplied submit closure returns
//       without throwing. A failed submit leaves the draft intact for
//       retry.
//
//  Conformers expose `hasUserContent` so the displacement policy
//  (Phase 3) can avoid bumping a sheet whose user has typed real
//  content. The default soft-displacement policy demotes
//  `.replaceLowerPriority` requests to `.queue` when the active sheet's
//  coordinator reports `hasUserContent == true`.
//
//  Threading: every method runs on the main actor. The debounce timer
//  fires on the main actor too — there is no off-main work in this
//  protocol.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DraftBackedFormCoordinator")

// MARK: - Protocol

@MainActor
protocol DraftBackedFormCoordinator: AnyObject {
    /// The codable snapshot type for this form. Must be stable across
    /// app versions; new fields use `decodeIfPresent` + defaults so
    /// older drafts continue to decode.
    associatedtype Payload: Codable

    /// What kind of form this coordinator owns. Identifies the row
    /// namespace in `FormDraft` and downstream UI surfaces (Today
    /// restore banner copy, displacement telemetry).
    var formKind: FormKind { get }

    /// Identity of the form's subject (meeting UUID, person UUID,
    /// outcome UUID, …). For brand-new entities, the coordinator must
    /// allocate a stable UUID at first edit and reuse it on restore.
    var subjectID: UUID { get }

    /// Monotonic version of the `Payload` schema. Bump when adding
    /// non-optional fields or changing semantics. Drafts whose stored
    /// version is too old to decode are surfaced as undecodable in the
    /// auto-discard notice (Phase 4) and otherwise ignored.
    var payloadVersion: Int { get }

    /// True when the user has typed real content. Used by Phase 3's
    /// soft-displacement policy in `ModalCoordinator` to avoid bumping
    /// a sheet that holds in-progress work.
    var hasUserContent: Bool { get }

    /// Optional title surfaced on the Today restore banner. Conforming
    /// coordinators return a short, human-readable label (e.g. the
    /// meeting title for post-meeting capture). Default nil — the banner
    /// falls back to a generic "Unfinished note" label.
    var draftDisplayTitle: String? { get }

    /// Optional subtitle for the banner (typically a date or person).
    /// Default nil.
    var draftDisplaySubtitle: String? { get }

    /// The debounce helper. Coordinators declare this as a stored
    /// property; the default extension uses it to coalesce frequent
    /// edits into single disk writes.
    var draftFlushScheduler: DraftFlushScheduler { get }

    /// Snapshot the current form state into a serializable payload.
    /// Called by the flush timer and at submit time.
    func capturePayload() -> Payload

    /// Apply a payload's values to the coordinator's @Observable state.
    /// Called by `restoreFromDraft()` after hydration. Implementations
    /// should defensively filter dangling references (e.g. UUIDs
    /// pointing at deleted entities) before assigning.
    func applyPayload(_ payload: Payload)
}

// MARK: - Default Implementations

extension DraftBackedFormCoordinator {

    var payloadVersion: Int { 1 }
    var draftDisplayTitle: String? { nil }
    var draftDisplaySubtitle: String? { nil }

    /// Hydrate from any existing draft for this `(formKind, subjectID)`.
    /// Call this once during coordinator init *after* `subjectID` is
    /// set. If the draft is missing or fails to decode, the coordinator
    /// remains at its initial state and a separate path will surface
    /// the undecodable draft to the user.
    func restoreFromDraft() {
        guard let payload = DraftPersistenceService.shared.load(
            Payload.self,
            kind: formKind,
            subjectID: subjectID
        ) else { return }
        applyPayload(payload)
        logger.debug("Restored \(self.formKind.rawValue) draft for subject \(self.subjectID)")
    }

    /// Schedule a debounced flush. Call from every `@Observable`
    /// property setter (typically inside `didSet`). Successive calls
    /// within the debounce window collapse into one disk write.
    func scheduleDraftFlush() {
        draftFlushScheduler.schedule { [weak self] in
            self?.flushNow()
        }
    }

    /// Flush the current state to disk immediately, cancelling any
    /// pending debounced flush. Call from `onDisappear` so the last
    /// keystrokes before view tear-down aren't lost in the debounce
    /// window. Also called by `submitAndClear` to keep the draft in
    /// sync if the submit closure throws.
    func flushNow() {
        draftFlushScheduler.cancel()
        let payload = capturePayload()
        do {
            _ = try DraftPersistenceService.shared.save(
                kind: formKind,
                subjectID: subjectID,
                payload: payload,
                payloadVersion: payloadVersion,
                displayTitle: draftDisplayTitle,
                displaySubtitle: draftDisplaySubtitle
            )
        } catch {
            logger.warning("Failed to persist \(self.formKind.rawValue) draft for subject \(self.subjectID): \(error.localizedDescription)")
        }
    }

    /// Delete the draft from disk and cancel any pending flush. Call on
    /// explicit user discard. Submit success goes through
    /// `submitAndClear` instead so the draft survives a failed submit.
    func clearDraft() {
        draftFlushScheduler.cancel()
        DraftPersistenceService.shared.delete(kind: formKind, subjectID: subjectID)
        // The Today restore banner subscribes to this — without it the
        // banner would only refresh on the next view appear.
        NotificationCenter.default.post(name: .samFormDraftsDidChange, object: nil)
    }

    /// Run the user-supplied submit closure, and on success delete the
    /// draft. On failure, the draft is left intact (and re-flushed) so
    /// the user can retry without losing their work.
    func submitAndClear(_ submit: () throws -> Void) throws {
        do {
            try submit()
        } catch {
            // Submit failed — make sure the latest state is durably on
            // disk so a retry from a fresh sheet still has the work.
            flushNow()
            throw error
        }
        clearDraft()
    }
}

// MARK: - Flush Scheduler

/// Debounce helper for `DraftBackedFormCoordinator`. Holds a single
/// in-flight `Task` per coordinator; rescheduling cancels the previous
/// one. Lives as a stored property on the coordinator so its lifetime
/// matches the form session.
@MainActor
final class DraftFlushScheduler {
    private var pendingFlush: Task<Void, Never>?
    private let delay: Duration

    init(delay: Duration = .milliseconds(1_500)) {
        self.delay = delay
    }

    func schedule(_ action: @escaping () -> Void) {
        pendingFlush?.cancel()
        pendingFlush = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        pendingFlush?.cancel()
        pendingFlush = nil
    }

    deinit {
        pendingFlush?.cancel()
    }
}
