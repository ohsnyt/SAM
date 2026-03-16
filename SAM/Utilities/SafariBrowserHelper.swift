//
//  SafariBrowserHelper.swift
//  SAM
//
//  Opens URLs in Safari windows via AppleScript and can close them later.
//  Preserves the user's existing Safari session (cookies, logins).
//

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SafariBrowserHelper")

enum SafariBrowserHelper {

    /// Open a URL in a new Safari window positioned and sized for easy photo drag.
    /// - Parameters:
    ///   - url: The URL to open.
    ///   - origin: Screen-coordinate origin (bottom-left) for the Safari window.
    ///             If nil, Safari picks its default position.
    ///   - size: Window size in points (default 500×500).
    /// - Returns: The window ID for later closing, or nil on failure.
    @discardableResult
    static func openInNewWindow(
        url: URL,
        origin: CGPoint? = nil,
        size: CGSize = CGSize(width: 500, height: 500)
    ) -> Int? {
        let boundsClause: String
        if let origin {
            // AppleScript `bounds` is {left, top, right, bottom} in screen coords
            // where top=0 is the top of the main screen.
            let left = Int(origin.x)
            let top = Int(origin.y)
            let right = left + Int(size.width)
            let bottom = top + Int(size.height)
            boundsClause = "set bounds of front window to {\(left), \(top), \(right), \(bottom)}"
        } else {
            boundsClause = ""
        }

        let script = """
        tell application "Safari"
            activate
            delay 0.3
            make new document with properties {URL:"\(url.absoluteString)"}
            delay 0.2
            \(boundsClause)
            set winID to id of front window
            return winID
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            logger.error("Failed to create AppleScript")
            return nil
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript error opening Safari: \(error, privacy: .public)")
            NSWorkspace.shared.open(url)
            return nil
        }

        let windowID = Int(result.int32Value)
        logger.debug("Opened Safari window with ID \(windowID)")
        return windowID
    }

    /// Close a Safari window by its stable window ID.
    static func closeWindow(id: Int) {
        let script = """
        tell application "Safari"
            try
                close (every window whose id is \(id))
            end try
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            logger.warning("AppleScript error closing Safari window: \(error, privacy: .public)")
        }
    }

    /// Close multiple Safari windows by their stable IDs.
    static func closeWindows(ids: [Int]) {
        guard !ids.isEmpty else { return }
        // Build a single AppleScript that closes all windows in one call
        let idList = ids.map(String.init).joined(separator: " or id is ")
        let script = """
        tell application "Safari"
            try
                close (every window whose id is \(idList))
            end try
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            logger.warning("AppleScript error closing Safari windows: \(error, privacy: .public)")
        }
    }
}
