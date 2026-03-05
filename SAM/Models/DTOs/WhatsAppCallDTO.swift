//
//  WhatsAppCallDTO.swift
//  SAM
//
//  WhatsApp Direct Database Integration
//
//  Sendable DTO for WhatsApp call events read from ChatStorage.sqlite.
//

import Foundation

struct WhatsAppCallDTO: Sendable, Identifiable {
    let id: Int64              // ZWACDCALLEVENT.Z_PK
    let callIDString: String   // ZWACDCALLEVENT.ZCALLIDSTRING (unique — used as sourceUID)
    let date: Date             // Core Data epoch
    let duration: TimeInterval // ZWACDCALLEVENT.ZDURATION
    let outcome: Int           // ZWACDCALLEVENT.ZOUTCOME (0=answered, non-zero=missed/declined)
    let participantJIDs: [String]  // from joined ZWACDCALLEVENTPARTICIPANT
}
