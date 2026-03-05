//
//  LegacyStoreMigrationService.swift
//  SAM
//
//  Discovers orphaned SAM_v*.store files from previous schema versions,
//  migrates the most recent via backup round-trip, and cleans up old files.
//

import SwiftData
import Foundation
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
            logger.info("No legacy stores found")
        } else {
            logger.info("Found \(result.count) legacy stores (\(result.formattedSize)), most recent: \(result.mostRecent?.version ?? "none")")
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
            logger.info("Attempting migration from \(source.version)")

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
                logger.info("\(source.version) is empty — skipping")
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
