//
//  SAMModels-PendingUpload.swift
//  SAM
//
//  Phase B: iPhone-side tracking of recordings that need to be uploaded
//  to the Mac for transcription. A `PendingUpload` record exists for any
//  session that finished in `localOnly` or `degradedToLocal` mode — the
//  audio is sitting in a local WAV file and needs to be sent to the Mac
//  the next time both devices are connected and the iPhone isn't
//  actively recording something else.
//

import SwiftData
import Foundation

// MARK: - PendingUploadStatus

public enum PendingUploadStatus: String, Codable, Sendable {
    /// Queued, waiting for Mac to be reachable + idle.
    case pending
    /// Currently being uploaded (chunks in flight).
    case uploading
    /// Uploaded; awaiting the Mac's `sessionProcessed` ack.
    case awaitingAck
    /// Mac confirmed success. The local WAV has been deleted; this row
    /// is kept briefly for UI feedback then pruned.
    case processed
    /// Upload or reprocess failed. User-visible error message lives in
    /// `failureReason`. Will retry on next auto-sync cycle.
    case failed
}

// MARK: - PendingUpload

@Model
public final class PendingUpload {
    /// Session UUID — matches the original recording's session identity.
    /// Crash recovery uses this to re-associate an orphaned WAV file
    /// with a pending-upload record that may have been saved separately.
    @Attribute(.unique) public var id: UUID

    /// When the original recording happened (not when the upload was created).
    public var recordedAt: Date

    /// Duration of the recording in seconds.
    public var durationSeconds: TimeInterval

    /// Audio format fields — needed so the Mac can reconstruct the WAV
    /// correctly during reprocessing.
    public var sampleRate: UInt32
    public var channels: UInt16

    /// Total byte size of the local WAV file.
    public var byteSize: Int64

    /// Relative path (from the iOS app's Documents directory) to the
    /// local WAV file on disk. Used by the uploader to read bytes off
    /// disk and by the cleanup path to delete the file post-ack.
    public var localWAVPath: String

    /// When this pending record was first created.
    public var createdAt: Date

    /// Raw storage for `PendingUploadStatus`.
    public var statusRawValue: String

    /// The last time the uploader attempted to push this session. Used to
    /// throttle retries after failures.
    public var lastAttemptAt: Date?

    /// How many upload attempts have been made for this session. Useful
    /// for exponential backoff and for showing "retrying…" in the UI.
    public var attemptCount: Int

    /// Human-readable reason the last attempt failed. nil when the
    /// status isn't `.failed`.
    public var failureReason: String?

    /// How many bytes have been successfully sent so far during the
    /// current upload attempt. Enables progress UI.
    public var bytesUploaded: Int64

    // MARK: - Computed

    @Transient
    public var status: PendingUploadStatus {
        get { PendingUploadStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }

    /// Fraction of bytes uploaded (0.0 - 1.0). Useful for progress bars.
    @Transient
    public var uploadProgress: Double {
        guard byteSize > 0 else { return 0 }
        return min(1.0, Double(bytesUploaded) / Double(byteSize))
    }

    public init(
        id: UUID = UUID(),
        recordedAt: Date = .now,
        durationSeconds: TimeInterval = 0,
        sampleRate: UInt32 = 48_000,
        channels: UInt16 = 1,
        byteSize: Int64 = 0,
        localWAVPath: String = "",
        createdAt: Date = .now,
        status: PendingUploadStatus = .pending,
        lastAttemptAt: Date? = nil,
        attemptCount: Int = 0,
        failureReason: String? = nil,
        bytesUploaded: Int64 = 0
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channels = channels
        self.byteSize = byteSize
        self.localWAVPath = localWAVPath
        self.createdAt = createdAt
        self.statusRawValue = status.rawValue
        self.lastAttemptAt = lastAttemptAt
        self.attemptCount = attemptCount
        self.failureReason = failureReason
        self.bytesUploaded = bytesUploaded
    }
}
