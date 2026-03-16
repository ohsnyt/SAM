//
//  BookmarkManager.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Manages security-scoped bookmarks for user-selected database directories
//  (iMessage ~/Library/Messages, Call History ~/Library/Application Support/CallHistoryDB,
//   LinkedIn export folder for message reprocessing after triage contact promotion).
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
    var hasLinkedInFolderAccess: Bool { linkedInFolderBookmarkData != nil }
    var hasFacebookFolderAccess: Bool { facebookFolderBookmarkData != nil }
    var hasWhatsAppAccess: Bool { whatsAppDirBookmarkData != nil }
    var hasMailDirAccess: Bool { mailDirBookmarkData != nil }

    // MARK: - Private

    private var messagesBookmarkData: Data?
    private var callHistoryBookmarkData: Data?
    private var linkedInFolderBookmarkData: Data?
    private var facebookFolderBookmarkData: Data?
    private var whatsAppDirBookmarkData: Data?
    private var mailDirBookmarkData: Data?

    private let messagesKey = "messagesDirBookmark"
    private let callHistoryKey = "callHistoryDirBookmark"
    private let linkedInFolderKey = "linkedInFolderBookmark"
    private let facebookFolderKey = "facebookFolderBookmark"
    private let whatsAppDirKey = "whatsAppDirBookmark"
    private let mailDirKey = "mailDirBookmark"

    private init() {
        messagesBookmarkData = UserDefaults.standard.data(forKey: messagesKey)
        callHistoryBookmarkData = UserDefaults.standard.data(forKey: callHistoryKey)
        linkedInFolderBookmarkData = UserDefaults.standard.data(forKey: linkedInFolderKey)
        facebookFolderBookmarkData = UserDefaults.standard.data(forKey: facebookFolderKey)
        whatsAppDirBookmarkData = UserDefaults.standard.data(forKey: whatsAppDirKey)
        mailDirBookmarkData = UserDefaults.standard.data(forKey: mailDirKey)

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

    /// Save a security-scoped bookmark for a LinkedIn export folder.
    /// Called by LinkedInImportSettingsView immediately after the user picks the folder,
    /// so we can re-access it later for triage reprocessing without another panel.
    func saveLinkedInFolderBookmark(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            linkedInFolderBookmarkData = bookmarkData
            UserDefaults.standard.set(bookmarkData, forKey: linkedInFolderKey)
            logger.info("LinkedIn folder bookmark saved for: \(url.path, privacy: .public)")
        } catch {
            logger.error("Failed to create LinkedIn folder bookmark: \(error)")
        }
    }

    /// Save a security-scoped bookmark for a Facebook export folder.
    /// Called by FacebookImportSettingsView immediately after the user picks the folder.
    func saveFacebookFolderBookmark(_ url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            facebookFolderBookmarkData = bookmarkData
            UserDefaults.standard.set(bookmarkData, forKey: facebookFolderKey)
            logger.info("Facebook folder bookmark saved for: \(url.path, privacy: .public)")
        } catch {
            logger.error("Failed to create Facebook folder bookmark: \(error)")
        }
    }

    /// Present NSOpenPanel pre-navigated to WhatsApp shared folder for user to select.
    @discardableResult
    func requestWhatsAppAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select WhatsApp Data Folder"
        panel.message = "Select the WhatsApp shared folder to allow SAM to read your WhatsApp history.\nNavigate to: ~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let whatsAppDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
        panel.directoryURL = whatsAppDir

        guard panel.runModal() == .OK, let url = panel.url else {
            logger.info("User cancelled WhatsApp directory selection")
            return nil
        }

        // Verify ChatStorage.sqlite exists in the selected directory
        let chatDB = url.appendingPathComponent("ChatStorage.sqlite")
        guard FileManager.default.fileExists(atPath: chatDB.path) else {
            logger.error("Selected directory does not contain ChatStorage.sqlite: \(url.path, privacy: .public)")
            return nil
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            whatsAppDirBookmarkData = bookmarkData
            UserDefaults.standard.set(bookmarkData, forKey: whatsAppDirKey)
            logger.info("WhatsApp directory bookmark saved for: \(url.path, privacy: .public)")
            return url
        } catch {
            logger.error("Failed to create WhatsApp bookmark: \(error)")
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

    /// Resolve the saved LinkedIn export folder bookmark.
    /// Returns the folder URL if available; caller must call startAccessingSecurityScopedResource()
    /// on it and stopAccessing(_:) in a defer block.
    func resolveLinkedInFolderURL() -> URL? {
        resolveDirectory(bookmarkData: linkedInFolderBookmarkData, key: linkedInFolderKey, label: "LinkedIn folder")
    }

    /// Resolve saved WhatsApp directory bookmark and return both database URLs.
    /// Single bookmark covers ChatStorage.sqlite (messages) and CallHistory.sqlite (calls).
    func resolveWhatsAppURL() -> (directory: URL, messagesDB: URL, callsDB: URL)? {
        guard let dirURL = resolveDirectory(bookmarkData: whatsAppDirBookmarkData, key: whatsAppDirKey, label: "WhatsApp") else {
            return nil
        }
        let messagesDB = dirURL.appendingPathComponent("ChatStorage.sqlite")
        let callsDB = dirURL.appendingPathComponent("ChatStorage.sqlite")  // Same DB for calls
        return (directory: dirURL, messagesDB: messagesDB, callsDB: callsDB)
    }

    /// Present NSOpenPanel for user to select the Mail data directory.
    /// The Mail data store lives under ~/Library/Mail/V{version}/ (e.g. V10, V11).
    /// We ask the user to select ~/Library/Mail so we can discover the version folder.
    @discardableResult
    func requestMailDirAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Mail Data Folder"
        panel.message = "Select the Mail folder to allow SAM to read email metadata directly.\nNavigate to: ~/Library/Mail"
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        let mailDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail")
        panel.directoryURL = mailDir

        guard panel.runModal() == .OK, let url = panel.url else {
            logger.info("User cancelled Mail directory selection")
            return nil
        }

        // Verify this looks like a Mail data directory (contains V* subfolder)
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let hasVersionFolder = contents.contains { $0.lastPathComponent.hasPrefix("V") }
        if !hasVersionFolder {
            logger.error("Selected directory does not appear to be ~/Library/Mail: \(url.path, privacy: .public)")
            return nil
        }

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            mailDirBookmarkData = bookmarkData
            UserDefaults.standard.set(bookmarkData, forKey: mailDirKey)
            logger.info("Mail directory bookmark saved for: \(url.path, privacy: .public)")
            return url
        } catch {
            logger.error("Failed to create Mail directory bookmark: \(error)")
            return nil
        }
    }

    /// Resolve saved Mail directory bookmark.
    /// Returns the Mail root directory URL (e.g. ~/Library/Mail).
    /// Caller must call `startAccessingSecurityScopedResource()` on the URL
    /// and `stopAccessing(_:)` in a defer block.
    func resolveMailDirURL() -> URL? {
        resolveDirectory(bookmarkData: mailDirBookmarkData, key: mailDirKey, label: "Mail directory")
    }

    /// Revoke saved Mail directory access.
    func revokeMailDirAccess() {
        mailDirBookmarkData = nil
        UserDefaults.standard.removeObject(forKey: mailDirKey)
        logger.info("Mail directory bookmark revoked")
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

    /// Revoke saved WhatsApp access.
    func revokeWhatsAppAccess() {
        whatsAppDirBookmarkData = nil
        UserDefaults.standard.removeObject(forKey: whatsAppDirKey)
        logger.info("WhatsApp bookmark revoked")
    }

    /// Revoke saved LinkedIn folder access.
    func revokeLinkedInFolderAccess() {
        linkedInFolderBookmarkData = nil
        UserDefaults.standard.removeObject(forKey: linkedInFolderKey)
        logger.info("LinkedIn folder bookmark revoked")
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
                    } else if key == callHistoryKey {
                        callHistoryBookmarkData = newData
                    } else if key == whatsAppDirKey {
                        whatsAppDirBookmarkData = newData
                    } else if key == mailDirKey {
                        mailDirBookmarkData = newData
                    } else {
                        linkedInFolderBookmarkData = newData
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
