//
//  PendingUploadService.swift
//  SAM Field
//
//  Phase B: iPhone-side queue that manages recordings captured offline
//  (or degraded from streaming) and uploads them to the Mac when both
//  devices are reachable and the iPhone isn't actively recording.
//
//  Responsibilities:
//    1. Enqueue a PendingUpload record when a session finishes in
//       localOnly or degradedToLocal mode
//    2. On Mac-reachable + idle, pick the oldest pending item and drive
//       the upload protocol (uploadStart → uploadChunk* → uploadEnd)
//    3. Wait for sessionProcessed ack, delete the local WAV, mark row
//       processed
//    4. On launch, scan Documents/MeetingRecordings/ for orphaned WAV
//       files (crashes, force-quits) and adopt them as pending uploads
//       so nothing gets lost
//

import Foundation
import SwiftData
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "PendingUploadService")

@MainActor
@Observable
final class PendingUploadService {

    static let shared = PendingUploadService()

    private init() {}

    // MARK: - State

    enum UploadState: Sendable, Equatable {
        case idle
        case sendingStart(UUID)
        case sendingChunks(UUID, bytesSent: Int64, totalBytes: Int64)
        case sendingEnd(UUID)
        case awaitingAck(UUID)
        case failed(UUID, reason: String)
    }

    private(set) var uploadState: UploadState = .idle

    /// Number of pending items visible in the UI — updated whenever the
    /// queue is scanned.
    private(set) var pendingCount: Int = 0

    // MARK: - Dependencies

    private var modelContainer: ModelContainer?
    private var streamingService: AudioStreamingService?

    /// The session ID we're currently uploading — used by the ack handler
    /// to match an incoming `sessionProcessed` to the right pending row.
    private var currentUploadSessionID: UUID?

    /// Continuation used to await the sessionProcessed ack.
    private var ackContinuation: CheckedContinuation<SessionProcessedAck, Never>?

    func configure(container: ModelContainer, streaming: AudioStreamingService) {
        self.modelContainer = container
        self.streamingService = streaming

        // Wire the streaming service's sessionProcessed handler to us.
        streaming.onSessionProcessed = { [weak self] ack in
            Task { @MainActor in
                self?.handleSessionProcessedAck(ack)
            }
        }

        // Reset any records stuck in .awaitingAck or .uploading from a
        // previous session that was interrupted by a crash, force-quit, or
        // connection loss. Without this reset they are never picked up by
        // attemptNextUpload (which only queries .pending and .failed).
        resetOrphanedInProgressRecords()
        refreshPendingCount()
    }

    /// Resets records stuck mid-upload back to .pending so they are retried.
    private func resetOrphanedInProgressRecords() {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PendingUpload>(
            predicate: #Predicate {
                $0.statusRawValue == "awaitingAck" || $0.statusRawValue == "uploading"
            }
        )
        guard let orphaned = try? context.fetch(descriptor), !orphaned.isEmpty else { return }
        for record in orphaned {
            logger.info("Resetting orphaned \(record.statusRawValue) record \(record.id.uuidString) → pending")
            record.status = .pending
            record.bytesUploaded = 0
        }
        try? context.save()
        logger.info("Reset \(orphaned.count) orphaned in-progress record(s) to .pending")
    }

    // MARK: - Enqueue

    /// Add a freshly-completed session to the pending queue. Called from
    /// `MeetingCaptureCoordinator.stopRecording()` when the recording mode
    /// is `.localOnly` or `.degradedToLocal`.
    func enqueue(
        sessionID: UUID,
        localWAVURL: URL,
        recordedAt: Date,
        durationSeconds: TimeInterval,
        sampleRate: Double,
        channelCount: UInt32
    ) {
        guard let container = modelContainer else {
            logger.error("enqueue: no container configured")
            return
        }

        let relativePath = MeetingRecordingService.relativePath(for: localWAVURL)
        let byteSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: localWAVURL.path)[.size] as? Int64) ?? 0

        let context = ModelContext(container)
        // Don't insert a duplicate if one already exists for this ID.
        let descriptor = FetchDescriptor<PendingUpload>(
            predicate: #Predicate { $0.id == sessionID }
        )
        if let existing = try? context.fetch(descriptor).first {
            logger.info("enqueue: session \(sessionID.uuidString) already in queue, updating file size")
            existing.byteSize = byteSize
            try? context.save()
            refreshPendingCount()
            return
        }

        let pending = PendingUpload(
            id: sessionID,
            recordedAt: recordedAt,
            durationSeconds: durationSeconds,
            sampleRate: UInt32(sampleRate),
            channels: UInt16(channelCount),
            byteSize: byteSize,
            localWAVPath: relativePath,
            createdAt: .now,
            status: .pending
        )
        context.insert(pending)
        do {
            try context.save()
            refreshPendingCount()
            logger.info("enqueue: queued session \(sessionID.uuidString) (\(byteSize) bytes, \(durationSeconds)s)")
        } catch {
            logger.error("enqueue: could not save pending record: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto-Upload Cycle

    /// Attempt to upload the oldest pending item. No-op if:
    ///  - Mac not currently connected
    ///  - iPhone is currently recording (don't interfere with live work)
    ///  - An upload is already in progress
    ///  - Queue is empty
    func attemptNextUpload(isRecording: Bool) async {
        guard uploadState == .idle else { return }
        guard !isRecording else { return }
        guard let streaming = streamingService,
              streaming.connectionState == .connected else {
            return
        }
        guard let container = modelContainer else { return }

        // Fetch the oldest pending item
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PendingUpload>(
            predicate: #Predicate { $0.statusRawValue == "pending" || $0.statusRawValue == "failed" },
            sortBy: [SortDescriptor(\PendingUpload.createdAt)]
        )
        guard let next = try? context.fetch(descriptor).first else {
            return
        }

        // Verify the local WAV still exists
        let localURL = MeetingRecordingService.url(fromRelativePath: next.localWAVPath)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            logger.warning("Pending session \(next.id.uuidString) has no local WAV — removing from queue")
            context.delete(next)
            try? context.save()
            refreshPendingCount()
            return
        }

        await uploadSession(next, fileURL: localURL, container: container)
    }

    /// Drive the full upload protocol for one session.
    private func uploadSession(_ pending: PendingUpload, fileURL: URL, container: ModelContainer) async {
        guard let streaming = streamingService else { return }

        let sessionID = pending.id
        let byteSize = pending.byteSize
        logger.info("Starting upload for session \(sessionID.uuidString) (\(byteSize) bytes)")

        // Mark uploading
        pending.status = .uploading
        pending.attemptCount += 1
        pending.lastAttemptAt = .now
        pending.bytesUploaded = 0
        try? ModelContext(container).save()

        // 1. Send uploadStart
        uploadState = .sendingStart(sessionID)
        let metadata = PendingUploadMetadata(
            sessionID: sessionID.uuidString,
            recordedAt: pending.recordedAt,
            durationSeconds: pending.durationSeconds,
            sampleRate: pending.sampleRate,
            channels: pending.channels,
            byteSize: pending.byteSize
        )
        guard streaming.sendUploadStart(metadata: metadata) else {
            failUpload(pending: pending, reason: "Could not send uploadStart", container: container)
            return
        }

        // 2. Stream chunks
        uploadState = .sendingChunks(sessionID, bytesSent: 0, totalBytes: byteSize)
        currentUploadSessionID = sessionID

        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }

            var bytesSent: Int64 = 0
            let chunkSize = AudioStreamingConstants.uploadChunkSize

            while true {
                let chunkData = try fileHandle.read(upToCount: chunkSize) ?? Data()
                if chunkData.isEmpty { break }

                guard streaming.sendUploadChunk(payload: chunkData) else {
                    failUpload(pending: pending, reason: "Chunk send failed mid-upload", container: container)
                    return
                }

                bytesSent += Int64(chunkData.count)
                uploadState = .sendingChunks(sessionID, bytesSent: bytesSent, totalBytes: byteSize)

                // Persist progress every ~1MB so the UI progress bar is
                // accurate across app launches.
                if bytesSent % (1024 * 1024) < Int64(chunkSize) {
                    pending.bytesUploaded = bytesSent
                    try? ModelContext(container).save()
                }

                // Yield to let the main actor breathe (UI updates etc.)
                await Task.yield()
            }
        } catch {
            failUpload(pending: pending, reason: "File read error: \(error.localizedDescription)", container: container)
            return
        }

        // 3. Send uploadEnd
        uploadState = .sendingEnd(sessionID)
        guard streaming.sendUploadEnd() else {
            failUpload(pending: pending, reason: "Could not send uploadEnd", container: container)
            return
        }

        // 4. Await sessionProcessed ack
        uploadState = .awaitingAck(sessionID)
        pending.status = .awaitingAck
        try? ModelContext(container).save()

        logger.info("Upload complete for \(sessionID.uuidString), awaiting ack…")

        let ack = await withCheckedContinuation { (cont: CheckedContinuation<SessionProcessedAck, Never>) in
            self.ackContinuation = cont

            // Timeout safety — give the Mac up to 30 minutes to finish.
            // Whisper on a 1-hour file can take 6-12 minutes; add buffer
            // for diarization, polish, and summary.
            Task {
                try? await Task.sleep(for: .seconds(1800))
                if let pendingCont = self.ackContinuation {
                    self.ackContinuation = nil
                    pendingCont.resume(returning: SessionProcessedAck(
                        sessionID: sessionID.uuidString,
                        success: false,
                        reason: "Timeout waiting for Mac to process (30 min)"
                    ))
                }
            }
        }

        // 5. Handle the ack result
        currentUploadSessionID = nil
        let ackContext = ModelContext(container)
        let ackDescriptor = FetchDescriptor<PendingUpload>(
            predicate: #Predicate { $0.id == sessionID }
        )
        guard let freshPending = try? ackContext.fetch(ackDescriptor).first else {
            uploadState = .idle
            refreshPendingCount()
            return
        }

        if ack.success {
            logger.info("Session \(sessionID.uuidString) processed by Mac — deleting local WAV")
            // Delete the local WAV file
            try? FileManager.default.removeItem(at: fileURL)
            // Remove the pending record entirely (could also mark processed
            // and retain for a grace period — we pick clean removal).
            ackContext.delete(freshPending)
            try? ackContext.save()
        } else {
            logger.error("Mac reported processing failure for \(sessionID.uuidString): \(ack.reason ?? "unknown")")
            freshPending.status = .failed
            freshPending.failureReason = ack.reason ?? "Unknown failure"
            try? ackContext.save()
        }

        uploadState = .idle
        refreshPendingCount()

        // Auto-chain: immediately attempt the next pending item so the
        // whole queue drains in one connected session without needing a
        // tab switch or reconnect to trigger each individual upload.
        Task { [weak self] in
            await self?.attemptNextUpload(isRecording: false)
        }
    }

    private func failUpload(pending: PendingUpload, reason: String, container: ModelContainer) {
        logger.error("Upload failed for \(pending.id.uuidString): \(reason)")
        pending.status = .failed
        pending.failureReason = reason
        try? ModelContext(container).save()
        uploadState = .failed(pending.id, reason: reason)
        currentUploadSessionID = nil
        refreshPendingCount()

        // Return to idle after a short delay so the UI can show the failed
        // state briefly before another attempt.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if case .failed = self?.uploadState {
                self?.uploadState = .idle
            }
        }
    }

    // MARK: - Ack Handling

    private func handleSessionProcessedAck(_ ack: SessionProcessedAck) {
        logger.info("Received sessionProcessed ack for \(ack.sessionID) success=\(ack.success)")

        // Happy path: a continuation is waiting for exactly this ack.
        if let cont = ackContinuation {
            ackContinuation = nil
            cont.resume(returning: ack)
            return
        }

        // Out-of-band ack: arrived before the upload flow set up its
        // continuation (timing gap between uploadStart and uploadEnd), or
        // after a reconnect when the old continuation was already abandoned.
        // Apply the result directly to the SwiftData record so the session
        // is cleaned up without requiring another round-trip.
        guard let sessionID = UUID(uuidString: ack.sessionID),
              let container = modelContainer else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PendingUpload>(
            predicate: #Predicate { $0.id == sessionID }
        )
        guard let pending = try? context.fetch(descriptor).first else { return }

        if ack.success {
            logger.info("Out-of-band ack: deleting session \(sessionID.uuidString) directly")
            let localURL = MeetingRecordingService.url(fromRelativePath: pending.localWAVPath)
            try? FileManager.default.removeItem(at: localURL)
            context.delete(pending)
            try? context.save()
        } else {
            logger.error("Out-of-band ack: marking session \(sessionID.uuidString) failed — \(ack.reason ?? "unknown")")
            pending.status = .failed
            pending.failureReason = ack.reason ?? "Mac reported failure"
            try? context.save()
        }

        uploadState = .idle
        refreshPendingCount()
        Task { [weak self] in
            await self?.attemptNextUpload(isRecording: false)
        }
    }

    // MARK: - Queue Enumeration

    /// Refresh `pendingCount` from SwiftData so the UI badge is accurate.
    func refreshPendingCount() {
        guard let container = modelContainer else {
            pendingCount = 0
            return
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PendingUpload>(
            predicate: #Predicate { $0.statusRawValue != "processed" }
        )
        pendingCount = (try? context.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Crash Recovery

    /// On app launch, scan `Documents/MeetingRecordings/` for WAV files that
    /// aren't tracked by any `PendingUpload` or `TranscriptSession`. These
    /// are orphans from force-quits or crashes — we adopt them as pending
    /// uploads so the audio isn't silently lost.
    func recoverOrphanedRecordings() {
        guard let container = modelContainer else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = docs.appendingPathComponent("MeetingRecordings", isDirectory: true)

        guard FileManager.default.fileExists(atPath: recordingsDir.path) else {
            return
        }

        let context = ModelContext(container)

        // Collect known session IDs from the PendingUpload table so we
        // don't re-adopt anything already tracked.
        var knownIDs = Set<String>()
        if let existing = try? context.fetch(FetchDescriptor<PendingUpload>()) {
            for p in existing {
                knownIDs.insert(p.id.uuidString)
            }
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: recordingsDir,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
            )
        } catch {
            logger.error("Could not scan recordings dir: \(error.localizedDescription)")
            return
        }

        let wavFiles = contents.filter { $0.pathExtension.lowercased() == "wav" }
        var recoveredCount = 0

        for url in wavFiles {
            // Filename format from MeetingRecordingService:
            //   "<ISO8601-date>_<sessionID>.wav"
            let basename = url.deletingPathExtension().lastPathComponent
            let components = basename.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)
            guard components.count == 2 else { continue }
            let sessionIDString = String(components[1])

            // Skip if already tracked
            if knownIDs.contains(sessionIDString) { continue }

            guard let sessionID = UUID(uuidString: sessionIDString) else { continue }

            // Get file metadata
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64,
                  size > 0 else {
                continue
            }

            // Try to open the WAV to read its real duration + format
            let wavFormat: (sampleRate: Double, channels: Int, duration: TimeInterval)?
            if let file = try? AVAudioFile(forReading: url) {
                let sr = file.processingFormat.sampleRate
                let ch = Int(file.processingFormat.channelCount)
                let frames = file.length
                let dur = Double(frames) / sr
                wavFormat = (sr, ch, dur)
            } else {
                wavFormat = nil
            }

            let sampleRate = UInt32(wavFormat?.sampleRate ?? 48_000)
            let channels = UInt16(wavFormat?.channels ?? 1)
            let duration = wavFormat?.duration ?? 0

            // Use the file's creation date as the session's recordedAt
            let recordedAt = (attrs[.creationDate] as? Date) ?? .now

            let pending = PendingUpload(
                id: sessionID,
                recordedAt: recordedAt,
                durationSeconds: duration,
                sampleRate: sampleRate,
                channels: channels,
                byteSize: size,
                localWAVPath: "MeetingRecordings/\(url.lastPathComponent)",
                createdAt: .now,
                status: .pending
            )
            context.insert(pending)
            recoveredCount += 1
            logger.info("Recovered orphaned recording: \(url.lastPathComponent) (\(duration)s, \(size) bytes)")
        }

        if recoveredCount > 0 {
            try? context.save()
            refreshPendingCount()
            logger.info("Crash recovery adopted \(recoveredCount) orphaned recording(s)")
        }
    }
}
