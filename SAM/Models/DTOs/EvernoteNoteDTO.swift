//
//  EvernoteNoteDTO.swift
//  SAM
//
//  Phase L: Notes Pro — Evernote import DTO
//

import Foundation
import CryptoKit

/// Sendable representation of a parsed Evernote note from ENEX XML
struct EvernoteNoteDTO: Sendable, Identifiable {
    let id: UUID
    let guid: String
    let title: String
    let plainTextContent: String
    let createdAt: Date
    let updatedAt: Date
    let tags: [String]
    let resources: [EvernoteResourceDTO]

    /// Maps resource MD5 hash → character offset in `plainTextContent` where the image
    /// appeared in the original ENML. Populated by the ENEX parser when `<en-media>` tags
    /// are found. Resources whose hash isn't in this map default to end-of-note.
    let imagePositions: [String: Int]

    init(
        id: UUID = UUID(),
        guid: String,
        title: String,
        plainTextContent: String,
        createdAt: Date,
        updatedAt: Date,
        tags: [String] = [],
        resources: [EvernoteResourceDTO] = [],
        imagePositions: [String: Int] = [:]
    ) {
        self.id = id
        self.guid = guid
        self.title = title
        self.plainTextContent = plainTextContent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
        self.resources = resources
        self.imagePositions = imagePositions
    }
}

/// An embedded resource (image) from an Evernote note
struct EvernoteResourceDTO: Sendable {
    let data: Data
    let mimeType: String  // "image/png", "image/jpeg", "image/gif"

    /// MD5 hex digest of the resource data, used to match `<en-media hash="...">` tags
    var md5Hash: String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
