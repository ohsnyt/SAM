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
        NoteImage.self,            // Note image attachments
        SamDailyBriefing.self,     // Daily briefing system
        SamUndoEntry.self,         // Phase P: Universal undo history
        TimeEntry.self,            // Phase Q: Time tracking & categorization
        StageTransition.self,      // Phase R: Pipeline intelligence audit log
        RecruitingStage.self,      // Phase R: Recruiting pipeline state
        ProductionRecord.self,     // Phase S: Production tracking
        StrategicDigest.self,      // Phase V: Business intelligence digests
        ContentPost.self,          // Phase W: Content posting tracker
        BusinessGoal.self,         // Phase X: Goal setting & decomposition
        ComplianceAuditEntry.self, // Phase Z: Compliance audit trail
        DeducedRelation.self,      // Deduced family relationships from contacts
        PendingEnrichment.self,    // Contact enrichment queue (schema SAM_v28)
        IntentionalTouch.self,          // LinkedIn/social touch scoring (schema SAM_v29)
        LinkedInImport.self,            // LinkedIn archive import history (schema SAM_v29)
        NotificationTypeTracker.self,   // LinkedIn notification type tracking (schema SAM_v33)
        ProfileAnalysisRecord.self,     // LinkedIn profile analysis history (schema SAM_v33)
        EngagementSnapshot.self,        // Social engagement metrics snapshots (schema SAM_v33)
        SocialProfileSnapshot.self,     // Platform-agnostic social profile storage (schema SAM_v33)
        FacebookImport.self,            // Facebook archive import history (schema SAM_v33)
        SubstackImport.self,            // Substack RSS/subscriber import history (schema SAM_v33)
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
            "SAM_v33", // Contact lifecycle management
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

    /// The default on-disk URL that ModelConfiguration("SAM_v33") uses.
    /// Computed without touching _shared so it is safe to call before the
    /// container is ever initialized (e.g. during a launch-time wipe).
    nonisolated static var defaultStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SAM_v33.store")
    }

    /// Delete the on-disk SQLite store files (main + -shm + -wal).
    /// MUST be called before _shared is first accessed; once any ModelContainer
    /// opens the files the OS will report "vnode unlinked while in use".
    nonisolated static func deleteStoreFiles() {
        let fm = FileManager.default
        let url = defaultStoreURL
        for ext in ["", ".shm", ".wal"] {
            let target = ext.isEmpty ? url : url.appendingPathExtension(String(ext.dropFirst()))
            try? fm.removeItem(at: target)
        }
    }

    /// Construct a fresh ModelContainer for testing or reset.
    nonisolated static func makeFreshContainer() -> ModelContainer {
        let schema = Schema(SAMSchema.allModels)
        let config = ModelConfiguration(
            "SAM_v33", // Contact lifecycle management
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
            "SAM_v33", // Contact lifecycle management
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

    // MARK: - One-Time Migrations

    /// Migrate isArchivedLegacy → lifecycleStatusRawValue for v31→v32.
    /// Safe to call multiple times; uses a UserDefaults flag to run once.
    @MainActor
    static func runMigrationV32IfNeeded() {
        let key = "sam.migration.v32.lifecycleDone"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let context = ModelContext(shared)
        do {
            let descriptor = FetchDescriptor<SamPerson>(
                predicate: #Predicate { $0.isArchivedLegacy == true }
            )
            let archived = try context.fetch(descriptor)
            for person in archived {
                if person.lifecycleStatusRawValue == ContactLifecycleStatus.active.rawValue {
                    person.lifecycleStatusRawValue = ContactLifecycleStatus.archived.rawValue
                    person.lifecycleChangedAt = .now
                }
            }
            if !archived.isEmpty {
                try context.save()
            }
        } catch {
            // Non-fatal: worst case archived contacts appear as active temporarily
        }

        UserDefaults.standard.set(true, forKey: key)
    }
}

