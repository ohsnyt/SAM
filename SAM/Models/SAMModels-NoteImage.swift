//
//  SAMModels-NoteImage.swift
//  SAM
//
//  Image attachment model for notes. Supports Evernote imports and clipboard paste.
//

import SwiftData
import Foundation

/// An image attached to a note (e.g., financial illustrations from Evernote, pasted screenshots)
@Model
public final class NoteImage {
    @Attribute(.unique) public var id: UUID

    /// Raw image bytes, stored externally by SwiftData to keep the database lean
    @Attribute(.externalStorage) public var imageData: Data?

    /// MIME type: "image/png", "image/jpeg", "image/gif"
    public var mimeType: String

    /// Position in the note's image list
    public var displayOrder: Int

    /// Character offset in note.content where image should appear inline.
    /// `nil` means the image appears at the end of the note.
    public var textInsertionPoint: Int?

    public var createdAt: Date

    @Relationship(deleteRule: .nullify)
    public var note: SamNote?

    public init(
        id: UUID = UUID(),
        imageData: Data? = nil,
        mimeType: String = "image/png",
        displayOrder: Int = 0,
        textInsertionPoint: Int = Int.max,
        createdAt: Date = .now
    ) {
        self.id = id
        self.imageData = imageData
        self.mimeType = mimeType
        self.displayOrder = displayOrder
        self.textInsertionPoint = textInsertionPoint
        self.createdAt = createdAt
    }
}
