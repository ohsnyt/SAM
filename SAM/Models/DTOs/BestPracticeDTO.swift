//
//  BestPracticeDTO.swift
//  SAM
//
//  Created on February 27, 2026.
//  Best practices knowledge base DTO.
//

import Foundation

/// A single best practice entry from the knowledge base.
nonisolated public struct BestPractice: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let category: String
    public let description: String
    public let suggestedActions: [String]

    public init(
        id: String,
        title: String,
        category: String,
        description: String,
        suggestedActions: [String] = []
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.description = description
        self.suggestedActions = suggestedActions
    }
}
