//
//  StageCache.swift
//  SAM
//
//  DEBUG-only content-hash cache for pipeline stages.
//
//  The transcription pipeline is a DAG: audio → Whisper → diarization →
//  polish → summary. Each stage's output depends ONLY on its inputs +
//  algorithm version. So if I edit the polish prompt and rerun a test,
//  Whisper and diarization should NOT re-execute — their inputs haven't
//  changed.
//
//  This cache stores each stage's output as JSON, keyed by SHA256 of the
//  inputs. Cached entries persist across SAM launches.
//
//  Cache invalidation: each stage carries a `cacheVersion` constant. Bump
//  the version manually when changing the algorithm in a way that should
//  invalidate prior outputs.
//
//  Disabled in Release builds entirely.
//

#if DEBUG

import Foundation
import CryptoKit
import os.log

private let cacheLogger = Logger(subsystem: "com.matthewsessions.SAM", category: "StageCache")

/// File-backed cache for pipeline stage outputs.
struct StageCache {

    /// Whether the cache is enabled. Off by default — flipped on by the
    /// test harness via `enabled = true` so production code paths are
    /// never affected unless we explicitly opt in.
    static var enabled: Bool = false

    /// Bumped per-stage to invalidate prior cache entries when an
    /// algorithm changes. The TestInboxWatcher uses these in cache keys.
    enum Version {
        static let whisper = "1"
        static let diarization = "1"
        // Bumped to 2: polish cache key no longer includes known nouns (they
        // were the dominant cost on cache hits, see PendingReprocessService).
        static let polish = "2"
        static let summary = "1"
    }

    let root: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = appSupport.appendingPathComponent("SAM-StageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Read / Write

    func get<T: Decodable>(stage: String, key: String, as type: T.Type) -> T? {
        guard Self.enabled else { return nil }
        let url = cacheURL(stage: stage, key: key)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            cacheLogger.notice("💾 CACHE HIT [\(stage)] key=\(key.prefix(12))…")
            return decoded
        } catch {
            cacheLogger.warning("Cache decode failed for [\(stage)] key=\(key.prefix(12))…: \(error.localizedDescription)")
            return nil
        }
    }

    func put<T: Encodable>(stage: String, key: String, value: T) {
        guard Self.enabled else { return }
        let url = cacheURL(stage: stage, key: key)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else {
            cacheLogger.warning("Cache encode failed for [\(stage)] key=\(key.prefix(12))…")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            cacheLogger.notice("💾 CACHE STORE [\(stage)] key=\(key.prefix(12))… (\(data.count) bytes)")
        } catch {
            cacheLogger.warning("Cache write failed: \(error.localizedDescription)")
        }
    }

    /// Wipe a single stage's cache (e.g., after bumping its version).
    func clearStage(_ stage: String) {
        let dir = root.appendingPathComponent(stage, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Wipe everything.
    func clearAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Path

    private func cacheURL(stage: String, key: String) -> URL {
        let stageDir = root.appendingPathComponent(stage, isDirectory: true)
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        return stageDir.appendingPathComponent("\(key).json")
    }

    // MARK: - Hashing helpers

    /// SHA256 hex of arbitrary string input.
    static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hex of file content. Returns nil if file unreadable.
    static func sha256(file url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hex of an Encodable value (sorted keys for stability).
    static func sha256<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Combine multiple components into one cache key.
    static func compositeKey(_ parts: String...) -> String {
        let joined = parts.joined(separator: "|")
        return sha256(joined)
    }
}

#endif
