//
//  CoachingSessionDTO.swift
//  SAM
//
//  Created on February 27, 2026.
//  Strategic Action Coaching Flow — Phase C
//
//  Sendable DTOs for the coaching chat session: messages, actions, and context.
//

import Foundation

// MARK: - Coaching Message

/// A single message in a coaching conversation.
nonisolated public struct CoachingMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let role: MessageRole
    public let content: String
    public let timestamp: Date
    public let actions: [CoachingAction]

    public enum MessageRole: String, Codable, Sendable {
        case assistant
        case user
    }

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = .now,
        actions: [CoachingAction] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.actions = actions
    }
}

// MARK: - Coaching Action

/// An actionable button the AI can attach to a coaching message.
nonisolated public struct CoachingAction: Codable, Sendable, Identifiable {
    public let id: UUID
    public let label: String
    public let actionType: ActionType
    public let metadata: [String: String]

    public enum ActionType: String, Codable, Sendable {
        case composeMessage
        case draftContent
        case scheduleEvent
        case createNote
        case navigateToPerson
        case reviewPipeline
    }

    public init(
        id: UUID = UUID(),
        label: String,
        actionType: ActionType,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.label = label
        self.actionType = actionType
        self.metadata = metadata
    }
}

// MARK: - Coaching Session Context

/// Context passed to start a coaching session.
nonisolated public struct CoachingSessionContext: Sendable {
    public let recommendation: StrategicRec
    public let approach: ImplementationApproach?
    public let businessSnapshot: String

    public init(
        recommendation: StrategicRec,
        approach: ImplementationApproach? = nil,
        businessSnapshot: String = ""
    ) {
        self.recommendation = recommendation
        self.approach = approach
        self.businessSnapshot = businessSnapshot
    }
}

// MARK: - Life Event Coaching Context

/// Context passed to start a life-event coaching session.
nonisolated public struct LifeEventCoachingContext: Sendable, Identifiable {
    public let id: UUID
    public let event: LifeEvent
    public let personID: UUID?
    public let personName: String
    public let personRoles: [String]
    public let relationshipSummary: String

    public init(
        id: UUID = UUID(),
        event: LifeEvent,
        personID: UUID?,
        personName: String,
        personRoles: [String] = [],
        relationshipSummary: String = ""
    ) {
        self.id = id
        self.event = event
        self.personID = personID
        self.personName = personName
        self.personRoles = personRoles
        self.relationshipSummary = relationshipSummary
    }
}
