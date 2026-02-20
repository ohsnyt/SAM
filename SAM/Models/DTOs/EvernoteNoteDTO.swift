//
//  EvernoteNoteDTO.swift
//  SAM
//
//  Phase L: Notes Pro — Evernote import DTO
//

import Foundation

/// Sendable representation of a parsed Evernote note from ENEX XML
struct EvernoteNoteDTO: Sendable, Identifiable {
    let id: UUID
    let guid: String
    let title: String
    let plainTextContent: String
    let createdAt: Date
    let updatedAt: Date
    let tags: [String]

    init(
        id: UUID = UUID(),
        guid: String,
        title: String,
        plainTextContent: String,
        createdAt: Date,
        updatedAt: Date,
        tags: [String] = []
    ) {
        self.id = id
        self.guid = guid
        self.title = title
        self.plainTextContent = plainTextContent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
    }
}
