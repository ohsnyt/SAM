//
//  RetentionService.swift
//  SAM
//
//  Periodic cleanup of meeting recording artifacts that have outlived
//  their usefulness. Sarah needs the audio for a few weeks after a
//  meeting to re-listen if a client follows up; after that the disk
//  space, the privacy exposure, and the backup bloat all start working
//  against her.
//
//  This service implements the audio-purge half of the retention
//  story:
//    - Find sessions that have been signed-off for longer than the
//      configured grace window
//    - Skip any session with `pinAudioRetention == true`
//    - Delete the WAV file from disk
//    - Mark `audioPurgedAt = .now` and clear `audioFilePath`
//    - Leave the polished text, summary, and linked note intact
//
//  Session-level deletion (purging the segments + summary + note) is
//  intentionally NOT done here. The user can delete a session manually
//  from the review view, but SAM never deletes coaching context
//  automatically — the polished text and summary are too valuable to
//  vanish on a timer.
//
//  Runs once on app launch (background task at .utility) and on a daily
//  schedule while the app is running. The cost is small (a few SwiftData
//  fetches and at most a handful of file deletes per day for an active
//  user) so we don't bother with batching.
//

import Foundation
import SwiftData
import os.log

@MainActor
@Observable
final class RetentionService {

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RetentionService")

    static let shared = RetentionService()

    private init() {}

    // MARK: - Settings (UserDefaults-backed)

    @ObservationIgnored private let audioRetentionDaysKey = "sam.retention.audioRetentionDays"

    /// How many days after sign-off SAM keeps the audio file before
    /// purging it. Default 30 days. Set to 0 to disable auto-purge.
    var audioRetentionDays: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: audioRetentionDaysKey)
            return val > 0 ? val : 30
        }
        set {
            UserDefaults.standard.set(newValue, forKey: audioRetentionDaysKey)
            logger.info("audioRetentionDays updated to \(newValue)")
        }
    }

    // MARK: - State

    private(set) var lastRunAt: Date?
    private(set) var lastRunPurgedCount: Int = 0
    private(set) var lastRunBytesFreed: Int64 = 0

    // MARK: - Public API

    /// Run a single retention pass against the database. Safe to call
    /// repeatedly; idempotent for already-purged sessions.
    @discardableResult
    func runOnce(container: ModelContainer) async -> (purgedCount: Int, bytesFreed: Int64) {
        let retentionDays = audioRetentionDays
        guard retentionDays > 0 else {
            logger.info("Retention disabled (days=0); skipping pass")
            return (0, 0)
        }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        logger.notice("🗑️ Retention pass starting — purge audio signed off before \(cutoff.formatted(date: .abbreviated, time: .shortened))")

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { session in
                session.signedOffAt != nil
                && session.audioPurgedAt == nil
                && session.audioFilePath != nil
                && session.pinAudioRetention == false
            }
        )

        let candidates: [TranscriptSession]
        do {
            candidates = try context.fetch(descriptor)
        } catch {
            logger.error("Retention pass fetch failed: \(error.localizedDescription)")
            return (0, 0)
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var purgedCount = 0
        var bytesFreed: Int64 = 0

        for session in candidates {
            // Skip sessions that aren't past the grace window yet.
            guard let signedOffAt = session.signedOffAt, signedOffAt < cutoff else {
                continue
            }
            guard let path = session.audioFilePath else { continue }

            // Compliance gate: if a post-meeting capture for the same
            // meeting is still in flight, defer purge. The user hasn't
            // confirmed the derived outputs for that meeting yet, so
            // destroying the source material under her would violate
            // the retention rule that drives this service. The draft's
            // own 7-day TTL ensures audio still gets purged eventually
            // even if Sarah never finishes the capture.
            if let evidenceID = await evidenceIDForSession(session, context: context),
               await MainActor.run(body: {
                   DraftPersistenceService.shared.hasUnfinishedDraft(
                       kind: .postMeetingCapture,
                       subjectID: evidenceID
                   )
               }) {
                logger.info("Retention deferring audio purge for session \(session.id.uuidString) — unfinished post-meeting capture for evidence \(evidenceID)")
                continue
            }

            let url = appSupport.appendingPathComponent(path)
            let size: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                session.audioPurgedAt = .now
                session.audioFilePath = nil
                purgedCount += 1
                bytesFreed += size
                logger.info("Retention purged audio for session \(session.id.uuidString) (\(size) bytes, signed off \(signedOffAt.formatted(date: .abbreviated, time: .omitted)))")
            } catch {
                logger.warning("Retention failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if purgedCount > 0 {
            do {
                try context.save()
            } catch {
                logger.error("Retention pass save failed: \(error.localizedDescription)")
            }
        }

        lastRunAt = .now
        lastRunPurgedCount = purgedCount
        lastRunBytesFreed = bytesFreed

        logger.notice("🗑️ Retention pass complete — purged \(purgedCount) audio file(s), freed \(bytesFreed) bytes")
        return (purgedCount, bytesFreed)
    }

    /// Resolves the `SamEvidenceItem.id` for a TranscriptSession, when
    /// the session was recorded against a calendar event. Returns nil
    /// for ad-hoc sessions with no calendar linkage. Used by the
    /// retention gate to find unfinished post-meeting captures keyed
    /// by the same evidence.
    private func evidenceIDForSession(
        _ session: TranscriptSession,
        context: ModelContext
    ) async -> UUID? {
        guard let calendarEventID = session.calendarEventID,
              !calendarEventID.isEmpty else { return nil }
        let sourceUID = "eventkit:\(calendarEventID)"
        let descriptor = FetchDescriptor<SamEvidenceItem>(
            predicate: #Predicate { $0.sourceUID == sourceUID }
        )
        return (try? context.fetch(descriptor).first)?.id
    }

    /// Sign off on a session. Sets `signedOffAt` and saves. The audio
    /// purge timer starts counting from this moment. Idempotent — calling
    /// twice on a signed-off session is a no-op.
    @discardableResult
    func signOff(session: TranscriptSession, container: ModelContainer) -> Bool {
        guard session.signedOffAt == nil else {
            logger.debug("signOff: session \(session.id.uuidString) already signed off, skipping")
            return false
        }

        let context = ModelContext(container)
        let sessionID = session.id
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        do {
            guard let fresh = try context.fetch(descriptor).first else { return false }
            fresh.signedOffAt = .now
            try context.save()
            logger.notice("✍️ Signed off session \(sessionID.uuidString)")
            return true
        } catch {
            logger.error("signOff failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Toggle whether a session's audio is pinned (kept indefinitely).
    @discardableResult
    func setAudioPin(session: TranscriptSession, pinned: Bool, container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        let sessionID = session.id
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        do {
            guard let fresh = try context.fetch(descriptor).first else { return false }
            fresh.pinAudioRetention = pinned
            try context.save()
            logger.info("📌 Audio pin for session \(sessionID.uuidString) set to \(pinned)")
            return true
        } catch {
            logger.error("setAudioPin failed: \(error.localizedDescription)")
            return false
        }
    }
}
