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
import Synchronization

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
        RoleDefinition.self,                    // Role recruiting definitions
        RoleCandidate.self,                     // Role recruiting candidates
        GoalJournalEntry.self,                  // Goal check-in journal entries
        EventEvaluation.self,                      // Post-event evaluation & workshop analysis
        SamTrip.self,                                  // Phase F1: Trip/mileage tracking (iOS companion)
        SamTripStop.self,                              // Phase F1: Trip stop locations
        TranscriptSession.self,                        // Speaker-diarized transcription sessions
        TranscriptSegment.self,                        // Speaker-attributed transcript segments
        SpeakerProfile.self,                           // Enrolled voice embeddings
        PendingUpload.self,                            // Phase B: iPhone-side pending upload queue
        ProcessedSessionTombstone.self,                // Prevents SAMField re-uploading sessions the user deleted on the Mac
    ]
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Container
// ─────────────────────────────────────────────────────────────────────

/// Lazily-created, process-lifetime container.  All code that needs
/// a ModelContext should derive one from here.
enum SAMModelContainer {

    private nonisolated static var containerLogger: Logger {
        Logger(subsystem: "com.matthewsessions.SAM", category: "SAMModelContainer")
    }

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
    // Mutex-protected backing storage for mutable shared container in DEBUG builds.
    private nonisolated static let _sharedMutex: Mutex<ModelContainer> = Mutex({
        checkpointStoreIfNeeded()
        backupStoreBeforeOpen()
        cleanupOrphanedReferences()

        let schema = Schema(SAMSchema.allModels)
        let config = ModelConfiguration(
            schemaVersion,
            schema: schema,
            isStoredInMemoryOnly: false,  // persistent on disk
            cloudKitDatabase: .none       // CloudKit used via CKContainer directly, not SwiftData sync
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SAMModelContainer: failed to create ModelContainer — \(error)")
        }
    }())

    /// DEBUG-only mutable shared container for reset flows.
    nonisolated static var shared: ModelContainer { _sharedMutex.withLock { $0 } }

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
        _sharedMutex.withLock { $0 = container }
    }
    #else
    /// Immutable shared container for production.
    nonisolated static let shared: ModelContainer = {
        // 1. Flush WAL so the backup contains a clean, self-contained store.
        checkpointStoreIfNeeded()
        // 2. Snapshot the store files BEFORE opening (migration may run on open).
        backupStoreBeforeOpen()
        // 3. Repair any dangling foreign-key references.
        cleanupOrphanedReferences()

        let schema     = Schema(SAMSchema.allModels)
        let config     = ModelConfiguration(
            schemaVersion,
            schema: schema,
            isStoredInMemoryOnly: false,  // persistent on disk
            cloudKitDatabase: .none       // CloudKit used via CKContainer directly, not SwiftData sync
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

    // MARK: - Pre-Open Backup

    /// Copy the current SQLite store files to a timestamped backup before the
    /// container opens (which may trigger lightweight migration). Run AFTER a
    /// WAL checkpoint so the backup is a clean, self-contained store file.
    /// Keeps the last 3 backups per schema version; older ones are pruned.
    private nonisolated static func backupStoreBeforeOpen() {
        let fm = FileManager.default
        let storeURL = defaultStoreURL
        guard fm.fileExists(atPath: storeURL.path) else { return }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let backupDir = appSupport.appendingPathComponent("SAM-PreOpenBackups")
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            containerLogger.warning("Pre-open backup: could not create directory — \(error.localizedDescription)")
            return
        }

        // Build a filename-safe ISO-8601 timestamp (replace colons with hyphens).
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupBaseName = "\(schemaVersion)-\(stamp)"
        let backupStoreURL = backupDir.appendingPathComponent(backupBaseName + ".store")

        // Copy the main store plus its WAL and SHM companions if present.
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: backupStoreURL.path + suffix)
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                containerLogger.warning("Pre-open backup: could not copy \(src.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        containerLogger.info("Pre-open backup written: \(backupBaseName).store")

        prunePreOpenBackups(in: backupDir)
    }

    /// Remove old pre-open backups, keeping only the 3 most recent for this schema version.
    private nonisolated static func prunePreOpenBackups(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Collect only the main .store files for this schema version (companions are pruned with them).
        let stores = items
            .filter { $0.lastPathComponent.hasPrefix(schemaVersion) && $0.pathExtension == "store" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b   // newest first
            }

        for old in stores.dropFirst(3) {
            let base = old.deletingPathExtension().lastPathComponent   // e.g. SAM_v34-2026-03-30T12-00-00Z
            for suffix in [".store", ".store-wal", ".store-shm"] {
                try? fm.removeItem(at: dir.appendingPathComponent(base + suffix))
            }
            containerLogger.debug("Pre-open backup pruned: \(old.lastPathComponent)")
        }
    }

    // MARK: - Startup Cleanup

    /// Clean up orphaned references to deleted records.
    /// SwiftData's .nullify delete rule doesn't always fire reliably,
    /// so we use raw SQL to nil out stale foreign keys.
    /// Runs before SwiftData opens the store to prevent faulting crashes.
    private nonisolated static func cleanupOrphanedReferences() {
        let url = defaultStoreURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        // Map of FK column names → the parent table they reference.
        // Any row where the FK value is NOT NULL but doesn't exist in the parent
        // table's Z_PK column is a dangling reference that will SIGTRAP SwiftData.
        let fkMappings: [(column: String, parentTable: String)] = [
            ("ZLINKEDPERSON",  "ZSAMPERSON"),
            ("ZLINKEDCONTEXT", "ZSAMCONTEXT"),
            ("ZPERSON",        "ZSAMPERSON"),
            ("ZEVENT",         "ZSAMEVENT"),
        ]

        // Collect all Z-prefixed tables
        var tables: OpaquePointer?
        let tablesSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%'"
        guard sqlite3_prepare_v2(db, tablesSQL, -1, &tables, nil) == SQLITE_OK else { return }

        var tableNames: [String] = []
        while sqlite3_step(tables) == SQLITE_ROW {
            guard let c = sqlite3_column_text(tables, 0) else { continue }
            tableNames.append(String(cString: c))
        }
        sqlite3_finalize(tables)

        var totalCleaned = 0
        for tableName in tableNames {
            for (col, parentTable) in fkMappings {
                // Check if this table has the FK column
                let colCheckSQL = "SELECT COUNT(*) FROM pragma_table_info('\(tableName)') WHERE name='\(col)'"
                var colCheck: OpaquePointer?
                guard sqlite3_prepare_v2(db, colCheckSQL, -1, &colCheck, nil) == SQLITE_OK,
                      sqlite3_step(colCheck) == SQLITE_ROW,
                      sqlite3_column_int(colCheck, 0) > 0 else {
                    sqlite3_finalize(colCheck)
                    continue
                }
                sqlite3_finalize(colCheck)

                // Verify the parent table exists
                let parentCheckSQL = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(parentTable)'"
                var parentCheck: OpaquePointer?
                guard sqlite3_prepare_v2(db, parentCheckSQL, -1, &parentCheck, nil) == SQLITE_OK,
                      sqlite3_step(parentCheck) == SQLITE_ROW,
                      sqlite3_column_int(parentCheck, 0) > 0 else {
                    sqlite3_finalize(parentCheck)
                    continue
                }
                sqlite3_finalize(parentCheck)

                // Null out orphaned references
                let cleanSQL = """
                    UPDATE \(tableName) SET \(col) = NULL
                    WHERE \(col) IS NOT NULL
                    AND \(col) NOT IN (SELECT Z_PK FROM \(parentTable))
                    """
                var cleanStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, cleanSQL, -1, &cleanStmt, nil) == SQLITE_OK {
                    if sqlite3_step(cleanStmt) == SQLITE_DONE {
                        let changes = Int(sqlite3_changes(db))
                        if changes > 0 {
                            containerLogger.info("Orphan cleanup: nullified \(changes) stale \(col) references in \(tableName) (parent: \(parentTable))")
                        }
                        totalCleaned += changes
                    }
                }
                sqlite3_finalize(cleanStmt)
            }
        }

        if totalCleaned > 0 {
            containerLogger.notice("Orphan cleanup: \(totalCleaned) total dangling references repaired")
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

