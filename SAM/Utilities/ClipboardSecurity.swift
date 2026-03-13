//
//  ClipboardSecurity.swift
//  SAM
//
//  Clipboard utility with optional auto-clear for sensitive content (drafts, messages).
//

import AppKit
import os

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ClipboardSecurity")

/// Clipboard utility with optional auto-clear for sensitive content.
@MainActor
enum ClipboardSecurity {

    /// The change count at the time of the last secure copy.
    /// Used to avoid clearing content the user has since replaced.
    private static var lastChangeCount: Int = 0
    private static var clearTask: Task<Void, Never>?

    /// Copy text to the clipboard with auto-clear after the specified duration.
    /// If the user copies something else before the timeout, the clear is skipped.
    /// - Parameters:
    ///   - text: The text to copy
    ///   - clearAfter: Seconds before auto-clear. Pass nil to skip auto-clear.
    static func copy(_ text: String, clearAfter seconds: TimeInterval? = 60) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount

        // Cancel any pending clear
        clearTask?.cancel()
        clearTask = nil

        guard let seconds else { return }

        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }

            // Only clear if the pasteboard hasn't changed since our copy
            if NSPasteboard.general.changeCount == lastChangeCount {
                NSPasteboard.general.clearContents()
                logger.info("Clipboard auto-cleared after \(Int(seconds))s")
            }
        }
    }

    /// Copy without auto-clear (for non-sensitive content like prompts).
    static func copyPersistent(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
