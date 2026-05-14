//
//  DraftStore.swift
//  SAM
//
//  Legacy field-map draft cache, used by ~9 edit sheets that pre-date
//  the typed-coordinator draft system. The API is unchanged from the
//  original in-memory implementation — callers pass a `kind` namespace
//  and an `id` (typically a UUID string, sometimes the literal "new")
//  and read/write a flat `[String: String]` of form fields.
//
//  Phase 1 (sheet-tear-down fix) wires this through to
//  `DraftPersistenceService` so the in-memory cache is also persisted
//  to disk. Every legacy caller now survives a crash, force-quit, or
//  power loss without changes. Disk writes are debounced (~1.5s after
//  the last edit) so frequent keystroke-driven saves don't thrash
//  SwiftData; the in-memory layer remains fully synchronous so reads
//  always see the latest write.
//
//  Identity mapping: `DraftPersistenceService` stores by UUID. Legacy
//  ids that are valid UUID strings are used as-is; anything else
//  ("new", arbitrary tokens) is hashed to a stable UUID via SHA-256 so
//  the same id string always resolves to the same row.
//

import CryptoKit
import Foundation
import os.log

@MainActor
@Observable
final class DraftStore {
    static let shared = DraftStore()

    private var drafts: [String: [String: [String: String]]] = [:]
    private var pendingFlushes: [DraftKey: Task<Void, Never>] = [:]
    /// Tracks which (kind,id) pairs we've already hydrated from disk so
    /// repeated `load` calls don't hit SwiftData for misses.
    private var hydrated: Set<DraftKey> = []
    private let flushDelay: Duration = .milliseconds(1_500)
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DraftStore")

    private struct DraftKey: Hashable {
        let kind: String
        let id: String
    }

    private init() {}

    // MARK: - Public API (unchanged surface)

    func save(kind: String, id: String, fields: [String: String]) {
        if drafts[kind] == nil { drafts[kind] = [:] }
        drafts[kind]?[id] = fields
        scheduleDiskFlush(kind: kind, id: id, fields: fields)
    }

    func load(kind: String, id: String) -> [String: String]? {
        let key = DraftKey(kind: kind, id: id)
        if let mem = drafts[kind]?[id] {
            hydrated.insert(key)
            return mem
        }
        // Not in memory yet — hydrate from disk on first miss so a draft
        // written in a previous run is visible to a re-opened sheet.
        if !hydrated.contains(key) {
            hydrated.insert(key)
            let subjectID = Self.deriveUUID(from: id)
            if let fromDisk = DraftPersistenceService.shared.loadLegacy(legacyKind: kind, subjectID: subjectID) {
                if drafts[kind] == nil { drafts[kind] = [:] }
                drafts[kind]?[id] = fromDisk
                return fromDisk
            }
        }
        return nil
    }

    func clear(kind: String, id: String) {
        drafts[kind]?[id] = nil
        if drafts[kind]?.isEmpty == true {
            drafts[kind] = nil
        }
        let key = DraftKey(kind: kind, id: id)
        hydrated.insert(key)
        pendingFlushes[key]?.cancel()
        pendingFlushes[key] = nil
        let subjectID = Self.deriveUUID(from: id)
        DraftPersistenceService.shared.deleteLegacy(legacyKind: kind, subjectID: subjectID)
    }

    func clearAll() {
        drafts.removeAll()
        hydrated.removeAll()
        for (_, task) in pendingFlushes { task.cancel() }
        pendingFlushes.removeAll()
        // Note: clearAll() does NOT wipe disk drafts. It is called in
        // narrow contexts (test reset, account swap) where the caller
        // already controls the underlying store; we don't want a
        // memory-cache reset to silently drop on-disk drafts of in-flight
        // user work. Callers that want disk drops use the
        // DraftPersistenceService cleanup APIs directly. `hydrated` is
        // cleared too so a re-opened sheet hits disk again rather than
        // assuming the absence cached from the prior session.
    }

    /// Called by the app on graceful shutdown / scene phase changes to
    /// flush any pending debounced writes immediately. Without this, the
    /// last ~1.5s of typing would only live in memory and be lost on
    /// process exit.
    func flushAllPending() {
        let snapshots = drafts.flatMap { (kind, byID) in
            byID.compactMap { (id, fields) -> (String, String, [String: String])? in
                guard pendingFlushes[DraftKey(kind: kind, id: id)] != nil else { return nil }
                return (kind, id, fields)
            }
        }
        for (kind, id, fields) in snapshots {
            writeToDisk(kind: kind, id: id, fields: fields)
            let key = DraftKey(kind: kind, id: id)
            pendingFlushes[key]?.cancel()
            pendingFlushes[key] = nil
        }
    }

    // MARK: - Internals

    private func scheduleDiskFlush(kind: String, id: String, fields: [String: String]) {
        let key = DraftKey(kind: kind, id: id)
        pendingFlushes[key]?.cancel()
        pendingFlushes[key] = Task { [weak self, flushDelay] in
            try? await Task.sleep(for: flushDelay)
            guard !Task.isCancelled else { return }
            self?.commitPending(key: key, kind: kind, id: id, fields: fields)
        }
    }

    private func commitPending(key: DraftKey, kind: String, id: String, fields: [String: String]) {
        // Re-read the latest in-memory copy in case more edits arrived
        // between schedule and commit; the debounce should have replaced
        // the task, but if multiple writes raced the latest write wins.
        let latest = drafts[kind]?[id] ?? fields
        writeToDisk(kind: kind, id: id, fields: latest)
        pendingFlushes[key] = nil
    }

    private func writeToDisk(kind: String, id: String, fields: [String: String]) {
        let subjectID = Self.deriveUUID(from: id)
        do {
            _ = try DraftPersistenceService.shared.saveLegacy(
                legacyKind: kind,
                subjectID: subjectID,
                fields: fields
            )
        } catch {
            logger.warning("Failed to persist legacy draft kind=\(kind) id=\(id): \(error.localizedDescription)")
        }
    }

    /// Deterministic UUID derivation. For valid UUID strings, parses
    /// directly. For anything else ("new", arbitrary tokens), hashes via
    /// SHA-256 and shapes the first 16 bytes into a valid v5-style UUID.
    /// Stability matters: the same input string must always produce the
    /// same UUID so a save and a later load find the same row.
    static func deriveUUID(from string: String) -> UUID {
        if let parsed = UUID(uuidString: string) { return parsed }
        let digest = SHA256.hash(data: Data(string.utf8))
        var bytes = Array(digest).prefix(16).map { $0 }
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // variant RFC 4122
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
