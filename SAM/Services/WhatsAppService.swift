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
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let sinceTimestamp = since.timeIntervalSinceReferenceDate

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

        while sqlite3_step(stmt) == SQLITE_ROW {
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
            guard knownPhones.contains(phone) else { continue }

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

        logger.debug("Fetched \(messages.count) WhatsApp messages from known contacts since \(since, privacy: .public)")
        return messages
    }

    /// Fetch call events since a given date, filtered to known phone numbers (1:1 calls only).
    /// Returns empty array if the call history table doesn't exist in this WhatsApp version.
    func fetchCalls(since: Date, dbURL: URL, knownPhones: Set<String>) async throws -> [WhatsAppCallDTO] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        // Check if the calls table exists — not all WhatsApp versions have it
        guard tableExists("ZWACDCALLEVENT", in: db) else {
            logger.debug("ZWACDCALLEVENT table not found — WhatsApp call history not available in this version")
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

        logger.debug("Fetched \(calls.count) WhatsApp call events from known contacts since \(since, privacy: .public)")
        return calls
    }

    /// Fetch (stanzaID → JID) pairs for back-filling participant hints on existing
    /// WhatsApp message evidence imported before phone-based hints were stored.
    func fetchJIDsForStanzaIDs(dbURL: URL, stanzaIDs: Set<String>) async throws -> [String: String] {
        guard !stanzaIDs.isEmpty else { return [:] }
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let query = """
            SELECT m.ZSTANZAID, cs.ZCONTACTJID
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION cs ON m.ZCHATSESSION = cs.Z_PK
            WHERE cs.ZSESSIONTYPE = 0 AND m.ZSTANZAID IS NOT NULL
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw WhatsAppError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let stanzaID = columnText(stmt, 0), stanzaIDs.contains(stanzaID) else { continue }
            if let jid = columnText(stmt, 1), !jid.isEmpty {
                result[stanzaID] = jid
            }
        }
        return result
    }

    /// Fetch (callIDString → [JID]) pairs for back-filling participant hints on
    /// existing WhatsApp call evidence.
    func fetchJIDsForCallIDs(dbURL: URL, callIDStrings: Set<String>) async throws -> [String: [String]] {
        guard !callIDStrings.isEmpty else { return [:] }
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        guard tableExists("ZWACDCALLEVENT", in: db) else { return [:] }

        let query = """
            SELECT ce.ZCALLIDSTRING, p.ZJID
            FROM ZWACDCALLEVENT ce
            LEFT JOIN ZWACDCALLEVENTPARTICIPANT p ON p.ZCALLEVENT = ce.Z_PK
            WHERE ce.ZCALLIDSTRING IS NOT NULL
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw WhatsAppError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let callID = columnText(stmt, 0), callIDStrings.contains(callID) else { continue }
            if let jid = columnText(stmt, 1), !jid.isEmpty {
                result[callID, default: []].append(jid)
            }
        }
        return result
    }

    /// Fetch all unique JIDs with message counts (for unknown sender discovery).
    func fetchAllJIDs(dbURL: URL) async throws -> [(jid: String, partnerName: String?, messageCount: Int, latestMessageDate: Date?)] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let query = """
            SELECT cs.ZCONTACTJID, cs.ZPARTNERNAME, COUNT(m.Z_PK) as msg_count, MAX(m.ZMESSAGEDATE) as last_date
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

        var jids: [(jid: String, partnerName: String?, messageCount: Int, latestMessageDate: Date?)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let jid = columnText(stmt, 0) ?? ""
            let partnerName = columnText(stmt, 1)
            let count = Int(sqlite3_column_int(stmt, 2))
            let latestDate: Date?
            if sqlite3_column_type(stmt, 3) == SQLITE_NULL {
                latestDate = nil
            } else {
                let dateVal = sqlite3_column_double(stmt, 3)
                latestDate = Date(timeIntervalSinceReferenceDate: dateVal)
            }
            jids.append((jid: jid, partnerName: partnerName, messageCount: count, latestMessageDate: latestDate))
        }

        logger.debug("Found \(jids.count) unique WhatsApp JIDs")
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
