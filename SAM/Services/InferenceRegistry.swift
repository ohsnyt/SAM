//
//  InferenceRegistry.swift
//  SAM
//
//  Source-of-truth for "what AI work is happening right now." AIService
//  registers each call with the registry as it enters the inference gate
//  and removes it when the call finishes. The sidebar footer (MinionsView)
//  reads from `groupedActivity` to display a row per active label.
//
//  Design intent — plug the same gap we just plugged for shutdown safety
//  with `AIService.activeGenerationCount`, but for the visible UI: any new
//  AI caller that registers a task automatically appears in the footer
//  without anyone remembering to update MinionsView.
//

import Foundation

// MARK: - InferenceTask

/// A labeled unit of AI work. The label/icon are what the user sees in the
/// sidebar footer; `source` is for tooltip / debugging only. Priority is
/// carried through to SerialGate so the registry doesn't have to know about
/// the gate's internals.
struct InferenceTask: Identifiable, Sendable {
    let id: UUID
    let label: String
    let icon: String
    let source: String
    let priority: AIService.Priority
    let startedAt: Date

    init(
        label: String,
        icon: String = "sparkles",
        source: String,
        priority: AIService.Priority = .background
    ) {
        self.id = UUID()
        self.label = label
        self.icon = icon
        self.source = source
        self.priority = priority
        self.startedAt = Date()
    }

    /// Fallback task synthesized for callers that haven't been migrated to
    /// the labeled API yet. Shows up in the footer as a generic "AI" row.
    /// During Phase B migration this should drop to zero use; a debug
    /// assertion in `AIService.runSerialized(priority:)` would be a good
    /// way to spot stragglers if needed.
    static func generic(priority: AIService.Priority) -> InferenceTask {
        InferenceTask(
            label: "AI",
            icon: "sparkles",
            source: "Unspecified",
            priority: priority
        )
    }
}

// MARK: - InferenceRegistry

@MainActor
@Observable
final class InferenceRegistry {

    static let shared = InferenceRegistry()
    private init() {}

    /// The task currently holding the inference gate's slot.
    private(set) var running: InferenceTask?

    /// Tasks waiting their turn behind `running`.
    private(set) var queued: [InferenceTask] = []

    // MARK: - Mutations (called by AIService)

    /// Caller has just called `gate.enter` but hasn't been admitted yet.
    func enqueue(_ task: InferenceTask) {
        queued.append(task)
    }

    /// Caller's `gate.enter` returned — they're now the running task.
    func markRunning(_ task: InferenceTask) {
        queued.removeAll { $0.id == task.id }
        running = task
    }

    /// Caller's body finished (success or throw) — release the slot.
    func remove(_ task: InferenceTask) {
        queued.removeAll { $0.id == task.id }
        if running?.id == task.id {
            running = nil
        }
    }

    // MARK: - UI grouping

    /// One row per distinct label, with a count badge for repeats. Running
    /// groups sort first; the rest alphabetical. The sidebar's
    /// min-display-time filter (Phase D) lives here so a 50ms inference
    /// doesn't flash a row.
    struct GroupedActivity: Identifiable, Equatable {
        let id: String       // == label
        let label: String
        let icon: String
        let count: Int
        let isRunning: Bool
    }

    var groupedActivity: [GroupedActivity] {
        struct Bucket { var icon: String; var count: Int; var hasRunning: Bool }
        var byLabel: [String: Bucket] = [:]
        if let r = running {
            var b = byLabel[r.label] ?? Bucket(icon: r.icon, count: 0, hasRunning: false)
            b.count += 1
            b.hasRunning = true
            byLabel[r.label] = b
        }
        for t in queued {
            var b = byLabel[t.label] ?? Bucket(icon: t.icon, count: 0, hasRunning: false)
            b.count += 1
            byLabel[t.label] = b
        }
        return byLabel.map { (label, b) in
            GroupedActivity(
                id: label,
                label: label,
                icon: b.icon,
                count: b.count,
                isRunning: b.hasRunning
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning && !rhs.isRunning }
            return lhs.label < rhs.label
        }
    }
}
