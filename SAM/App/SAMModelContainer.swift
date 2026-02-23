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
import Combine

// ─────────────────────────────────────────────────────────────────────
// MARK: - Schema
// ─────────────────────────────────────────────────────────────────────

/// Every @Model class in the app, listed once.  SwiftData uses this
/// to build the underlying schema; if a class is missing here it
/// won't get a table.
enum SAMSchema {
    nonisolated static let allModels: [any PersistentModel.Type] = [
        SamPerson.self,
        SamContext.self,
        ContextParticipation.self,
        Responsibility.self,
        JointInterest.self,
        ConsentRequirement.self,
        Product.self,
        Coverage.self,
        SamEvidenceItem.self,
        SamInsight.self,
        SamNote.self,  // Added for Phase 5 notes feature
        SamAnalysisArtifact.self,  // Added for note/email/zoom analysis storage
        UnknownSender.self,
        SamOutcome.self,           // Phase N: Outcome-focused coaching
        CoachingProfile.self,      // Phase N: Adaptive coaching profile
    ]
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Container
// ─────────────────────────────────────────────────────────────────────

/// Lazily-created, process-lifetime container.  All code that needs
/// a ModelContext should derive one from here.
enum SAMModelContainer {

    #if DEBUG
    // Backing storage for mutable shared container in DEBUG builds.
    nonisolated(unsafe) private static var _shared: ModelContainer = {
        let schema     = Schema(SAMSchema.allModels)
        let config     = ModelConfiguration(
            "SAM_v11", // v10: added linkedEvidence inverse on SamPerson + SamContext
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

    /// DEBUG-only mutable shared container for reset flows.
    nonisolated static var shared: ModelContainer { _shared }

    /// Construct a fresh ModelContainer for testing or reset.
    nonisolated static func makeFreshContainer() -> ModelContainer {
        let schema = Schema(SAMSchema.allModels)
        let config = ModelConfiguration(
            "SAM_v11", // v10: added linkedEvidence inverse on SamPerson + SamContext
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SAMModelContainer: failed to create fresh ModelContainer — \(error)")
        }
    }

    /// Replace the shared container with a new one.
    nonisolated static func replaceShared(with container: ModelContainer) {
        _shared = container
    }
    #else
    /// Immutable shared container for production.
    nonisolated static let shared: ModelContainer = {
        let schema     = Schema(SAMSchema.allModels)
        let config     = ModelConfiguration(
            "SAM_v11", // v10: added linkedEvidence inverse on SamPerson + SamContext
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
    #endif

    /// A fresh ModelContext bound to the shared container.
    /// Safe to call from any actor; ModelContext itself is not
    /// Sendable so callers should use it only on the actor that
    /// created it.
    nonisolated static func newContext() -> ModelContext {
        ModelContext(shared)
    }
}

