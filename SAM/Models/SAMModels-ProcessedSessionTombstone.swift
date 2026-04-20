//
//  SAMModels-ProcessedSessionTombstone.swift
//  SAM
//
//  Persistent marker that a transcript session was received from SAMField
//  and intentionally deleted on the Mac. Without this, SAMField keeps
//  re-uploading the same WAV every launch: the session is gone, so
//  AudioReceivingService treats it as new and reprocesses, producing a
//  summary the user already rejected. The tombstone short-circuits
//  classifyUploadSession so SAM acks success immediately — SAMField
//  deletes its local WAV and removes the PendingUpload record.
//

import SwiftData
import Foundation

@Model
public final class ProcessedSessionTombstone {
    /// Session UUID that was processed and deleted. Matches the
    /// `sessionID` carried in SAMField's PendingUploadMetadata.
    @Attribute(.unique) public var sessionID: UUID

    /// When the tombstone was written. Retained in case a future retention
    /// policy wants to prune old tombstones — not load-bearing for dedup.
    public var deletedAt: Date

    public init(sessionID: UUID, deletedAt: Date = .now) {
        self.sessionID = sessionID
        self.deletedAt = deletedAt
    }
}
