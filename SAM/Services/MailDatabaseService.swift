//
//  MailDatabaseService.swift
//  SAM
//
//  Direct file-system access to Mail.app's data store.
//
//  Reads the Envelope Index SQLite database for metadata and .emlx files for
//  message bodies. This completely bypasses AppleScript / Apple Events, so
//  Mail.app is never blocked or slowed down.
//
//  Requires a security-scoped bookmark for ~/Library/Mail (granted via
//  BookmarkManager.requestMailDirAccess).
//

import Foundation
import SQLite3
import os.log

/// Actor-isolated service for reading email directly from Mail's on-disk data store.
actor MailDatabaseService {
    static let shared = MailDatabaseService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailDatabaseService")

    private init() {}

    // MARK: - Directory Discovery

    /// Find the active Mail data version directory (e.g. ~/Library/Mail/V10).
    /// Returns the path to the highest-numbered V* directory.
    func findMailDataDir(rootURL: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        // Find V* directories, sorted by version number descending
        let versionDirs = contents
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("V") && name.dropFirst().allSatisfy(\.isNumber)
            }
            .sorted { a, b in
                let aNum = Int(a.lastPathComponent.dropFirst()) ?? 0
                let bNum = Int(b.lastPathComponent.dropFirst()) ?? 0
                return aNum > bNum
            }

        guard let best = versionDirs.first else {
            logger.error("No V* directory found in \(rootURL.path, privacy: .public)")
            return nil
        }

        logger.debug("Using Mail data directory: \(best.lastPathComponent, privacy: .public)")
        return best
    }

    /// Locate the Envelope Index database within a Mail data version directory.
    func findEnvelopeIndex(in versionDir: URL) -> URL? {
        let candidate = versionDir.appendingPathComponent("MailData/Envelope Index")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Some versions use different casing or location
        let alt = versionDir.appendingPathComponent("MailData/Envelope Index-shm")
        if FileManager.default.fileExists(atPath: alt.path) {
            // SHM exists, so the main file should too
            return versionDir.appendingPathComponent("MailData/Envelope Index")
        }
        logger.error("Envelope Index not found in \(versionDir.path, privacy: .public)")
        return nil
    }

    // MARK: - Metadata Fetch

    /// Fetch email metadata directly from the Envelope Index SQLite database.
    /// This is the replacement for the AppleScript metadata sweep.
    ///
    /// - Parameters:
    ///   - dbURL: Path to the Envelope Index database
    ///   - since: Only return messages newer than this date
    ///   - accountEmails: Email addresses of accounts to scan (filters by mailbox ownership)
    ///   - maxResults: Maximum number of results to return
    ///   - mailbox: Which mailbox type to scan
    /// - Returns: Array of MessageMeta DTOs
    func fetchMetadata(
        dbURL: URL,
        since: Date,
        accountEmails: [String],
        maxResults: Int = 200,
        mailbox: MailboxTarget = .inbox
    ) throws -> [MessageMeta] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        // Log schema on first use to help diagnose column mismatches
        logSchema(db: db)

        // Envelope Index uses Unix timestamps (seconds since 1970-01-01)
        let sinceTimestamp = since.timeIntervalSince1970

        // The Envelope Index schema (V10, macOS 15+):
        //   messages: ROWID, subject (FK), sender (FK), date_received, date_sent,
        //             mailbox (FK), flags, message_id (RFC 2822 Message-ID)
        //   subjects: ROWID, subject (text)
        //   addresses: ROWID, address (email), comment (display name)
        //   mailboxes: ROWID, url (path to .mbox directory)

        let dateColumn = mailbox == .inbox ? "date_received" : "date_sent"

        // Build mailbox filter: inbox = not in sent/trash/junk; sent = in sent folders
        let mailboxFilter: String
        switch mailbox {
        case .inbox:
            mailboxFilter = """
                AND mb.url NOT LIKE '%Sent%'
                AND mb.url NOT LIKE '%Trash%'
                AND mb.url NOT LIKE '%Junk%'
                AND mb.url NOT LIKE '%Deleted%'
                AND mb.url NOT LIKE '%Drafts%'
                AND mb.url NOT LIKE '%Archive%'
                """
        case .sent:
            mailboxFilter = "AND mb.url LIKE '%Sent%'"
        }

        let query = """
            SELECT
                m.ROWID,
                m.message_id,
                COALESCE(s.subject, '(No Subject)'),
                COALESCE(a.address, ''),
                COALESCE(a.comment, ''),
                m.\(dateColumn),
                mb.url
            FROM messages m
            LEFT JOIN subjects s ON m.subject = s.ROWID
            LEFT JOIN addresses a ON m.sender = a.ROWID
            LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
            WHERE m.\(dateColumn) > ?1
            \(mailboxFilter)
            ORDER BY m.\(dateColumn) DESC
            LIMIT ?2
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare metadata query: \(err, privacy: .public)")
            throw MailDatabaseError.queryFailed(err)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, sinceTimestamp)
        sqlite3_bind_int(stmt, 2, Int32(maxResults))

        var metas: [MessageMeta] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID = sqlite3_column_int(stmt, 0)
            let messageID = columnString(stmt, 1) ?? ""
            let subject = columnString(stmt, 2) ?? "(No Subject)"
            let senderEmail = columnString(stmt, 3) ?? ""
            let senderName = columnString(stmt, 4) ?? ""
            let dateTimestamp = sqlite3_column_double(stmt, 5)
            let mailboxURL = columnString(stmt, 6) ?? ""

            // Reconstruct sender string in "Name <email>" format
            let sender: String
            if !senderName.isEmpty && !senderEmail.isEmpty {
                sender = "\(senderName) <\(senderEmail)>"
            } else if !senderEmail.isEmpty {
                sender = senderEmail
            } else {
                sender = senderName
            }

            let date = Date(timeIntervalSince1970: dateTimestamp)
            let normalizedEmail = senderEmail.lowercased()
            let isLikelyMarketing = MailService.isLikelyMarketingSender(email: normalizedEmail)

            // Extract account name from mailbox URL path
            // Mailbox URLs look like: imap://user@server/INBOX or similar
            let accountName = extractAccountName(from: mailboxURL, accountEmails: accountEmails)

            metas.append(MessageMeta(
                mailID: rowID,
                messageID: messageID,
                subject: subject,
                sender: sender,
                senderEmail: normalizedEmail,
                date: date,
                accountName: accountName,
                isLikelyMarketing: isLikelyMarketing,
                mailboxTarget: mailbox
            ))
        }

        logger.debug("Database metadata sweep: \(metas.count) messages since \(since, privacy: .public)")
        return metas
    }

    // MARK: - Body Fetch

    /// Fetch the plain-text body of a message by reading its .emlx file.
    ///
    /// Mail stores each message as an .emlx file. The ROWID from the Envelope Index
    /// is the filename (e.g., `12345.emlx`). The file is located within the mailbox's
    /// .mbox directory structure.
    ///
    /// .emlx format:
    /// - Line 1: byte count of the RFC 2822 message
    /// - Lines 2+: the raw RFC 2822 message (headers + body)
    /// - After the message: an XML plist with Mail's metadata
    func fetchBody(
        mailRootURL: URL,
        versionDir: URL,
        meta: MessageMeta
    ) -> EmailBodyResult? {
        // Search for the .emlx file
        guard let emlxURL = findEmlxFile(
            versionDir: versionDir,
            rowID: meta.mailID
        ) else {
            logger.debug("No .emlx file found for message \(meta.mailID)")
            return nil
        }

        guard let data = try? Data(contentsOf: emlxURL),
              let content = String(data: data, encoding: .utf8) else {
            logger.warning("Failed to read .emlx file for message \(meta.mailID)")
            return nil
        }

        return parseEmlx(content, meta: meta)
    }

    /// Batch fetch bodies for multiple messages.
    func fetchBodies(
        mailRootURL: URL,
        versionDir: URL,
        metas: [MessageMeta],
        filterRules: [MailFilterRule],
        mailbox: MailboxTarget = .inbox
    ) -> [EmailDTO] {
        var results: [EmailDTO] = []

        for meta in metas {
            guard let bodyResult = fetchBody(
                mailRootURL: mailRootURL,
                versionDir: versionDir,
                meta: meta
            ) else { continue }

            let dto = EmailDTO(
                id: String(meta.mailID),
                messageID: meta.messageID,
                subject: meta.subject,
                senderName: MailService.extractName(from: meta.sender),
                senderEmail: meta.senderEmail,
                recipientEmails: bodyResult.recipients,
                ccEmails: bodyResult.cc,
                date: meta.date,
                bodyPlainText: bodyResult.plainText,
                bodySnippet: String(bodyResult.plainText.prefix(200)),
                isRead: bodyResult.isRead,
                folderName: mailbox == .sent ? "Sent" : "INBOX"
            )
            results.append(dto)
        }

        // Apply recipient filter
        if !filterRules.isEmpty {
            results = results.filter { email in
                let allRecipients = email.recipientEmails + email.ccEmails
                return filterRules.contains { $0.matches(recipientEmails: allRecipients) }
            }
            logger.debug("After recipient filtering: \(results.count) emails")
        }

        logger.debug("Body fetch complete: \(results.count) emails from .emlx files")
        return results
    }

    // MARK: - MIME Source (for LinkedIn HTML parsing)

    /// Fetch the raw MIME source of a message from its .emlx file.
    /// Used for LinkedIn notification parsing (needs HTML, not plain text).
    func fetchMIMESource(
        versionDir: URL,
        meta: MessageMeta
    ) -> String? {
        guard let emlxURL = findEmlxFile(versionDir: versionDir, rowID: meta.mailID) else {
            return nil
        }
        guard let data = try? Data(contentsOf: emlxURL),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Extract the RFC 2822 message (skip the byte count line, stop before the XML plist)
        return extractRFC2822(from: content)
    }

    // MARK: - .emlx Parsing

    /// Result of parsing an .emlx file body.
    struct EmailBodyResult: Sendable {
        let plainText: String
        let recipients: [String]
        let cc: [String]
        let isRead: Bool
    }

    /// Parse an .emlx file's contents into a body result.
    private func parseEmlx(_ content: String, meta: MessageMeta) -> EmailBodyResult? {
        guard let rfc2822 = extractRFC2822(from: content) else { return nil }

        // Parse headers from the RFC 2822 message
        let headerEnd = rfc2822.range(of: "\r\n\r\n") ?? rfc2822.range(of: "\n\n")
        let headers: String
        let bodyRaw: String
        if let headerEnd {
            headers = String(rfc2822[rfc2822.startIndex..<headerEnd.lowerBound])
            bodyRaw = String(rfc2822[headerEnd.upperBound...])
        } else {
            headers = rfc2822
            bodyRaw = ""
        }

        // Extract recipients from To: and Cc: headers
        let recipients = extractAddresses(from: headers, headerName: "To")
        let cc = extractAddresses(from: headers, headerName: "Cc")

        // Extract plain text body (handle multipart)
        let plainText: String
        let contentType = extractHeaderValue(from: headers, headerName: "Content-Type") ?? ""
        if contentType.lowercased().contains("multipart") {
            plainText = extractPlainTextFromMultipart(bodyRaw, contentType: contentType) ?? bodyRaw
        } else {
            plainText = bodyRaw
        }

        // Check read status from the XML plist at the end of the .emlx
        let isRead = checkReadStatus(in: content)

        return EmailBodyResult(
            plainText: plainText,
            recipients: recipients,
            cc: cc,
            isRead: isRead
        )
    }

    /// Extract the RFC 2822 message from .emlx content.
    /// .emlx format: first line is byte count, then the message, then XML plist.
    private func extractRFC2822(from emlxContent: String) -> String? {
        // First line is the byte count
        guard let firstNewline = emlxContent.firstIndex(of: "\n") else { return nil }
        let byteCountStr = String(emlxContent[emlxContent.startIndex..<firstNewline]).trimmingCharacters(in: .whitespaces)
        guard let byteCount = Int(byteCountStr) else {
            // Some .emlx files might not have a byte count — try treating entire content as message
            return emlxContent
        }

        // The message starts after the first newline
        let messageStart = emlxContent.index(after: firstNewline)
        let messageData = emlxContent[messageStart...]

        // Use byte count to find the end of the RFC 2822 message
        // Note: byte count is in bytes, not characters, so we use UTF-8 data
        if let data = String(messageData).data(using: .utf8) {
            let clampedCount = min(byteCount, data.count)
            if let message = String(data: data.prefix(clampedCount), encoding: .utf8) {
                return message
            }
        }

        // Fallback: return everything up to the XML plist marker
        if let plistRange = emlxContent.range(of: "<?xml") {
            return String(emlxContent[messageStart..<plistRange.lowerBound])
        }
        return String(messageData)
    }

    /// Check the read status from the XML plist at the end of the .emlx file.
    /// The flags integer contains bit 0 = read.
    private func checkReadStatus(in emlxContent: String) -> Bool {
        // Look for <key>flags</key><integer>N</integer> in the XML plist
        guard let flagsRange = emlxContent.range(of: "<key>flags</key>") else { return true }
        let afterFlags = emlxContent[flagsRange.upperBound...]
        guard let intStart = afterFlags.range(of: "<integer>"),
              let intEnd = afterFlags.range(of: "</integer>") else { return true }
        let flagStr = String(afterFlags[intStart.upperBound..<intEnd.lowerBound])
        guard let flags = Int(flagStr) else { return true }
        // Bit 0 of flags = read
        return (flags & 1) != 0
    }

    // MARK: - .emlx File Discovery

    /// Cached list of all Messages/ directories within the Mail data store.
    /// Built once on first access, then reused for all lookups.
    private var messagesDirs: [URL]?

    /// Find all Messages/ directories within the Mail version directory.
    /// These are the directories that contain .emlx files:
    ///   V{n}/{account-uuid}/{mailbox}.mbox/Messages/
    ///   V{n}/{account-uuid}/{mailbox}.mbox/{sub}.mbox/Messages/
    private func discoverMessageDirs(versionDir: URL) -> [URL] {
        if let cached = messagesDirs { return cached }

        let fm = FileManager.default
        var dirs: [URL] = []

        guard let enumerator = fm.enumerator(
            at: versionDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }

            if url.lastPathComponent == "Messages" {
                dirs.append(url)
                enumerator.skipDescendants() // Don't go deeper inside Messages/
            }

            // Don't go deeper than 6 levels from version dir
            let depth = url.pathComponents.count - versionDir.pathComponents.count
            if depth > 5 {
                enumerator.skipDescendants()
            }
        }

        logger.debug("Discovered \(dirs.count) Messages/ directories in Mail data store")
        messagesDirs = dirs
        return dirs
    }

    /// Search for a .emlx file by ROWID within the Mail version directory.
    /// Checks all known Messages/ directories for {ROWID}.emlx.
    private func findEmlxFile(versionDir: URL, rowID: Int32) -> URL? {
        let filename = "\(rowID).emlx"
        let dirs = discoverMessageDirs(versionDir: versionDir)

        for dir in dirs {
            let candidate = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            // Also check for partial downloads
            let partial = dir.appendingPathComponent("\(rowID).partial.emlx")
            if FileManager.default.fileExists(atPath: partial.path) {
                return partial
            }
        }

        return nil
    }

    /// Clear the cached Messages/ directory list (e.g. after new mail arrives).
    func invalidateCache() {
        messagesDirs = nil
    }

    // MARK: - MIME Parsing Helpers

    /// Extract email addresses from a header line (To:, Cc:, etc.)
    private func extractAddresses(from headers: String, headerName: String) -> [String] {
        guard let value = extractHeaderValue(from: headers, headerName: headerName) else { return [] }
        // Parse comma-separated addresses, handling "Name <email>" format
        return value.components(separatedBy: ",").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return MailService.extractEmail(from: trimmed)
        }.filter { $0.contains("@") }
    }

    /// Extract a header value by name, handling folded headers.
    private func extractHeaderValue(from headers: String, headerName: String) -> String? {
        let lines = headers.components(separatedBy: "\n")
        let prefix = headerName.lowercased() + ":"
        var value: String?
        var collecting = false

        for line in lines {
            if line.lowercased().hasPrefix(prefix) {
                value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                collecting = true
            } else if collecting && (line.hasPrefix(" ") || line.hasPrefix("\t")) {
                // Folded header continuation
                value = (value ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                collecting = false
            }
        }
        return value
    }

    /// Extract plain text from a multipart MIME message.
    private func extractPlainTextFromMultipart(_ body: String, contentType: String) -> String? {
        // Extract boundary
        guard let boundaryMatch = contentType.range(of: #"boundary="?([^";]+)"?"#, options: .regularExpression) else {
            return nil
        }
        var boundary = String(contentType[boundaryMatch])
        if let eqIdx = boundary.firstIndex(of: "=") {
            boundary = String(boundary[boundary.index(after: eqIdx)...])
                .trimmingCharacters(in: .init(charactersIn: "\""))
        }

        let delimiter = "--" + boundary
        let parts = body.components(separatedBy: delimiter)

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" { continue }

            // Check if this part is text/plain
            if let headerEnd = trimmed.range(of: "\r\n\r\n") ?? trimmed.range(of: "\n\n") {
                let partHeaders = String(trimmed[trimmed.startIndex..<headerEnd.lowerBound])
                if partHeaders.lowercased().contains("text/plain") {
                    return String(trimmed[headerEnd.upperBound...])
                }
            }
        }

        return nil
    }

    /// Extract account name from a mailbox URL path.
    private func extractAccountName(from mailboxURL: String, accountEmails: [String]) -> String {
        // Mailbox URL format varies:
        //   imap://user@imap.gmail.com/INBOX
        //   imap://user@imap.mail.me.com/INBOX
        // We try to match against known account emails, fall back to the URL
        for email in accountEmails {
            if mailboxURL.lowercased().contains(email.lowercased()) {
                return email
            }
        }
        // Extract from URL if possible
        if let atRange = mailboxURL.range(of: "@") {
            let beforeAt = mailboxURL[mailboxURL.startIndex..<atRange.lowerBound]
            if let slashRange = beforeAt.range(of: "//") {
                return String(beforeAt[slashRange.upperBound...])
            }
        }
        return accountEmails.first ?? "unknown"
    }

    // MARK: - Schema Discovery

    /// Log the schema of key tables so we can diagnose column mismatches across macOS versions.
    private func logSchema(db: OpaquePointer) {
        for table in ["messages", "subjects", "addresses", "mailboxes"] {
            var stmt: OpaquePointer?
            let query = "PRAGMA table_info(\(table))"
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            var columns: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) {
                    columns.append(String(cString: name))
                }
            }
            logger.debug("Schema for '\(table)': \(columns.joined(separator: ", "), privacy: .public)")
        }

        // Also log all table names in the database
        var stmt: OpaquePointer?
        let query = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var tables: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 0) {
                tables.append(String(cString: name))
            }
        }
        logger.debug("All tables in Envelope Index: \(tables.joined(separator: ", "), privacy: .public)")
    }

    // MARK: - SQLite Helpers

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        // Open read-only — we never write to Mail's database
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let err = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw MailDatabaseError.openFailed(err)
        }
        // Set a short busy timeout in case Mail has a write lock
        sqlite3_busy_timeout(db, 1000) // 1 second
        return db
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    // MARK: - Errors

    enum MailDatabaseError: Error, LocalizedError {
        case openFailed(String)
        case queryFailed(String)
        case noEnvelopeIndex

        var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "Failed to open Mail database: \(msg)"
            case .queryFailed(let msg): return "Mail database query failed: \(msg)"
            case .noEnvelopeIndex: return "Could not locate Mail's Envelope Index database"
            }
        }
    }
}
