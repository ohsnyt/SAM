//
//  SAMModelContainer.swift
//  SAM_crm
//
//  Single source of truth for the SwiftData ModelContainer.
//  • Lists every @Model class the app owns.
//  • Exposes a shared container instance so both the App scene and
//    any background tasks can reach the same store.
//  • Provides the convenience method that seeds on first launch.
//

import SwiftData
import Foundation

// ─────────────────────────────────────────────────────────────────────
// MARK: - Schema
// ─────────────────────────────────────────────────────────────────────

/// Every @Model class in the app, listed once.  SwiftData uses this
/// to build the underlying schema; if a class is missing here it
/// won't get a table.
enum SAMSchema {
    static let allModels: [any PersistentModel.Type] = [
        SamPerson.self,
        SamContext.self,
        ContextParticipation.self,
        Responsibility.self,
        JointInterest.self,
        ConsentRequirement.self,
        Product.self,
        Coverage.self,
        SamEvidenceItem.self,
    ]
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Container
// ─────────────────────────────────────────────────────────────────────

/// Lazily-created, process-lifetime container.  All code that needs
/// a ModelContext should derive one from here.
enum SAMModelContainer {

    /// The single shared container.  Throws on first access if
    /// SwiftData cannot create the store (e.g. sandbox path issue).
    /// In practice this never fails on a correctly-configured macOS
    /// target.
    static let shared: ModelContainer = {
        let schema     = Schema(SAMSchema.allModels)
        let config     = ModelConfiguration(
            "SAM",
            schema: schema,
            isStoredInMemoryOnly: false   // persistent on disk
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            // Fatal: without a container the app cannot function.
            fatalError("SAMModelContainer: failed to create ModelContainer — \(error)")
        }
    }()

    /// A fresh ModelContext bound to the shared container.
    /// Safe to call from any actor; ModelContext itself is not
    /// Sendable so callers should use it only on the actor that
    /// created it.
    static func newContext() -> ModelContext {
        ModelContext(shared)
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Seed hook
// ─────────────────────────────────────────────────────────────────────

extension SAMModelContainer {

    /// Call once at app launch.  Creates a context, runs the seed
    /// (which is itself a no-op after the first successful run), and
    /// discards the context.
    @MainActor
    static func seedOnFirstLaunch() {
        let ctx = newContext()
        SAMStoreSeed.seedIfNeeded(into: ctx)
    }
}
