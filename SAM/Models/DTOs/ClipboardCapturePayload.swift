//
//  ClipboardCapturePayload.swift
//  SAM
//
//  Global Clipboard Capture Hotkey
//
//  Lightweight payload for the clipboard capture auxiliary window.
//

import Foundation

struct ClipboardCapturePayload: Codable, Hashable, Sendable {
    let captureID: UUID

    init(captureID: UUID = UUID()) {
        self.captureID = captureID
    }
}
