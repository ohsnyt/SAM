//
//  WhatsAppMessageDTO.swift
//  SAM
//
//  WhatsApp Direct Database Integration
//
//  Sendable DTO for WhatsApp messages read from ChatStorage.sqlite.
//

import Foundation

struct WhatsAppMessageDTO: Sendable, Identifiable {
    let id: Int64              // ZWAMESSAGE.Z_PK
    let stanzaID: String       // ZWAMESSAGE.ZSTANZAID (unique — used as sourceUID)
    let text: String?          // ZWAMESSAGE.ZTEXT
    let date: Date             // ZWAMESSAGE.ZMESSAGEDATE (Core Data epoch)
    let isFromMe: Bool         // ZWAMESSAGE.ZISFROMME
    let contactJID: String     // ZWACHATSESSION.ZCONTACTJID ("14075800106@s.whatsapp.net")
    let partnerName: String?   // ZWACHATSESSION.ZPARTNERNAME
    let messageType: Int       // 0=text, 1=image, 2=video, 3=voice, etc.
    let isStarred: Bool        // ZWAMESSAGE.ZSTARRED
}
