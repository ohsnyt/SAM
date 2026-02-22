//
//  CallHistoryService.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Actor-isolated service that reads ~/Library/Application Support/CallHistoryDB/
//  CallHistory.storedata via SQLite3 and returns Sendable DTOs.
//

import Foundation
import os.log
import SQLite3

actor CallHistoryService {

    static let shared = CallHistoryService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CallHistoryService")

    private init() {}

    // MARK: - Public API

    /// Fetch call records since a given date, filtered to known phone numbers only.
    /// `knownPhones` contains canonicalized phone numbers (last 10 digits).
    func fetchCalls(since: Date, dbURL: URL, knownPhones: Set<String>) async throws -> [CallRecordDTO] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let sinceTimestamp = since.timeIntervalSinceReferenceDate

        let query = """
            SELECT Z_PK, CAST(ZADDRESS AS TEXT), ZDATE, ZDURATION, ZCALLTYPE, ZORIGINATED, ZANSWERED
            FROM ZCALLRECORD
            WHERE ZDATE > ?1
            ORDER BY ZDATE ASC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw CallHistoryError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, sinceTimestamp)

        var records: [CallRecordDTO] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let address = columnText(stmt, 1) ?? ""
            let dateVal = sqlite3_column_double(stmt, 2)
            let duration = sqlite3_column_double(stmt, 3)
            let callTypeRaw = Int(sqlite3_column_int(stmt, 4))
            let originated = sqlite3_column_int(stmt, 5) == 1
            let answered = sqlite3_column_int(stmt, 6) == 1

            // Filter to known phone numbers
            let canonicalAddress = canonicalizePhone(address)
            guard knownPhones.contains(canonicalAddress) else { continue }

            let callDate = Date(timeIntervalSinceReferenceDate: dateVal)
            let callType = mapCallType(callTypeRaw)

            records.append(CallRecordDTO(
                id: pk,
                address: address,
                date: callDate,
                duration: duration,
                callType: callType,
                isOutgoing: originated,
                wasAnswered: answered
            ))
        }

        logger.info("Fetched \(records.count) call records from known contacts since \(since, privacy: .public)")
        return records
    }

    /// Fetch all unique addresses with call counts (for future unknown caller discovery).
    func fetchAllAddresses(dbURL: URL) async throws -> [(address: String, callCount: Int)] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        let query = """
            SELECT CAST(ZADDRESS AS TEXT), COUNT(*) as call_count
            FROM ZCALLRECORD
            WHERE ZADDRESS IS NOT NULL
            GROUP BY ZADDRESS
            ORDER BY call_count DESC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw CallHistoryError.queryFailed(error)
        }
        defer { sqlite3_finalize(stmt) }

        var addresses: [(address: String, callCount: Int)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let address = columnText(stmt, 0) ?? ""
            let count = Int(sqlite3_column_int(stmt, 1))
            addresses.append((address: address, callCount: count))
        }

        logger.info("Found \(addresses.count) unique call addresses")
        return addresses
    }

    // MARK: - SQLite3 Helpers

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(url.path, &db, flags, nil)

        guard result == SQLITE_OK, let db else {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw CallHistoryError.databaseOpenFailed(error)
        }

        return db
    }

    private func columnText(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: ptr)
    }

    // MARK: - Phone Canonicalization

    private func canonicalizePhone(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return raw.lowercased() }
        return String(digits.suffix(10))
    }

    // MARK: - Call Type Mapping

    private func mapCallType(_ raw: Int) -> CallRecordDTO.CallType {
        switch raw {
        case 1: return .phone
        case 8: return .faceTimeVideo
        case 16: return .faceTimeAudio
        default: return .unknown(raw)
        }
    }

    // MARK: - Errors

    enum CallHistoryError: Error, LocalizedError {
        case databaseOpenFailed(String)
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseOpenFailed(let msg): return "Failed to open call history database: \(msg)"
            case .queryFailed(let msg): return "Call history query failed: \(msg)"
            }
        }
    }
}
