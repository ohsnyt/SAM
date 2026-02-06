import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Seed hook (separate file to avoid actor inference on SAMModelContainer)
// ─────────────────────────────────────────────────────────────────────

/// Call once at app launch.  Creates a context, runs the seed
/// (which is itself a no-op after the first successful run), and
/// discards the context.
///
/// Kept in a separate file to avoid Swift's actor isolation inference
/// from tainting SAMModelContainer with MainActor isolation.
@MainActor
func seedModelContainerOnFirstLaunch() {
    let ctx = SAMModelContainer.newContext()
    SAMStoreSeed.seedIfNeeded(into: ctx)
}
