//
//  BookmarkManager.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Manages security-scoped bookmarks for user-selected database directories
//  (iMessage ~/Library/Messages, Call History ~/Library/Application Support/CallHistoryDB).
//
//  Users select the DIRECTORY via NSOpenPanel. This grants access to all files
//  within (including WAL/SHM companions required by SQLite). The resolve methods
//  return the specific database file URL within the bookmarked directory.
//

import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "BookmarkManager")

@MainActor @Observable
final class BookmarkManager {

    static let shared = BookmarkManager()

    // MARK: - Observable State

    var hasMessagesAccess: Bool { messagesBookmarkData != nil }
    var hasCallHistoryAccess: Bool { callHistoryBookmarkData != nil }

    // MARK: - Private

    private var messagesBookmarkData: Data?
    private var callHistoryBookmarkData: Data?

    private let messagesKey = "messagesDirBookmark"
    private let callHistoryKey = "callHistoryDirBookmark"

    private init() {
        messagesBookmarkData = UserDefaults.standard.data(forKey: messagesKey)
        callHistoryBookmarkData = UserDefaults.standard.data(forKey: callHistoryKey)

        // Migrate from old file-level bookmark keys if present
        if messagesBookmarkData == nil, UserDefaults.standard.data(forKey: "messagesDBBookmark") != nil {
            UserDefaults.standard.removeObject(forKey: "messagesDBBookmark")
            logger.info("Removed stale file-level messages bookmark — please re-grant directory access")
        }
        if callHistoryBookmarkData == nil, UserDefaults.standard.data(forKey: "callHistoryDBBookmark") != nil {
            UserDefaults.standard.removeObject(forKey: "callHistoryDBBookmark")
            logger.info("Removed stale file-level call history bookmark — please re-grant directory access")
        }
    }

    // MARK: - Request Access via NSOpenPanel

    /// Present NSOpenPanel pre-navigated to ~/Library/ for user to select the Messages folder.
    /// Selecting the directory grants access to chat.db and its WAL/SHM companions.
    @discardableResult
    func requestMessagesAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Messages Folder"
        panel.message = "Select the Messages folder to allow SAM to read your iMessage history.\nNavigate to: ~/Library/Messages"
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let libraryDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages")
        panel.directoryURL = libraryDir

        guard panel.runModal() == .OK, let url = panel.url else {
            logger.info("User cancelled messages directory selection")
            return nil
        }

        // Verify chat.db exists in the selected directory
        let chatDB = url.appendingPathComponent("chat.db")
        guard FileManager.default.fileExists(atPath: chatDB.path) else {
            logger.error("Selected directory does not contain chat.db: \(url.path, privacy: .public)")
            return nil
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            messagesBookmarkData = bookmarkData
            UserDefaults.standard.set(bookmarkData, forKey: messagesKey)
            logger.info("Messages directory bookmark saved for: \(url.path, privacy: .public)")
            return url
        } catch {
            logger.error("Failed to create messages bookmark: \(error)")
            return nil
        }
    }

    /// Present NSOpenPanel for user to select the CallHistoryDB folder.
    @discardableResult
    func requestCallHistoryAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Call History Folder"
        panel.message = "Select the CallHistoryDB folder to allow SAM to read your call history.\nNavigate to: ~/Library/Application Support/CallHistoryDB"
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let callHistoryDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CallHistoryDB")
        panel.directoryURL = callHistoryDir

        guard panel.runModal() == .OK, let url = panel.url else {
            logger.info("User cancelled call history directory selection")
            return nil
        }

        // Verify storedata exists
        let storedata = url.appendingPathComponent("CallHistory.storedata")
        guard FileManager.default.fileExists(atPath: storedata.path) else {
            logger.error("Selected directory does not contain CallHistory.storedata: \(url.path, privacy: .public)")
            return nil
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            callHistoryBookmarkData = bookmarkData
            UserDefaults.standard.set(bookmarkData, forKey: callHistoryKey)
            logger.info("Call history directory bookmark saved for: \(url.path, privacy: .public)")
            return url
        } catch {
            logger.error("Failed to create call history bookmark: \(error)")
            return nil
        }
    }

    // MARK: - Resolve Bookmarks

    /// Resolve saved messages directory bookmark and return the chat.db URL within it.
    /// Caller must call `startAccessingSecurityScopedResource()` on the DIRECTORY URL
    /// and `stopAccessing(_:)` in a defer block.
    /// Returns (directoryURL, chatDBURL) — caller must start/stop access on the directory.
    func resolveMessagesURL() -> (directory: URL, database: URL)? {
        guard let dirURL = resolveDirectory(bookmarkData: messagesBookmarkData, key: messagesKey, label: "messages") else {
            return nil
        }
        let dbURL = dirURL.appendingPathComponent("chat.db")
        return (directory: dirURL, database: dbURL)
    }

    /// Resolve saved call history directory bookmark and return the storedata URL.
    func resolveCallHistoryURL() -> (directory: URL, database: URL)? {
        guard let dirURL = resolveDirectory(bookmarkData: callHistoryBookmarkData, key: callHistoryKey, label: "call history") else {
            return nil
        }
        let dbURL = dirURL.appendingPathComponent("CallHistory.storedata")
        return (directory: dirURL, database: dbURL)
    }

    /// Stop accessing a security-scoped resource.
    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Revoke saved messages access.
    func revokeMessagesAccess() {
        messagesBookmarkData = nil
        UserDefaults.standard.removeObject(forKey: messagesKey)
        logger.info("Messages bookmark revoked")
    }

    /// Revoke saved call history access.
    func revokeCallHistoryAccess() {
        callHistoryBookmarkData = nil
        UserDefaults.standard.removeObject(forKey: callHistoryKey)
        logger.info("Call history bookmark revoked")
    }

    // MARK: - Private Helpers

    private func resolveDirectory(bookmarkData: Data?, key: String, label: String) -> URL? {
        guard let data = bookmarkData else { return nil }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.info("Bookmark for \(label) is stale — refreshing")
                do {
                    let newData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    UserDefaults.standard.set(newData, forKey: key)
                    if key == messagesKey {
                        messagesBookmarkData = newData
                    } else {
                        callHistoryBookmarkData = newData
                    }
                } catch {
                    logger.warning("Failed to refresh stale \(label) bookmark: \(error)")
                }
            }

            return url
        } catch {
            logger.error("Failed to resolve \(label) bookmark: \(error)")
            return nil
        }
    }
}
