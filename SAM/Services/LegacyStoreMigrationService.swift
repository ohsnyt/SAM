//
//  LegacyStoreMigrationService.swift
//  SAM
//
//  Discovers orphaned SAM_v*.store files from previous schema versions,
//  migrates the most recent via backup round-trip, and cleans up old files.
//

import SwiftData
import Foundation
import SQLite3
import os

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LegacyStoreMigration")

// ─────────────────────────────────────────────────────────────────────
// MARK: - Discovery Result
// ─────────────────────────────────────────────────────────────────────

struct LegacyStoreInfo: Sendable {
    let url: URL
    let version: String
    let versionNumber: Int
    let fileSize: UInt64 // main .store file only
}

struct LegacyStoreDiscovery: Sendable {
    let stores: [LegacyStoreInfo]
    let totalSizeBytes: UInt64
    let mostRecent: LegacyStoreInfo?

    var isEmpty: Bool { stores.isEmpty }
    var count: Int { stores.count }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSizeBytes), countStyle: .file)
    }
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Migration Status
// ─────────────────────────────────────────────────────────────────────

enum LegacyMigrationStatus: Equatable {
    case idle
    case discovering
    case migrating(String)
    case cleaning
    case success(String)
    case failed(String)
}

// ─────────────────────────────────────────────────────────────────────
// MARK: - Service
// ─────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class LegacyStoreMigrationService {
    static let shared = LegacyStoreMigrationService()

    var status: LegacyMigrationStatus = .idle
    var discovery: LegacyStoreDiscovery?

    var isBusy: Bool {
        switch status {
        case .migrating, .cleaning, .discovering: return true
        default: return false
        }
    }

    private init() {}

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Application Support Directory
    // ─────────────────────────────────────────────────────────────────

    private static var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Discover
    // ─────────────────────────────────────────────────────────────────

    /// Scan Application Support for orphaned SAM_v*.store files whose
    /// version doesn't match the current `SAMModelContainer.schemaVersion`.
    func discoverLegacyStores() {
        status = .discovering
        let fm = FileManager.default
        let dir = Self.appSupportDirectory
        let currentVersion = SAMModelContainer.schemaVersion

        var stores: [LegacyStoreInfo] = []
        var totalSize: UInt64 = 0

        do {
            let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            for fileURL in contents {
                let name = fileURL.lastPathComponent
                // Match pattern: SAM_v<number>.store (not .store-shm or .store-wal)
                guard name.hasPrefix("SAM_v"),
                      name.hasSuffix(".store"),
                      !name.contains("-") else { continue }

                let version = String(name.dropLast(".store".count)) // e.g. "SAM_v26"
                guard version != currentVersion else { continue }

                // Extract numeric version
                let numStr = version.replacingOccurrences(of: "SAM_v", with: "")
                guard let versionNumber = Int(numStr) else { continue }

                let attrs = try fm.attributesOfItem(atPath: fileURL.path)
                let fileSize = attrs[.size] as? UInt64 ?? 0

                // Also count companion files
                var companionSize: UInt64 = 0
                for ext in ["shm", "wal"] {
                    let companion = fileURL.appendingPathExtension(ext)
                    if let cAttrs = try? fm.attributesOfItem(atPath: companion.path) {
                        companionSize += cAttrs[.size] as? UInt64 ?? 0
                    }
                }
                // Also count _SUPPORT directory
                let supportDir = dir.appendingPathComponent("\(name)_SUPPORT")
                if fm.fileExists(atPath: supportDir.path) {
                    if let enumerator = fm.enumerator(at: supportDir, includingPropertiesForKeys: [.fileSizeKey]) {
                        while let item = enumerator.nextObject() as? URL {
                            if let cAttrs = try? fm.attributesOfItem(atPath: item.path) {
                                companionSize += cAttrs[.size] as? UInt64 ?? 0
                            }
                        }
                    }
                }

                let info = LegacyStoreInfo(
                    url: fileURL,
                    version: version,
                    versionNumber: versionNumber,
                    fileSize: fileSize
                )
                stores.append(info)
                totalSize += fileSize + companionSize
            }
        } catch {
            logger.error("Failed to scan Application Support: \(error)")
        }

        stores.sort { $0.versionNumber > $1.versionNumber }

        let result = LegacyStoreDiscovery(
            stores: stores,
            totalSizeBytes: totalSize,
            mostRecent: stores.first
        )
        discovery = result
        status = .idle

        if result.isEmpty {
            logger.debug("No legacy stores found")
        } else {
            logger.debug("Found \(result.count) legacy stores (\(result.formattedSize)), most recent: \(result.mostRecent?.version ?? "none")")
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Migrate
    // ─────────────────────────────────────────────────────────────────

    /// Migrate data from a legacy store into the current store via backup
    /// round-trip. Tries stores from most recent to oldest — newer stores
    /// are more likely to lightweight-migrate successfully.
    ///
    /// The legacy store is **copied to a temp directory** before opening so
    /// CoreData's in-place migration attempt doesn't corrupt the original.
    func migrate() async {
        guard let disc = discovery, !disc.stores.isEmpty else {
            status = .failed("No legacy stores to migrate")
            return
        }

        let fm = FileManager.default

        // Try stores from most recent to oldest
        for source in disc.stores {
            status = .migrating("Trying \(source.version)...")
            logger.debug("Attempting migration from \(source.version)")

            // 1. Copy store files to a temp directory to protect originals
            //    from CoreData's in-place migration attempt.
            let tempDir = fm.temporaryDirectory
                .appendingPathComponent("SAM-Migration-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                logger.error("Cannot create temp dir: \(error)")
                continue
            }

            let storeName = source.url.lastPathComponent
            let tempStoreURL = tempDir.appendingPathComponent(storeName)

            do {
                // Copy main store + companions
                try fm.copyItem(at: source.url, to: tempStoreURL)
                for ext in ["shm", "wal"] {
                    let companion = source.url.appendingPathExtension(ext)
                    if fm.fileExists(atPath: companion.path) {
                        try fm.copyItem(at: companion, to: tempStoreURL.appendingPathExtension(ext))
                    }
                }
            } catch {
                logger.error("Cannot copy \(source.version) to temp: \(error)")
                try? fm.removeItem(at: tempDir)
                continue
            }

            // 2. Open the copy with the current schema.
            //    SwiftData lightweight migration handles additive changes.
            //    If the store is too old (mandatory attributes missing),
            //    this will throw and we try the next store.
            let schema = Schema(SAMSchema.allModels)
            let tempConfigName = "SAM_migration_temp_\(source.versionNumber)"
            let legacyConfig = ModelConfiguration(
                tempConfigName,
                schema: schema,
                url: tempStoreURL,
                allowsSave: false
            )

            let legacyContainer: ModelContainer
            do {
                legacyContainer = try ModelContainer(for: schema, configurations: legacyConfig)
            } catch {
                logger.warning("Cannot open \(source.version) — lightweight migration failed: \(error.localizedDescription)")
                try? fm.removeItem(at: tempDir)
                continue // Try the next oldest store
            }

            let legacyContext = ModelContext(legacyContainer)

            // 3. Check if store has data
            let personCount: Int
            do {
                personCount = try legacyContext.fetchCount(FetchDescriptor<SamPerson>())
            } catch {
                logger.warning("\(source.version): cannot read person count: \(error)")
                try? fm.removeItem(at: tempDir)
                continue
            }

            if personCount == 0 {
                logger.debug("\(source.version) is empty — skipping")
                try? fm.removeItem(at: tempDir)
                continue
            }

            status = .migrating("Found \(personCount) people in \(source.version)...")

            // 4. Export via BackupCoordinator
            status = .migrating("Exporting from \(source.version)...")
            let backupURL = tempDir.appendingPathComponent("migration.sambackup")
            await BackupCoordinator.shared.exportBackup(to: backupURL, container: legacyContainer)

            // Check export succeeded
            if case .failed(let msg) = BackupCoordinator.shared.status {
                logger.warning("Export from \(source.version) failed: \(msg)")
                try? fm.removeItem(at: tempDir)
                continue
            }

            // 5. Import into current live store
            status = .migrating("Importing into current store...")
            await BackupCoordinator.shared.performImport(from: backupURL)

            // Clean up temp directory
            try? fm.removeItem(at: tempDir)

            // Check import result
            if case .failed(let msg) = BackupCoordinator.shared.status {
                status = .failed("Import failed: \(msg)")
                return
            }

            status = .success("Migrated \(personCount) people from \(source.version)")
            logger.info("Migration from \(source.version) completed successfully")
            // Clear the startup detection flag
            UserDefaults.standard.removeObject(forKey: "sam.legacyStores.detected")
            return // Success — stop trying
        }

        // All stores failed
        status = .failed("Could not migrate any legacy store — schemas too old for lightweight migration")
        logger.error("All legacy store migration attempts failed")
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Cleanup
    // ─────────────────────────────────────────────────────────────────

    /// Delete all orphaned legacy store files and their companions.
    func cleanupLegacyStores() {
        guard let disc = discovery, !disc.isEmpty else {
            status = .failed("No legacy stores to clean up")
            return
        }

        status = .cleaning
        let fm = FileManager.default
        var deletedCount = 0
        var reclaimedBytes: UInt64 = 0

        for store in disc.stores {
            let baseURL = store.url
            let name = baseURL.lastPathComponent

            // Delete main .store file
            do {
                let attrs = try fm.attributesOfItem(atPath: baseURL.path)
                reclaimedBytes += attrs[.size] as? UInt64 ?? 0
                try fm.removeItem(at: baseURL)
                deletedCount += 1
            } catch {
                logger.error("Failed to delete \(name): \(error)")
            }

            // Delete companion files: .store-shm, .store-wal
            for ext in ["shm", "wal"] {
                let companion = baseURL.appendingPathExtension(ext)
                if fm.fileExists(atPath: companion.path) {
                    do {
                        let attrs = try fm.attributesOfItem(atPath: companion.path)
                        reclaimedBytes += attrs[.size] as? UInt64 ?? 0
                        try fm.removeItem(at: companion)
                    } catch {
                        logger.error("Failed to delete \(companion.lastPathComponent): \(error)")
                    }
                }
            }

            // Delete _SUPPORT directory
            let dir = Self.appSupportDirectory
            let supportDir = dir.appendingPathComponent("\(name)_SUPPORT")
            if fm.fileExists(atPath: supportDir.path) {
                do {
                    if let enumerator = fm.enumerator(at: supportDir, includingPropertiesForKeys: [.fileSizeKey]) {
                        while let item = enumerator.nextObject() as? URL {
                            if let attrs = try? fm.attributesOfItem(atPath: item.path) {
                                reclaimedBytes += attrs[.size] as? UInt64 ?? 0
                            }
                        }
                    }
                    try fm.removeItem(at: supportDir)
                } catch {
                    logger.error("Failed to delete \(supportDir.lastPathComponent): \(error)")
                }
            }
        }

        let formatted = ByteCountFormatter.string(fromByteCount: Int64(reclaimedBytes), countStyle: .file)
        status = .success("Removed \(deletedCount) legacy stores, reclaimed \(formatted)")
        logger.info("Cleanup complete: \(deletedCount) stores removed, \(formatted) reclaimed")

        // Refresh discovery
        discovery = LegacyStoreDiscovery(stores: [], totalSizeBytes: 0, mostRecent: nil)
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Role Extraction (SQLite3 fallback)
    // ─────────────────────────────────────────────────────────────────

    /// Result of extracting roles from a legacy store via raw SQLite3.
    struct RoleExtractionResult {
        let storeVersion: String
        let totalPersons: Int
        let personsWithRoles: Int
        let matched: Int
        let applied: Int
    }

    /// When full migration fails (schema too old), fall back to raw SQLite3
    /// to extract contactIdentifier + roleBadges from the legacy store and
    /// apply them to matching contacts in the current store.
    func migrateRolesOnly() async -> RoleExtractionResult? {
        guard let disc = discovery, !disc.stores.isEmpty else {
            status = .failed("No legacy stores found")
            return nil
        }

        // Try stores from most recent to oldest
        for source in disc.stores {
            status = .migrating("Extracting roles from \(source.version)...")
            logger.debug("Attempting role extraction from \(source.version) via SQLite3")

            guard let result = await extractAndApplyRoles(from: source) else {
                continue // Try next store
            }

            status = .success("Imported \(result.applied) role assignments from \(source.version)")
            UserDefaults.standard.removeObject(forKey: "sam.legacyStores.detected")
            return result
        }

        status = .failed("Could not extract roles from any legacy store")
        return nil
    }

    private func extractAndApplyRoles(from source: LegacyStoreInfo) async -> RoleExtractionResult? {
        // 1. Open legacy store with raw SQLite3
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            source.url.path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK else {
            let err = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            logger.warning("Cannot open \(source.version): \(err)")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // 2. Query for contactIdentifier, roleBadges, and displayNameCache.
        //    SwiftData stores [String] arrays as binary plists in SQLite.
        //    Column names use Z-prefix convention from CoreData.
        let query = """
            SELECT ZCONTACTIDENTIFIER, ZROLEBADGES, ZDISPLAYNAMECACHE
            FROM ZSAMPERSON
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db!))
            logger.warning("Query failed on \(source.version): \(err)")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        // 3. Collect legacy role data
        struct LegacyPersonRole {
            let contactIdentifier: String?
            let displayName: String?
            let roleBadges: [String]
        }

        var legacyRoles: [LegacyPersonRole] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            // contactIdentifier (text, nullable)
            let contactID: String? = sqlite3_column_type(stmt, 0) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 0))
                : nil

            // roleBadges (binary plist blob)
            let badges: [String]
            if sqlite3_column_type(stmt, 1) != SQLITE_NULL,
               let blobPtr = sqlite3_column_blob(stmt, 1) {
                let blobSize = Int(sqlite3_column_bytes(stmt, 1))
                let data = Data(bytes: blobPtr, count: blobSize)
                // SwiftData stores [String] as NSKeyedArchiver binary plist
                if let decoded = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClasses: [NSArray.self, NSString.self],
                    from: data
                ) as? [String] {
                    badges = decoded
                } else if let decoded = try? PropertyListSerialization.propertyList(
                    from: data, format: nil
                ) as? [String] {
                    badges = decoded
                } else {
                    badges = []
                }
            } else {
                badges = []
            }

            // displayNameCache (text, nullable)
            let displayName: String? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 2))
                : nil

            legacyRoles.append(LegacyPersonRole(
                contactIdentifier: contactID,
                displayName: displayName,
                roleBadges: badges
            ))
        }

        let totalPersons = legacyRoles.count
        let withRoles = legacyRoles.filter { !$0.roleBadges.isEmpty }

        if withRoles.isEmpty {
            logger.debug("\(source.version): found \(totalPersons) persons but none have roles")
            return nil
        }

        logger.debug("\(source.version): found \(withRoles.count) persons with roles out of \(totalPersons)")
        status = .migrating("Found \(withRoles.count) contacts with roles...")

        // 4. Match against current store and apply roles
        let context = ModelContext(SAMModelContainer.shared)
        var matched = 0
        var applied = 0

        // Build lookup of current persons by contactIdentifier
        let currentPersons: [SamPerson]
        do {
            currentPersons = try context.fetch(FetchDescriptor<SamPerson>())
        } catch {
            logger.error("Cannot fetch current persons: \(error)")
            return nil
        }

        var byContactID: [String: SamPerson] = [:]
        var byName: [String: SamPerson] = [:]
        for person in currentPersons {
            if let cid = person.contactIdentifier {
                byContactID[cid] = person
            }
            if let name = person.displayNameCache?.lowercased(), !name.isEmpty {
                byName[name] = person
            }
        }

        for legacy in withRoles {
            // Try contactIdentifier match first (most reliable)
            var target: SamPerson?
            if let cid = legacy.contactIdentifier {
                target = byContactID[cid]
            }

            // Fallback: display name match
            if target == nil, let name = legacy.displayName?.lowercased(), !name.isEmpty {
                target = byName[name]
            }

            guard let person = target else { continue }
            matched += 1

            // Apply roles that the person doesn't already have
            let newRoles = legacy.roleBadges.filter { !person.roleBadges.contains($0) }
            if !newRoles.isEmpty {
                person.roleBadges.append(contentsOf: newRoles)
                applied += 1
                logger.debug("Applied roles \(newRoles) to \(person.displayNameCache ?? "unknown")")
            }
        }

        // Save
        do {
            try context.save()
            logger.info("Role extraction complete: \(matched) matched, \(applied) updated")
        } catch {
            logger.error("Failed to save role assignments: \(error)")
            return nil
        }

        return RoleExtractionResult(
            storeVersion: source.version,
            totalPersons: totalPersons,
            personsWithRoles: withRoles.count,
            matched: matched,
            applied: applied
        )
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Quick Check (for startup detection)
    // ─────────────────────────────────────────────────────────────────

    /// Lightweight check: are there any legacy stores? Does not update `discovery`.
    static func hasLegacyStores() -> Bool {
        let fm = FileManager.default
        let dir = appSupportDirectory
        let currentVersion = SAMModelContainer.schemaVersion

        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return false
        }

        return contents.contains { fileURL in
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("SAM_v"),
                  name.hasSuffix(".store"),
                  !name.contains("-") else { return false }
            let version = String(name.dropLast(".store".count))
            return version != currentVersion
        }
    }
}
