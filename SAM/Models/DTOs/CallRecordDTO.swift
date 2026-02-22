//
//  CallRecordDTO.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Sendable DTO representing a single call/FaceTime record.
//  Crosses actor boundary from CallHistoryService → CommunicationsImportCoordinator.
//

import Foundation

struct CallRecordDTO: Sendable, Identifiable {
    let id: Int64              // Z_PK
    let address: String        // ZADDRESS (phone number)
    let date: Date             // ZDATE converted
    let duration: TimeInterval // ZDURATION
    let callType: CallType     // mapped from ZCALLTYPE
    let isOutgoing: Bool       // ZORIGINATED == 1
    let wasAnswered: Bool      // ZANSWERED == 1

    enum CallType: Sendable {
        case phone           // ZCALLTYPE 1
        case faceTimeVideo   // ZCALLTYPE 8
        case faceTimeAudio   // ZCALLTYPE 16
        case unknown(Int)

        var isFaceTime: Bool {
            switch self {
            case .faceTimeVideo, .faceTimeAudio: return true
            default: return false
            }
        }
    }
}
