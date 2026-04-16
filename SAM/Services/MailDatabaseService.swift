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
            let dirCount = discoverMessageDirs(versionDir: versionDir).count
            logger.debug("No .emlx file found for message \(meta.mailID) (\(meta.subject, privacy: .private)) in \(dirCount) dirs")
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
                bccEmails: [],
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

    // MARK: - Database-Only Body Fetch (no .emlx required)

    /// Create EmailDTOs from metadata + recipients queried from the Envelope Index.
    /// Used when .emlx files aren't available (IMAP-only messages, especially sent mail).
    /// Body text will be empty, but recipients/CC are extracted from the database.
    func fetchMetadataOnly(
        dbURL: URL,
        metas: [MessageMeta],
        mailbox: MailboxTarget = .sent
    ) throws -> [EmailDTO] {
        let db = try openDatabase(at: dbURL)
        defer { sqlite3_close(db) }

        var results: [EmailDTO] = []

        for meta in metas {
            // Query recipients for this message from the recipients table
            let (toAddrs, ccAddrs, bccAddrs) = queryRecipients(db: db, messageRowID: meta.mailID)

            // Skip messages with no recipients (can't link to contacts)
            guard !toAddrs.isEmpty || !ccAddrs.isEmpty else { continue }

            // Try to get a snippet/summary from the database
            let snippet = querySnippet(db: db, messageRowID: meta.mailID)

            // Build a descriptive fallback if no snippet is available
            let allRecipients = toAddrs + ccAddrs
            let recipientList = allRecipients.prefix(3).joined(separator: ", ")
                + (allRecipients.count > 3 ? " +\(allRecipients.count - 3) more" : "")
            let fallback = "Sent to \(recipientList)"

            let dto = EmailDTO(
                id: String(meta.mailID),
                messageID: meta.messageID,
                subject: meta.subject,
                senderName: MailService.extractName(from: meta.sender),
                senderEmail: meta.senderEmail,
                recipientEmails: toAddrs,
                ccEmails: ccAddrs,
                bccEmails: bccAddrs,
                date: meta.date,
                bodyPlainText: snippet ?? fallback,
                bodySnippet: snippet ?? fallback,
                isRead: true,
                folderName: mailbox == .sent ? "Sent" : "INBOX"
            )
            results.append(dto)
        }

        logger.debug("Metadata-only fetch: \(results.count)/\(metas.count) messages with recipients from DB")
        return results
    }

    /// Query To and CC recipients for a message from the Envelope Index.
    /// Returns (toEmails, ccEmails).
    private func queryRecipients(db: OpaquePointer, messageRowID: Int32) -> ([String], [String], [String]) {
        // First, discover the actual column names in the recipients table
        var columnNames: [String] = []
        var pragmaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(recipients)", -1, &pragmaStmt, nil) == SQLITE_OK {
            while sqlite3_step(pragmaStmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(pragmaStmt, 1) {
                    columnNames.append(String(cString: name))
                }
            }
            sqlite3_finalize(pragmaStmt)
        }

        // Determine the correct column names for message FK and address FK
        let msgCol = columnNames.first(where: { $0.lowercased().contains("message") }) ?? "message_id"
        let addrCol = columnNames.first(where: { $0.lowercased().contains("address") }) ?? "address_id"
        let typeCol = columnNames.first(where: { $0.lowercased() == "type" }) ?? "type"

        let recipientQuery = """
            SELECT a.address, r.\(typeCol)
            FROM recipients r
            JOIN addresses a ON r.\(addrCol) = a.ROWID
            WHERE r.\(msgCol) = ?1
            """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, recipientQuery, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, messageRowID)

            var toAddrs: [String] = []
            var ccAddrs: [String] = []
            var bccAddrs: [String] = []

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let addr = columnString(stmt, 0), !addr.isEmpty else { continue }
                let type = sqlite3_column_int(stmt, 1)
                switch type {
                case 0: toAddrs.append(addr.lowercased())
                case 1: ccAddrs.append(addr.lowercased())
                case 2: bccAddrs.append(addr.lowercased())
                default: toAddrs.append(addr.lowercased())
                }
            }

            if !toAddrs.isEmpty || !ccAddrs.isEmpty || !bccAddrs.isEmpty {
                return (toAddrs, ccAddrs, bccAddrs)
            }
        } else {
            let err = String(cString: sqlite3_errmsg(db))
            logger.warning("[recipients] Query failed: \(err, privacy: .public) — columns: \(columnNames.joined(separator: ", "), privacy: .public)")
        }

        return ([], [], [])
    }

    /// Try to extract a message snippet/preview from the database.
    /// Returns nil if no meaningful text is found.
    private func querySnippet(db: OpaquePointer, messageRowID: Int32) -> String? {
        // Try the summaries table — column names vary by macOS version,
        // so discover them dynamically. Silently return nil if unavailable.
        var pragmaStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(summaries)", -1, &pragmaStmt, nil) == SQLITE_OK else {
            return nil
        }
        var columns: [String] = []
        while sqlite3_step(pragmaStmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(pragmaStmt, 1) {
                columns.append(String(cString: name))
            }
        }
        sqlite3_finalize(pragmaStmt)

        let msgCol = columns.first(where: { $0.lowercased().contains("message") })
        let textCol = columns.first(where: { $0.lowercased().contains("summary") || $0.lowercased().contains("text") || $0.lowercased().contains("content") })
        guard let msgCol, let textCol else { return nil }

        let query = "SELECT \(textCol) FROM summaries WHERE \(msgCol) = ?1 LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, messageRowID)
        if sqlite3_step(stmt) == SQLITE_ROW, let text = columnString(stmt, 0),
           !text.isEmpty, text.count > 10 {
            return text
        }
        return nil
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
    /// Mail stores .emlx files in sharded directory trees:
    ///   V{n}/{account}/{mailbox}.mbox/Messages/          (flat)
    ///   V{n}/{account}/{mailbox}.mbox/Data/{0-9}/Messages/  (sharded)
    ///   V{n}/{account}/{mailbox}.mbox/Data/{0-9}/{0-9}/Messages/  (double-sharded)
    private func discoverMessageDirs(versionDir: URL) -> [URL] {
        if let cached = messagesDirs { return cached }

        let fm = FileManager.default
        var dirs: [URL] = []

        // Don't skip package descendants — .mbox directories are macOS packages
        guard let enumerator = fm.enumerator(
            at: versionDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }

            if url.lastPathComponent == "Messages" {
                dirs.append(url)
                enumerator.skipDescendants() // Don't go deeper inside Messages/
                continue
            }

            // Skip Attachments directories — no .emlx files there
            if url.lastPathComponent == "Attachments" {
                enumerator.skipDescendants()
                continue
            }

            // Don't go deeper than 8 levels from version dir
            // (account/mailbox.mbox/Data/X/Y/Messages = 6 levels)
            let depth = url.pathComponents.count - versionDir.pathComponents.count
            if depth > 7 {
                enumerator.skipDescendants()
            }
        }

        logger.debug("Discovered \(dirs.count) Messages/ directories in Mail data store")
        messagesDirs = dirs
        return dirs
    }

    /// Search for a .emlx file by ROWID within the Mail version directory.
    /// Checks all known Messages/ directories for {ROWID}.emlx.
    /// Falls back to a recursive search within the version directory.
    private func findEmlxFile(versionDir: URL, rowID: Int32) -> URL? {
        let filename = "\(rowID).emlx"
        let partialFilename = "\(rowID).partial.emlx"
        let dirs = discoverMessageDirs(versionDir: versionDir)

        // Fast path: check known Messages/ directories
        for dir in dirs {
            let candidate = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let partial = dir.appendingPathComponent(partialFilename)
            if FileManager.default.fileExists(atPath: partial.path) {
                return partial
            }
        }

        // Slow path: recursive search using shell find (catches sharded/nested structures)
        // Only runs once per missing message — results get picked up by the DB-only fallback
        if let result = findEmlxRecursive(versionDir: versionDir, filename: filename) {
            // Cache this directory for future lookups
            let parent = result.deletingLastPathComponent()
            if !(messagesDirs ?? []).contains(parent) {
                messagesDirs?.append(parent)
                logger.debug("Discovered new .emlx directory: \(parent.lastPathComponent, privacy: .public) (via recursive search for \(rowID))")
            }
            return result
        }

        return nil
    }

    /// Recursive file search for a specific .emlx filename within the version directory.
    /// Used as fallback when the standard Messages/ directory scan doesn't find the file.
    private func findEmlxRecursive(versionDir: URL, filename: String) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: versionDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]  // Don't skip package descendants — .mbox are packages
        ) else { return nil }

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == filename {
                return url
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

    // MARK: - SQLite Helpers

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        // Open read-only — we never write to Mail's database
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let err: String
            if let db {
                err = String(cString: sqlite3_errmsg(db))
                sqlite3_close(db)
            } else {
                err = "sqlite3_open_v2 returned \(rc) with nil db pointer"
            }
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
