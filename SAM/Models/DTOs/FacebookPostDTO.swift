//
//  FacebookPostDTO.swift
//  SAM
//
//  Value type representing a user's own Facebook post, parsed from the data export.
//

import Foundation

/// A single post by the user from their Facebook data export.
public struct FacebookPostDTO: Sendable {
    public let text: String
    public let timestamp: Date
    public let title: String?
}
