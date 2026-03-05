//
//  WhatsAppService.swift
//  SAM
//
//  WhatsApp Direct Database Integration
//
//  Actor-isolated service that reads WhatsApp's local ChatStorage.sqlite
//  via SQLite3 and returns Sendable DTOs. Requires security-scoped bookmark
//  access to ~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/.
//

import Foundation
import os.log
import SQLite3

actor WhatsAppService {

    static let shared = WhatsAppService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "WhatsAppService")

    private init() {}

    // MARK: - Public API

    /// Fetch messages since a given date, filtered to known phone numbers only.
    /// `knownPhones` contains canonicalized phone numbers (last 10 digits).
    func fetchMessages(since: Date, dbURL: URL, knownPhones: Set<String>) async throws -> [WhatsAppMessageDTO] {
        logger.info("[DEBUG] fetchMessages: dbURL=\(dbURL.path, privacy: .public), since=\(since, privacy: .public), knownPhones=\(knownPhones.count)")
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }
        logger.info("[DEBUG] Database opened successfully")

        let sinceTimestamp = since.timeIntervalSinceReferenceDate
        logger.info("[DEBUG] sinceTimestamp (timeIntervalSinceReferenceDate)=\(sinceTimestamp)")

        // Count total rows for debugging
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZWAMESSAGE", -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let totalCount = sqlite3_column_int64(countStmt, 0)
                logger.info("[DEBUG] Total ZWAMESSAGE rows in DB: \(totalCount)")
            }
            sqlite3_finalize(countStmt)
        }

        // Count chat sessions
        var sessionStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZWACHATSESSION WHERE ZSESSIONTYPE = 0", -1, &sessionStmt, nil) == SQLITE_OK {
            if sqlite3_step(sessionStmt) == SQLITE_ROW {
                let sessionCount = sqlite3_column_int64(sessionStmt, 0)
                logger.info("[DEBUG] Private chat sessions (ZSESSIONTYPE=0): \(sessionCount)")
            }
            sqlite3_finalize(sessionStmt)
        }

        // Count messages after watermark
        var afterStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZWAMESSAGE WHERE ZMESSAGEDATE > ?1", -1, &afterStmt, nil) == SQLITE_OK {
            sqlite3_bind_double(afterStmt, 1, sinceTimestamp)
            if sqlite3_step(afterStmt) == SQLITE_ROW {
                let afterCount = sqlite3_column_int64(afterStmt, 0)
                logger.info("[DEBUG] Messages with ZMESSAGEDATE > sinceTimestamp: \(afterCount)")
            }
            sqlite3_finalize(afterStmt)
        }

        // Sample a few ZMESSAGEDATE values
        var sampleStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT ZMESSAGEDATE FROM ZWAMESSAGE ORDER BY ZMESSAGEDATE DESC LIMIT 3", -1, &sampleStmt, nil) == SQLITE_OK {
            var samples: [Double] = []
            while sqlite3_step(sampleStmt) == SQLITE_ROW {
                samples.append(sqlite3_column_double(sampleStmt, 0))
            }
            sqlite3_finalize(sampleStmt)
            logger.info("[DEBUG] Latest 3 ZMESSAGEDATE values: \(samples)")
        }

        // Private chats only (ZSESSIONTYPE = 0), join messages with chat sessions
        let query = """
            SELECT
                m.Z_PK,
                m.ZSTANZAID,
                m.ZTEXT,
                m.ZMESSAGEDATE,
                m.ZISFROMME,
                cs.ZCONTACTJID,
                cs.ZPARTNERNAME,
                m.ZMESSAGETYPE,
                m.ZSTARRED
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION cs ON m.ZCHATSESSION = cs.Z_PK
            WHERE cs.ZSESSIONTYPE = 0
              AND m.ZMESSAGEDATE > ?1
            ORDER BY m.ZMESSAGEDATE ASC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw WhatsAppError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, sinceTimestamp)

        var messages: [WhatsAppMessageDTO] = []
        var totalRowsRead = 0
        var filteredOutCount = 0
        var seenJIDs: Set<String> = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            totalRowsRead += 1
            let pk = sqlite3_column_int64(stmt, 0)
            let stanzaID = columnText(stmt, 1) ?? "unknown-\(pk)"
            let text = columnText(stmt, 2)
            let dateVal = sqlite3_column_double(stmt, 3)
            let isFromMe = sqlite3_column_int(stmt, 4) == 1
            let contactJID = columnText(stmt, 5) ?? ""
            let partnerName = columnText(stmt, 6)
            let messageType = Int(sqlite3_column_int(stmt, 7))
            let isStarred = sqlite3_column_int(stmt, 8) == 1

            // Filter to known phone numbers
            let phone = jidToPhone(contactJID)
            if !seenJIDs.contains(contactJID) {
                seenJIDs.insert(contactJID)
                let matched = knownPhones.contains(phone)
                logger.info("[DEBUG] JID \(contactJID, privacy: .public) → phone \(phone, privacy: .public) → matched=\(matched), partnerName=\(partnerName ?? "nil", privacy: .public)")
            }
            guard knownPhones.contains(phone) else {
                filteredOutCount += 1
                continue
            }

            let messageDate = Date(timeIntervalSinceReferenceDate: dateVal)

            messages.append(WhatsAppMessageDTO(
                id: pk,
                stanzaID: stanzaID,
                text: text,
                date: messageDate,
                isFromMe: isFromMe,
                contactJID: contactJID,
                partnerName: partnerName,
                messageType: messageType,
                isStarred: isStarred
            ))
        }

        logger.info("[DEBUG] Query read \(totalRowsRead) rows total, \(filteredOutCount) filtered out (unknown), \(messages.count) matched known contacts, \(seenJIDs.count) unique JIDs seen")
        // Also log a few sample known phones for cross-reference
        let samplePhones = Array(knownPhones.prefix(5))
        logger.info("[DEBUG] Sample knownPhones: \(samplePhones, privacy: .public)")
        logger.info("Fetched \(messages.count) WhatsApp messages from known contacts since \(since, privacy: .public)")
        return messages
    }

    /// Fetch call events since a given date, filtered to known phone numbers (1:1 calls only).
    /// Returns empty array if the call history table doesn't exist in this WhatsApp version.
    func fetchCalls(since: Date, dbURL: URL, knownPhones: Set<String>) async throws -> [WhatsAppCallDTO] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        // Check if the calls table exists — not all WhatsApp versions have it
        guard tableExists("ZWACDCALLEVENT", in: db) else {
            logger.info("[DEBUG] ZWACDCALLEVENT table not found — WhatsApp call history not available in this version")
            return []
        }

        let sinceTimestamp = since.timeIntervalSinceReferenceDate

        // First get call events, then join participants
        let query = """
            SELECT
                ce.Z_PK,
                ce.ZCALLIDSTRING,
                ce.ZDATE,
                ce.ZDURATION,
                ce.ZOUTCOME,
                p.ZJID
            FROM ZWACDCALLEVENT ce
            LEFT JOIN ZWACDCALLEVENTPARTICIPANT p ON p.ZCALLEVENT = ce.Z_PK
            WHERE ce.ZDATE > ?1
            ORDER BY ce.ZDATE ASC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw WhatsAppError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, sinceTimestamp)

        // Group participants by call PK
        var callRows: [Int64: (callIDString: String, date: Double, duration: Double, outcome: Int, jids: [String])] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let callIDString = columnText(stmt, 1) ?? "unknown-\(pk)"
            let dateVal = sqlite3_column_double(stmt, 2)
            let duration = sqlite3_column_double(stmt, 3)
            let outcome = Int(sqlite3_column_int(stmt, 4))
            let participantJID = columnText(stmt, 5)

            if var existing = callRows[pk] {
                if let jid = participantJID {
                    existing.jids.append(jid)
                    callRows[pk] = existing
                }
            } else {
                callRows[pk] = (
                    callIDString: callIDString,
                    date: dateVal,
                    duration: duration,
                    outcome: outcome,
                    jids: participantJID.map { [$0] } ?? []
                )
            }
        }

        // Filter to 1:1 calls with known contacts
        var calls: [WhatsAppCallDTO] = []

        for (pk, row) in callRows {
            // Only 1:1 calls (single participant)
            guard row.jids.count == 1 else { continue }

            let phone = jidToPhone(row.jids[0])
            guard knownPhones.contains(phone) else { continue }

            let callDate = Date(timeIntervalSinceReferenceDate: row.date)

            calls.append(WhatsAppCallDTO(
                id: pk,
                callIDString: row.callIDString,
                date: callDate,
                duration: row.duration,
                outcome: row.outcome,
                participantJIDs: row.jids
            ))
        }

        calls.sort { $0.date < $1.date }

        logger.info("Fetched \(calls.count) WhatsApp call events from known contacts since \(since, privacy: .public)")
        return calls
    }

    /// Fetch all unique JIDs with message counts (for unknown sender discovery).
    func fetchAllJIDs(dbURL: URL) async throws -> [(jid: String, partnerName: String?, messageCount: Int)] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let query = """
            SELECT cs.ZCONTACTJID, cs.ZPARTNERNAME, COUNT(m.Z_PK) as msg_count
            FROM ZWACHATSESSION cs
            JOIN ZWAMESSAGE m ON m.ZCHATSESSION = cs.Z_PK
            WHERE cs.ZSESSIONTYPE = 0
            GROUP BY cs.ZCONTACTJID
            ORDER BY msg_count DESC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw WhatsAppError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        var jids: [(jid: String, partnerName: String?, messageCount: Int)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let jid = columnText(stmt, 0) ?? ""
            let partnerName = columnText(stmt, 1)
            let count = Int(sqlite3_column_int(stmt, 2))
            jids.append((jid: jid, partnerName: partnerName, messageCount: count))
        }

        logger.info("Found \(jids.count) unique WhatsApp JIDs")
        return jids
    }

    // MARK: - SQLite3 Helpers

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(url.path, &db, flags, nil)

        guard result == SQLITE_OK, let db else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw WhatsAppError.databaseOpenFailed(error)
        }

        return db
    }

    /// Check whether a table exists in the database.
    private func tableExists(_ tableName: String, in db: OpaquePointer) -> Bool {
        let query = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (tableName as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    private func columnText(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: ptr)
    }

    // MARK: - JID Helpers

    /// Convert a WhatsApp JID ("14075800106@s.whatsapp.net") to canonicalized phone (last 10 digits).
    private func jidToPhone(_ jid: String) -> String {
        let local = jid.split(separator: "@").first.map(String.init) ?? jid
        let digits = local.filter(\.isNumber)
        guard digits.count >= 7 else { return jid.lowercased() }
        return String(digits.suffix(10))
    }

    // MARK: - Errors

    enum WhatsAppError: Error, LocalizedError {
        case databaseOpenFailed(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseOpenFailed(let msg): return "Failed to open WhatsApp database: \(msg)"
            case .queryFailed(let msg): return "WhatsApp query failed: \(msg)"
            }
        }
    }
}
