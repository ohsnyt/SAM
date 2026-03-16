//
//  iMessageService.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Actor-isolated service that reads ~/Library/Messages/chat.db via SQLite3
//  and returns Sendable DTOs. Requires security-scoped bookmark access.
//

import Foundation
import os.log
import SQLite3

actor iMessageService {

    static let shared = iMessageService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "iMessageService")

    private init() {}

    // MARK: - Public API

    /// Fetch messages since a given date, filtered to known identifiers only.
    /// `knownIdentifiers` contains both canonicalized phone numbers (10-digit) and lowercased emails.
    func fetchMessages(since: Date, dbURL: URL, knownIdentifiers: Set<String>) async throws -> (known: [MessageDTO], unknown: [MessageDTO]) {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let sinceTimestamp = dateToiMessageTimestamp(since)

        // Check which spam/junk columns exist (availability varies by macOS version)
        let hasSpam = columnExists(db: db, table: "message", column: "is_spam")
        let hasJunk = columnExists(db: db, table: "message", column: "is_junk")

        var spamClauses: [String] = []
        if hasSpam { spamClauses.append("COALESCE(m.is_spam, 0) = 0") }
        if hasJunk { spamClauses.append("COALESCE(m.is_junk, 0) = 0") }
        let spamFilter = spamClauses.isEmpty ? "" : "AND " + spamClauses.joined(separator: " AND ")

        let query = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                h.id,
                c.guid,
                m.service,
                m.cache_has_attachments,
                m.attributedBody
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.date > ?1 \(spamFilter)
            ORDER BY m.date ASC
            """

        if hasSpam || hasJunk {
            logger.debug("Spam/junk filtering enabled (is_spam: \(hasSpam), is_junk: \(hasJunk))")
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw iMessageError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, sinceTimestamp)

        var messages: [MessageDTO] = []
        var unknownMessages: [MessageDTO] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(stmt, 0)
            let guid = columnText(stmt, 1) ?? "unknown-\(rowID)"
            let text = columnText(stmt, 2)
            let dateVal = sqlite3_column_int64(stmt, 3)
            let isFromMe = sqlite3_column_int(stmt, 4) == 1
            let handleID = columnText(stmt, 5) ?? ""
            let chatGUID = columnText(stmt, 6) ?? ""
            let service = columnText(stmt, 7) ?? "iMessage"
            let hasAttachment = sqlite3_column_int(stmt, 8) == 1

            // Extract text from attributedBody if text column is nil
            var finalText = text
            if finalText == nil {
                finalText = extractAttributedBodyText(stmt, column: 9)
            }

            let canonicalHandle = canonicalizeHandle(handleID)
            let messageDate = iMessageTimestampToDate(dateVal)

            let dto = MessageDTO(
                id: rowID,
                guid: guid,
                text: finalText,
                date: messageDate,
                isFromMe: isFromMe,
                handleID: handleID,
                chatGUID: chatGUID,
                serviceName: service,
                hasAttachment: hasAttachment
            )

            if knownIdentifiers.contains(canonicalHandle) {
                messages.append(dto)
            } else if !isFromMe, let txt = finalText, !txt.isEmpty {
                // Capture incoming messages from unknown senders (for event RSVP detection)
                unknownMessages.append(dto)
            }
        }

        logger.debug("Fetched \(messages.count) messages from known senders, \(unknownMessages.count) from unknown senders since \(since, privacy: .public)")
        return (known: messages, unknown: unknownMessages)
    }

    /// Fetch all unique handles with message counts (for future unknown sender discovery).
    func fetchAllHandles(dbURL: URL) async throws -> [(handleID: String, messageCount: Int)] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let query = """
            SELECT h.id, COUNT(m.ROWID) as msg_count
            FROM handle h
            JOIN message m ON m.handle_id = h.ROWID
            GROUP BY h.id
            ORDER BY msg_count DESC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw iMessageError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        var handles: [(handleID: String, messageCount: Int)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let handleID = columnText(stmt, 0) ?? ""
            let count = Int(sqlite3_column_int(stmt, 1))
            handles.append((handleID: handleID, messageCount: count))
        }

        logger.debug("Found \(handles.count) unique message handles")
        return handles
    }

    /// Fetch handles whose messages are all flagged as junk or spam.
    /// Returns handle IDs (phone numbers or emails) suitable for auto-tagging as never-include.
    func fetchJunkSenderHandles(dbURL: URL) async throws -> [String] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let hasSpam = columnExists(db: db, table: "message", column: "is_spam")
        let hasJunk = columnExists(db: db, table: "message", column: "is_junk")
        guard hasSpam || hasJunk else { return [] }

        // Build junk detection expression from available columns
        var junkCases: [String] = []
        if hasSpam { junkCases.append("COALESCE(m.is_spam, 0) = 1") }
        if hasJunk { junkCases.append("COALESCE(m.is_junk, 0) = 1") }
        let junkExpr = junkCases.joined(separator: " OR ")

        // Find handles where every message is junk/spam (no legitimate messages)
        let query = """
            SELECT h.id
            FROM handle h
            JOIN message m ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 0
            GROUP BY h.id
            HAVING COUNT(*) = SUM(CASE WHEN \(junkExpr) THEN 1 ELSE 0 END)
               AND COUNT(*) > 0
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw iMessageError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        var handles: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let handleID = columnText(stmt, 0) {
                handles.append(handleID)
            }
        }

        if !handles.isEmpty {
            logger.debug("Found \(handles.count) junk/spam-only sender handles")
        }
        return handles
    }

    // MARK: - SQLite3 Helpers

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(url.path, &db, flags, nil)

        guard result == SQLITE_OK, let db else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw iMessageError.databaseOpenFailed(error)
        }

        return db
    }

    private func columnText(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: ptr)
    }

    /// Check if a column exists in a SQLite table (for schema compatibility).
    private func columnExists(db: OpaquePointer, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        let query = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 1), name == column {
                return true
            }
        }
        return false
    }

    /// Extract text from iMessage attributedBody BLOB column.
    /// The blob uses Apple's legacy typedstream format (NSArchiver), NOT NSKeyedArchiver.
    private func extractAttributedBodyText(_ stmt: OpaquePointer?, column: Int32) -> String? {
        guard let blobPtr = sqlite3_column_blob(stmt, column) else { return nil }
        let blobSize = sqlite3_column_bytes(stmt, column)
        guard blobSize > 0 else { return nil }

        let data = Data(bytes: blobPtr, count: Int(blobSize))

        // Primary: use NSUnarchiver (handles typedstream/NSArchiver format).
        // NSKeyedUnarchiver does NOT work — attributedBody is typedstream, not keyed archive.
        // NSUnarchiver is deprecated but is the only Foundation API that decodes typedstream.
        if let text = unarchiveTypedstream(data) {
            return text
        }

        // Fallback: manual binary parsing for typedstream format
        // The text is embedded after an "NSString" marker with a length prefix
        if let text = extractTextFromTypedstream(data) {
            return text
        }

        return nil
    }

    /// Decode typedstream data using NSUnarchiver.
    /// NSUnarchiver is the only Foundation API that decodes the typedstream (NSArchiver) format
    /// used by iMessage attributedBody. NSKeyedUnarchiver does NOT work for this format.
    @available(macOS, deprecated: 10.13, message: "Required for iMessage typedstream decoding — no alternative exists")
    private nonisolated func unarchiveTypedstream(_ data: Data) -> String? {
        guard let attrString = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString else { return nil }
        let text = attrString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Manual fallback parser for typedstream-encoded attributedBody.
    /// Searches for the "NSString" class marker then reads the length-prefixed UTF-8 text.
    private func extractTextFromTypedstream(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = [UInt8]("NSString".utf8)

        // Find "NSString" marker
        guard let markerIndex = bytes.indices.first(where: { idx in
            idx + marker.count <= bytes.count &&
            Array(bytes[idx..<idx+marker.count]) == marker
        }) else { return nil }

        // After "NSString" there are typically 5 bytes of type info, then the length
        let pos = markerIndex + marker.count
        guard pos + 6 < bytes.count else { return nil }

        // Skip type descriptor bytes (varies, but typically ~5 bytes)
        // Look for the length byte(s) — try a few offsets
        for skip in 3...8 {
            let lengthPos = pos + skip
            guard lengthPos < bytes.count else { continue }

            let length: Int
            let textStart: Int

            if bytes[lengthPos] == 0x81, lengthPos + 2 < bytes.count {
                // Two-byte length: 0x81 followed by actual length byte
                length = Int(bytes[lengthPos + 1])
                textStart = lengthPos + 2
            } else {
                // Single-byte length
                length = Int(bytes[lengthPos])
                textStart = lengthPos + 1
            }

            guard length > 0, length < 10000, textStart + length <= bytes.count else { continue }

            let textBytes = Array(bytes[textStart..<textStart+length])
            if let text = String(bytes: textBytes, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Validate: should be mostly printable characters
                let printableRatio = Double(trimmed.unicodeScalars.filter { $0.value >= 32 }.count) / max(1, Double(trimmed.count))
                if !trimmed.isEmpty && printableRatio > 0.8 {
                    return trimmed
                }
            }
        }

        return nil
    }

    // MARK: - Date Conversion

    /// iMessage stores dates as nanoseconds since 2001-01-01 (Core Data epoch).
    /// Clamps to 0 for dates before the reference date (e.g. `.distantPast`)
    /// to avoid Int64 overflow.
    private func dateToiMessageTimestamp(_ date: Date) -> Int64 {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds > 0 else { return 0 }
        return Int64(seconds * 1_000_000_000)
    }

    private func iMessageTimestampToDate(_ timestamp: Int64) -> Date {
        let seconds = Double(timestamp) / 1_000_000_000.0
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: - Handle Canonicalization

    /// Canonicalize a handle ID: phone → last 10 digits; email → lowercased.
    private func canonicalizeHandle(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)

        // If it looks like an email, lowercase it
        if trimmed.contains("@") {
            return trimmed.lowercased()
        }

        // Otherwise treat as phone: strip non-digits, take last 10
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 7 else { return trimmed.lowercased() }
        return String(digits.suffix(10))
    }

    // MARK: - Errors

    enum iMessageError: Error, LocalizedError {
        case databaseOpenFailed(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseOpenFailed(let msg): return "Failed to open messages database: \(msg)"
            case .queryFailed(let msg): return "Messages query failed: \(msg)"
            }
        }
    }
}
