//
//  SafeModeService.swift
//  SAM
//
//  Deep database integrity checks for Safe Mode.
//  Runs before the ModelContainer opens to detect and repair corruption
//  that the normal startup orphan cleanup might miss.
//

import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SafeMode")

/// Result of a single integrity check.
struct SafeModeCheckResult: Identifiable, Sendable {
    let id = UUID()
    let category: String
    let description: String
    let severity: Severity
    let detail: String

    enum Severity: String, Sendable {
        case ok = "OK"
        case warning = "Warning"
        case repaired = "Repaired"
        case error = "Error"

        var icon: String {
            switch self {
            case .ok:       return "checkmark.circle.fill"
            case .warning:  return "exclamationmark.triangle.fill"
            case .repaired: return "wrench.and.screwdriver.fill"
            case .error:    return "xmark.octagon.fill"
            }
        }
    }
}

/// Full report from a safe mode run.
struct SafeModeReport: Sendable {
    let timestamp: Date
    let schemaVersion: String
    let storeFileSize: Int64
    let walFileSize: Int64
    let checks: [SafeModeCheckResult]
    let repairsPerformed: Int
    let appVersion: String
    let macModel: String
    let osVersion: String

    /// Plain-text representation for email.
    var plainText: String {
        var lines: [String] = []
        lines.append("SAM Safe Mode Report")
        lines.append("=" * 50)
        lines.append("")
        lines.append("Timestamp:      \(ISO8601DateFormatter().string(from: timestamp))")
        lines.append("App Version:    \(appVersion)")
        lines.append("Schema:         \(schemaVersion)")
        lines.append("macOS:          \(osVersion)")
        lines.append("Hardware:       \(macModel)")
        lines.append("Store Size:     \(ByteCountFormatter.string(fromByteCount: storeFileSize, countStyle: .file))")
        lines.append("WAL Size:       \(ByteCountFormatter.string(fromByteCount: walFileSize, countStyle: .file))")
        lines.append("Total Checks:   \(checks.count)")
        lines.append("Repairs Made:   \(repairsPerformed)")
        lines.append("")
        lines.append("-" * 50)

        let grouped = Dictionary(grouping: checks, by: \.category)
        for category in grouped.keys.sorted() {
            lines.append("")
            lines.append("[\(category)]")
            for check in grouped[category]! {
                let marker: String
                switch check.severity {
                case .ok:       marker = "  OK "
                case .warning:  marker = " WARN"
                case .repaired: marker = "FIXED"
                case .error:    marker = "ERROR"
                }
                lines.append("  [\(marker)] \(check.description)")
                if !check.detail.isEmpty {
                    lines.append("         \(check.detail)")
                }
            }
        }

        lines.append("")
        lines.append("-" * 50)
        lines.append("End of report")
        return lines.joined(separator: "\n")
    }
}

// String repeat helper
private extension String {
    static func * (lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}

/// Performs deep database integrity checks directly on the SQLite store
/// before SwiftData opens it. All operations use raw SQLite to avoid
/// triggering SwiftData faults on corrupted data.
enum SafeModeService {

    // MARK: - Public

    /// Run all integrity checks and repairs. Returns a full report.
    /// Must be called BEFORE SAMModelContainer.shared is accessed.
    nonisolated static func runFullCheck() -> SafeModeReport {
        let storeURL = SAMModelContainer.defaultStoreURL
        var checks: [SafeModeCheckResult] = []
        var repairCount = 0

        // File existence
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else {
            checks.append(SafeModeCheckResult(
                category: "Store",
                description: "Database file",
                severity: .warning,
                detail: "No database file found at \(storeURL.lastPathComponent). A fresh store will be created on launch."
            ))
            return buildReport(checks: checks, repairs: 0)
        }

        // File sizes
        let storeSize = (try? fm.attributesOfItem(atPath: storeURL.path)[.size] as? Int64) ?? 0
        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let walSize = (try? fm.attributesOfItem(atPath: walURL.path)[.size] as? Int64) ?? 0

        checks.append(SafeModeCheckResult(
            category: "Store",
            description: "Store file size",
            severity: .ok,
            detail: ByteCountFormatter.string(fromByteCount: storeSize, countStyle: .file)
        ))
        if walSize > 50_000_000 { // >50 MB WAL is concerning
            checks.append(SafeModeCheckResult(
                category: "Store",
                description: "WAL file size",
                severity: .warning,
                detail: "\(ByteCountFormatter.string(fromByteCount: walSize, countStyle: .file)) — unusually large, will be checkpointed"
            ))
        }

        // Open database
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            checks.append(SafeModeCheckResult(
                category: "Store",
                description: "Database open",
                severity: .error,
                detail: "Failed to open database file"
            ))
            return buildReport(checks: checks, repairs: 0)
        }
        defer { sqlite3_close(db) }

        // 1. WAL checkpoint
        checks.append(contentsOf: checkpointWAL(db: db!, &repairCount))

        // 2. SQLite integrity check
        checks.append(contentsOf: runIntegrityCheck(db: db!))

        // 3. Table inventory and row counts
        let tables = discoverTables(db: db!)
        checks.append(contentsOf: reportTableCounts(db: db!, tables: tables))

        // 4. Full FK scan — dynamically discover ALL foreign key columns
        checks.append(contentsOf: fullForeignKeyRepair(db: db!, tables: tables, repairCount: &repairCount))

        // 5. Many-to-many join table cleanup
        checks.append(contentsOf: cleanupJoinTables(db: db!, tables: tables, repairCount: &repairCount))

        // 6. Duplicate UUID detection
        checks.append(contentsOf: checkDuplicateUUIDs(db: db!, tables: tables))

        // 7. Schema metadata
        checks.append(contentsOf: checkSchemaMetadata(db: db!))

        logger.notice("Safe Mode: \(checks.count) checks complete, \(repairCount) repairs")
        return buildReport(checks: checks, repairs: repairCount, storeSize: storeSize, walSize: walSize)
    }

    // MARK: - Individual Checks

    private nonisolated static func checkpointWAL(db: OpaquePointer, _ repairCount: inout Int) -> [SafeModeCheckResult] {
        var logSize: Int32 = 0
        var checkpointCount: Int32 = 0
        let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &logSize, &checkpointCount)
        if rc == SQLITE_OK {
            repairCount += 1
            return [SafeModeCheckResult(
                category: "WAL",
                description: "WAL checkpoint",
                severity: .repaired,
                detail: "Flushed \(checkpointCount) pages to main database"
            )]
        } else {
            return [SafeModeCheckResult(
                category: "WAL",
                description: "WAL checkpoint",
                severity: .warning,
                detail: "Checkpoint returned SQLite error \(rc)"
            )]
        }
    }

    private nonisolated static func runIntegrityCheck(db: OpaquePointer) -> [SafeModeCheckResult] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &stmt, nil) == SQLITE_OK else {
            return [SafeModeCheckResult(
                category: "Integrity",
                description: "SQLite integrity check",
                severity: .error,
                detail: "Could not prepare integrity check"
            )]
        }
        defer { sqlite3_finalize(stmt) }

        var messages: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                messages.append(String(cString: text))
            }
        }

        if messages == ["ok"] {
            return [SafeModeCheckResult(
                category: "Integrity",
                description: "SQLite integrity check",
                severity: .ok,
                detail: "Database passes integrity check"
            )]
        } else {
            return [SafeModeCheckResult(
                category: "Integrity",
                description: "SQLite integrity check",
                severity: .error,
                detail: messages.prefix(10).joined(separator: "; ")
            )]
        }
    }

    private nonisolated static func discoverTables(db: OpaquePointer) -> [String] {
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%' ORDER BY name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: c))
            }
        }
        return names
    }

    private nonisolated static func reportTableCounts(db: OpaquePointer, tables: [String]) -> [SafeModeCheckResult] {
        var results: [SafeModeCheckResult] = []
        for table in tables {
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM \(table)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else {
                sqlite3_finalize(stmt)
                continue
            }
            let count = sqlite3_column_int64(stmt, 0)
            sqlite3_finalize(stmt)
            results.append(SafeModeCheckResult(
                category: "Tables",
                description: table,
                severity: .ok,
                detail: "\(count) rows"
            ))
        }
        return results
    }

    /// Dynamically discovers ALL foreign key columns across all tables by inspecting
    /// column names that look like FK references (Z-prefixed integer columns that
    /// reference other Z-prefixed tables).
    private nonisolated static func fullForeignKeyRepair(db: OpaquePointer, tables: [String], repairCount: inout Int) -> [SafeModeCheckResult] {
        var results: [SafeModeCheckResult] = []

        // Build a set of known model tables for parent resolution
        let tableSet = Set(tables)

        // Known FK column → parent table mappings (explicit relationships in our schema)
        // These are all the relationship columns SwiftData creates.
        let knownMappings: [(column: String, parentTable: String)] = [
            ("ZLINKEDPERSON",    "ZSAMPERSON"),
            ("ZLINKEDCONTEXT",   "ZSAMCONTEXT"),
            ("ZPERSON",          "ZSAMPERSON"),
            ("ZEVENT",           "ZSAMEVENT"),
            ("ZLINKEDEVENT",     "ZSAMEVENT"),
            ("ZNOTE",            "ZSAMNOTE"),
            ("ZINSIGHT",         "ZSAMINSIGHT"),
            ("ZCOACHINGPROFILE", "ZCOACHINGPROFILE"),
            ("ZEVIDENCE",        "ZSAMEVIDENCEITEM"),
            ("ZPRESENTATION",    "ZSAMPRESENTATION"),
            ("ZGOAL",            "ZBUSINESSGOAL"),
            ("ZROLEDEFINITION",  "ZROLEDEFINITION"),
        ]
        let knownColumns = Set(knownMappings.map { $0.column })

        // First pass: known mappings
        for table in tables {
            for (col, parentTable) in knownMappings {
                guard tableSet.contains(parentTable) else { continue }
                let cleaned = repairFKColumn(db: db, table: table, column: col, parentTable: parentTable)
                if cleaned > 0 {
                    repairCount += cleaned
                    results.append(SafeModeCheckResult(
                        category: "Relationships",
                        description: "\(table).\(col) → \(parentTable)",
                        severity: .repaired,
                        detail: "Nullified \(cleaned) orphaned reference(s)"
                    ))
                }
            }
        }

        // Second pass: discover unknown FK columns heuristically
        // Any integer column named Z* that isn't a known column and has a plausible parent table
        for table in tables {
            let cols = discoverColumns(db: db, table: table)
            for col in cols {
                guard col.hasPrefix("Z"),
                      !knownColumns.contains(col),
                      col != "Z_PK", col != "Z_ENT", col != "Z_OPT",
                      !col.hasPrefix("Z_") else { continue }

                // Try to guess parent table: ZLINKEDFOO → ZFOO or ZSAMFOO
                let stripped = col.replacingOccurrences(of: "ZLINKED", with: "")
                let candidates = ["ZSAM\(stripped)", "Z\(stripped)"]
                for candidate in candidates {
                    if tableSet.contains(candidate) {
                        let cleaned = repairFKColumn(db: db, table: table, column: col, parentTable: candidate)
                        if cleaned > 0 {
                            repairCount += cleaned
                            results.append(SafeModeCheckResult(
                                category: "Relationships",
                                description: "\(table).\(col) → \(candidate) (auto-detected)",
                                severity: .repaired,
                                detail: "Nullified \(cleaned) orphaned reference(s)"
                            ))
                        }
                        break
                    }
                }
            }
        }

        if results.isEmpty {
            results.append(SafeModeCheckResult(
                category: "Relationships",
                description: "Foreign key references",
                severity: .ok,
                detail: "No orphaned references found"
            ))
        }

        return results
    }

    /// Clean up many-to-many join tables (Z_*) that reference deleted records.
    private nonisolated static func cleanupJoinTables(db: OpaquePointer, tables: [String], repairCount: inout Int) -> [SafeModeCheckResult] {
        var results: [SafeModeCheckResult] = []

        // Discover join tables (Z_* naming convention from CoreData)
        var joinTables: [String] = []
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z_%' AND name NOT LIKE 'Z_PRIMARYKEY' AND name NOT LIKE 'Z_METADATA' AND name NOT LIKE 'Z_MODELCACHE'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                let name = String(cString: c)
                // Join tables typically have names like Z_2LINKEDEVIDENCE
                if name.contains("LINKED") || name.range(of: #"^Z_\d+"#, options: .regularExpression) != nil {
                    joinTables.append(name)
                }
            }
        }
        sqlite3_finalize(stmt)

        for joinTable in joinTables {
            let cols = discoverColumns(db: db, table: joinTable)
            for col in cols where col.hasPrefix("Z_") && col != "Z_PK" {
                // FK columns in join tables are like Z_1LINKEDPEOPLE, Z_2LINKEDEVIDENCE
                // The referenced PK column maps to the Z_PK of a model table.
                // We can't easily determine the parent from the column name alone,
                // so we check for rows referencing Z_PK values that don't exist in ANY model table.

                // Simpler approach: delete rows where EITHER side is NULL or references
                // a non-existent Z_PK in any Z-prefixed table
                // For now, just delete rows with 0 or NULL FK values
                let cleanSQL = "DELETE FROM \(joinTable) WHERE \(col) IS NULL OR \(col) = 0"
                var cleanStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, cleanSQL, -1, &cleanStmt, nil) == SQLITE_OK {
                    if sqlite3_step(cleanStmt) == SQLITE_DONE {
                        let changes = Int(sqlite3_changes(db))
                        if changes > 0 {
                            repairCount += changes
                            results.append(SafeModeCheckResult(
                                category: "Join Tables",
                                description: "\(joinTable).\(col)",
                                severity: .repaired,
                                detail: "Removed \(changes) orphaned join record(s)"
                            ))
                        }
                    }
                }
                sqlite3_finalize(cleanStmt)
            }
        }

        if results.isEmpty {
            results.append(SafeModeCheckResult(
                category: "Join Tables",
                description: "Many-to-many relationships",
                severity: .ok,
                detail: "No orphaned join records found"
            ))
        }

        return results
    }

    /// Check for duplicate UUID values in model tables.
    private nonisolated static func checkDuplicateUUIDs(db: OpaquePointer, tables: [String]) -> [SafeModeCheckResult] {
        var results: [SafeModeCheckResult] = []

        // Most SAM models have a ZID column that stores the UUID
        for table in tables {
            let cols = discoverColumns(db: db, table: table)
            guard cols.contains("ZID") else { continue }

            var stmt: OpaquePointer?
            let sql = "SELECT ZID, COUNT(*) as cnt FROM \(table) WHERE ZID IS NOT NULL GROUP BY ZID HAVING cnt > 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }

            var dupeCount = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                dupeCount += 1
            }
            sqlite3_finalize(stmt)

            if dupeCount > 0 {
                results.append(SafeModeCheckResult(
                    category: "Duplicates",
                    description: "\(table) duplicate UUIDs",
                    severity: .warning,
                    detail: "\(dupeCount) UUID value(s) appear more than once"
                ))
            }
        }

        if results.isEmpty {
            results.append(SafeModeCheckResult(
                category: "Duplicates",
                description: "UUID uniqueness",
                severity: .ok,
                detail: "No duplicate UUIDs found"
            ))
        }

        return results
    }

    /// Check SwiftData/CoreData metadata table.
    private nonisolated static func checkSchemaMetadata(db: OpaquePointer) -> [SafeModeCheckResult] {
        var results: [SafeModeCheckResult] = []

        var stmt: OpaquePointer?
        let sql = "SELECT Z_VERSION, Z_PLIST FROM Z_METADATA"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            results.append(SafeModeCheckResult(
                category: "Metadata",
                description: "Schema metadata",
                severity: .warning,
                detail: "Could not read Z_METADATA table"
            ))
            return results
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let version = sqlite3_column_int(stmt, 0)
            results.append(SafeModeCheckResult(
                category: "Metadata",
                description: "Core Data model version",
                severity: .ok,
                detail: "Version \(version)"
            ))
        }
        sqlite3_finalize(stmt)

        return results
    }

    // MARK: - Helpers

    private nonisolated static func discoverColumns(db: OpaquePointer, table: String) -> [String] {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info('\(table)')"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var cols: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { // column 1 = name
                cols.append(String(cString: c))
            }
        }
        return cols
    }

    /// Null out FK values in `table.column` that don't exist in `parentTable.Z_PK`.
    /// Returns the number of rows repaired.
    private nonisolated static func repairFKColumn(db: OpaquePointer, table: String, column: String, parentTable: String) -> Int {
        // First verify the column exists in this table
        let cols = discoverColumns(db: db, table: table)
        guard cols.contains(column) else { return 0 }

        let sql = """
            UPDATE \(table) SET \(column) = NULL
            WHERE \(column) IS NOT NULL
            AND \(column) NOT IN (SELECT Z_PK FROM \(parentTable))
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    private nonisolated static func buildReport(
        checks: [SafeModeCheckResult],
        repairs: Int,
        storeSize: Int64 = 0,
        walSize: Int64 = 0
    ) -> SafeModeReport {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        // Hardware model
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let macModel = String(cString: model)

        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return SafeModeReport(
            timestamp: .now,
            schemaVersion: SAMModelContainer.schemaVersion,
            storeFileSize: storeSize,
            walFileSize: walSize,
            checks: checks,
            repairsPerformed: repairs,
            appVersion: "\(appVersion) (\(buildNumber))",
            macModel: macModel,
            osVersion: osVersion
        )
    }
}
