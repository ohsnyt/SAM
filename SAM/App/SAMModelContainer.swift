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
import SQLite3
import os.log

private let containerLogger = Logger(subsystem: "com.matthewsessions.SAM", category: "SAMModelContainer")

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
        NotificationTypeTracker.self,   // LinkedIn notification type tracking (schema SAM_v34)
        ProfileAnalysisRecord.self,     // LinkedIn profile analysis history (schema SAM_v34)
        EngagementSnapshot.self,        // Social engagement metrics snapshots (schema SAM_v34)
        SocialProfileSnapshot.self,     // Platform-agnostic social profile storage (schema SAM_v34)
        FacebookImport.self,            // Facebook archive import history (schema SAM_v34)
        SubstackImport.self,            // Substack RSS/subscriber import history (schema SAM_v34)
        SamEvent.self,                      // Event/workshop management with RSVP tracking
        EventParticipation.self,            // Event ↔ Person join table with RSVP state
        SamPresentation.self,               // Presentation library for recurring workshops
    ]
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Container
// ─────────────────────────────────────────────────────────────────────

/// Lazily-created, process-lifetime container.  All code that needs
/// a ModelContext should derive one from here.
enum SAMModelContainer {

    // IMPORTANT: Do NOT change schemaVersion for additive schema changes.
    // SwiftData handles new models and new fields with defaults via
    // lightweight migration automatically. Changing the config name
    // creates a NEW empty store, abandoning all existing data.
    // Only change schemaVersion for destructive migrations that require
    // a SchemaMigrationPlan.
    nonisolated static let schemaVersion = "SAM_v34"

    /// Force a WAL checkpoint on the SQLite store to flush pending deletes.
    /// Prevents SwiftData crashes when accessing deleted-but-not-checkpointed records.
    private nonisolated static func checkpointStoreIfNeeded() {
        let url = defaultStoreURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        // TRUNCATE mode: checkpoint WAL and truncate the WAL file
        var logSize: Int32 = 0
        var checkpointCount: Int32 = 0
        let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &logSize, &checkpointCount)
        if rc == SQLITE_OK {
            containerLogger.info("WAL checkpoint complete: \(checkpointCount) pages checkpointed")
        } else {
            containerLogger.warning("WAL checkpoint returned \(rc)")
        }
    }

    /// The default on-disk URL that ModelConfiguration(schemaVersion) uses.
    /// Computed without touching shared so it is safe to call before the
    /// container is ever initialized (e.g. during a launch-time wipe).
    nonisolated static var defaultStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("\(schemaVersion).store")
    }

    #if DEBUG
    // Backing storage for mutable shared container in DEBUG builds.
    nonisolated(unsafe) private static var _shared: ModelContainer = {
        // Flush pending WAL changes and fix orphaned references before opening
        checkpointStoreIfNeeded()
        cleanupOrphanedReferences()

        let schema     = Schema(SAMSchema.allModels)
        let config     = ModelConfiguration(
            schemaVersion,
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
            schemaVersion,
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
        // Flush pending WAL changes and fix orphaned references before opening
        checkpointStoreIfNeeded()
        cleanupOrphanedReferences()

        let schema     = Schema(SAMSchema.allModels)
        let config     = ModelConfiguration(
            schemaVersion,
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

    // MARK: - Startup Cleanup

    /// Clean up orphaned references to deleted SamPerson records.
    /// SwiftData's .nullify delete rule doesn't always fire reliably,
    /// so we use raw SQL to nil out stale linkedPerson foreign keys.
    /// Runs before SwiftData opens the store to prevent faulting crashes.
    private nonisolated static func cleanupOrphanedReferences() {
        let url = defaultStoreURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        // Find all tables that have a ZLINKEDPERSON column pointing to ZSAMPERSON
        // and null out any that reference deleted rows.
        // Also handle other relationship columns that point to SamPerson.
        let fkColumns = ["ZLINKEDPERSON", "ZLINKEDCONTEXT"]
        let personTable = "ZSAMPERSON"

        // First verify the person table exists
        var tableCheck: OpaquePointer?
        let checkSQL = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(personTable)'"
        guard sqlite3_prepare_v2(db, checkSQL, -1, &tableCheck, nil) == SQLITE_OK,
              sqlite3_step(tableCheck) == SQLITE_ROW,
              sqlite3_column_int(tableCheck, 0) > 0 else {
            sqlite3_finalize(tableCheck)
            return
        }
        sqlite3_finalize(tableCheck)

        // Find all tables and check which ones have FK columns to person
        var tables: OpaquePointer?
        let tablesSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%'"
        guard sqlite3_prepare_v2(db, tablesSQL, -1, &tables, nil) == SQLITE_OK else { return }

        var totalCleaned = 0
        while sqlite3_step(tables) == SQLITE_ROW {
            guard let tableNameC = sqlite3_column_text(tables, 0) else { continue }
            let tableName = String(cString: tableNameC)

            for col in fkColumns {
                // Check if this table has the column
                let colCheckSQL = "SELECT COUNT(*) FROM pragma_table_info('\(tableName)') WHERE name='\(col)'"
                var colCheck: OpaquePointer?
                guard sqlite3_prepare_v2(db, colCheckSQL, -1, &colCheck, nil) == SQLITE_OK,
                      sqlite3_step(colCheck) == SQLITE_ROW,
                      sqlite3_column_int(colCheck, 0) > 0 else {
                    sqlite3_finalize(colCheck)
                    continue
                }
                sqlite3_finalize(colCheck)

                // Null out orphaned references
                let cleanSQL = """
                    UPDATE \(tableName) SET \(col) = NULL
                    WHERE \(col) IS NOT NULL
                    AND \(col) NOT IN (SELECT Z_PK FROM \(personTable))
                    """
                var cleanStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, cleanSQL, -1, &cleanStmt, nil) == SQLITE_OK {
                    if sqlite3_step(cleanStmt) == SQLITE_DONE {
                        let changes = Int(sqlite3_changes(db))
                        totalCleaned += changes
                    }
                }
                sqlite3_finalize(cleanStmt)
            }
        }
        sqlite3_finalize(tables)

        if totalCleaned > 0 {
            containerLogger.info("Orphan cleanup: nullified \(totalCleaned) stale person references")
        }
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

    /// Backfill directionRaw on existing evidence from isFromMe / source / title.
    /// Safe to call multiple times; uses a UserDefaults flag to run once.
    @MainActor
    static func runDirectionBackfillIfNeeded() {
        let key = "sam.migration.directionBackfillDone"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let context = ModelContext(shared)
        do {
            let descriptor = FetchDescriptor<SamEvidenceItem>()
            let all = try context.fetch(descriptor)
            var patched = 0
            for item in all where item.directionRaw == nil {
                switch item.source {
                case .iMessage, .whatsApp, .clipboardCapture:
                    item.direction = item.isFromMe ? .outbound : .inbound
                    patched += 1
                case .phoneCall, .faceTime:
                    // Titles contain "to" (outgoing) or "from" (incoming)
                    let lower = item.title.lowercased()
                    if lower.contains(" to ") {
                        item.direction = .outbound
                    } else if lower.contains(" from ") {
                        item.direction = .inbound
                    }
                    patched += 1
                case .mail:
                    // All existing mail evidence is from Inbox scanning
                    item.direction = .inbound
                    patched += 1
                case .calendar:
                    item.direction = .bidirectional
                    patched += 1
                case .whatsAppCall:
                    // Missed calls are inbound; answered calls are bidirectional
                    item.direction = item.snippet.lowercased() == "missed" ? .inbound : .bidirectional
                    patched += 1
                default:
                    break // notes, contacts, social — leave nil
                }
            }
            if patched > 0 {
                try context.save()
            }
        } catch {
            // Non-fatal: direction will be set on next import cycle
        }

        UserDefaults.standard.set(true, forKey: key)
    }
}

