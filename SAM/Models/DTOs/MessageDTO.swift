//
//  MessageDTO.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Sendable DTO representing a single iMessage/SMS message.
//  Crosses actor boundary from iMessageService → CommunicationsImportCoordinator.
//

import Foundation

struct MessageDTO: Sendable, Identifiable {
    let id: Int64              // message.ROWID
    let guid: String           // message.guid (stable sourceUID)
    let text: String?          // message.text or attributedBody extraction
    let date: Date             // converted from Core Data nanosecond epoch
    let isFromMe: Bool         // message.is_from_me
    let handleID: String       // handle.id (phone number or email)
    let chatGUID: String       // chat.guid
    let serviceName: String    // "iMessage" or "SMS"
    let hasAttachment: Bool    // message.cache_has_attachments
}
