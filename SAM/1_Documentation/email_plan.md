     │ Plan: Email Integration (IMAP → Evidence Pipeline)                                                      │
     │                                                                                                         │
     │ Context                                                                                                 │
     │                                                                                                         │
     │ SAM currently ingests evidence from Calendar and Contacts. The user wants to add email as a third data  │
     │ source. Emails should be fetched from a user-configured IMAP account, filtered by sender, and analyzed  │
     │ on-device using Apple Foundation Models to extract summaries, named entities, product mentions, and     │
     │ event detections. Raw email bodies are never stored — only summaries and analysis artifacts are         │
     │ persisted (per project policy in CLAUDE.md/agent.md).                                                   │
     │                                                                                                         │
     │ Why IMAP, not Mail.app? macOS provides no public API to read Mail.app message bodies programmatically.  │
     │ The Message.framework was deprecated and removed. IMAP is the only reliable cross-provider approach.    │
     │                                                                                                         │
     │ Library choice: SwiftNIO IMAP. Apple's own swift-nio-imap is the best fit — it's pure Swift, maintained │
     │  by Apple, has no C dependencies (unlike MailCore2), and integrates naturally with Swift concurrency.   │
     │ It's the only external SPM dependency the project will add.                                             │
     │                                                                                                         │
     │ Architecture Overview                                                                                   │
     │                                                                                                         │
     │ Follows the existing pattern exactly:                                                                   │
     │                                                                                                         │
     │ MailService (actor)           → EmailDTO (Sendable)                                                     │
     │ EmailAnalysisService (actor)  → EmailAnalysisDTO (Sendable)                                             │
     │ MailImportCoordinator (@MainActor @Observable) → EvidenceRepository                                     │
     │                                                                                                         │
     │ Evidence items use EvidenceSource.mail (already defined) with sourceUID: "mail:<messageID>".            │
     │                                                                                                         │
     │ Files to Create/Modify (17 files)                                                                       │
     │                                                                                                         │
     │ New Files (11)                                                                                          │
     │                                                                                                         │
     │ #: 1                                                                                                    │
     │ File: Models/DTOs/EmailDTO.swift                                                                        │
     │ Layer: DTO                                                                                              │
     │ Purpose: Sendable email message wrapper                                                                 │
     │ ────────────────────────────────────────                                                                │
     │ #: 2                                                                                                    │
     │ File: Models/DTOs/EmailAnalysisDTO.swift                                                                │
     │ Layer: DTO                                                                                              │
     │ Purpose: Sendable LLM analysis results for email                                                        │
     │ ────────────────────────────────────────                                                                │
     │ #: 3                                                                                                    │
     │ File: Services/MailService.swift                                                                        │
     │ Layer: Service                                                                                          │
     │ Purpose: Actor-isolated IMAP client using SwiftNIO IMAP                                                 │
     │ ────────────────────────────────────────                                                                │
     │ #: 4                                                                                                    │
     │ File: Services/EmailAnalysisService.swift                                                               │
     │ Layer: Service                                                                                          │
     │ Purpose: Actor-isolated Foundation Models analysis for email bodies                                     │
     │ ────────────────────────────────────────                                                                │
     │ #: 5                                                                                                    │
     │ File: Coordinators/MailImportCoordinator.swift                                                          │
     │ Layer: Coordinator                                                                                      │
     │ Purpose: Orchestrates fetch → analyze → upsert pipeline                                                 │
     │ ────────────────────────────────────────                                                                │
     │ #: 6                                                                                                    │
     │ File: Views/Settings/MailSettingsView.swift                                                             │
     │ Layer: View                                                                                             │
     │ Purpose: IMAP account configuration UI                                                                  │
     │ ────────────────────────────────────────                                                                │
     │ #: 7                                                                                                    │
     │ File: Utilities/KeychainHelper.swift                                                                    │
     │ Layer: Utility                                                                                          │
     │ Purpose: Secure credential storage for IMAP password                                                    │
     │ ────────────────────────────────────────                                                                │
     │ #: 8                                                                                                    │
     │ File: Utilities/MailFilterRule.swift                                                                    │
     │ Layer: Utility                                                                                          │
     │ Purpose: Sender filter rules (domain or address)                                                        │
     │ ────────────────────────────────────────                                                                │
     │ #: 9                                                                                                    │
     │ File: Models/DTOs/OnboardingView.swift                                                                  │
     │ Layer: View                                                                                             │
     │ Purpose: Add mail permission step (modify existing)                                                     │
     │ ────────────────────────────────────────                                                                │
     │ #: 10                                                                                                   │
     │ File: Views/Settings/SettingsView.swift                                                                 │
     │ Layer: View                                                                                             │
     │ Purpose: Add Mail tab (modify existing)                                                                 │
     │ ────────────────────────────────────────                                                                │
     │ #: 11                                                                                                   │
     │ File: App/SAMApp.swift                                                                                  │
     │ Layer: App                                                                                              │
     │ Purpose: Wire up MailImportCoordinator (modify existing)                                                │
     │                                                                                                         │
     │ Modified Files (6)                                                                                      │
     │                                                                                                         │
     │ ┌─────┬───────────────────────────────────────┬──────────────────────────────────────────────────────── │
     │ ──────┐                                                                                                 │
     │ │  #  │                 File                  │                            Change                       │
     │       │                                                                                                 │
     │ ├─────┼───────────────────────────────────────┼──────────────────────────────────────────────────────── │
     │ ──────┤                                                                                                 │
     │ │ 12  │ Package.swift or Xcode project        │ Add swift-nio-imap SPM dependency                       │
     │       │                                                                                                 │
     │ ├─────┼───────────────────────────────────────┼──────────────────────────────────────────────────────── │
     │ ──────┤                                                                                                 │
     │ │ 13  │ App/SAMApp.swift                      │ Configure MailImportCoordinator, add to import triggers │
     │       │                                                                                                 │
     │ ├─────┼───────────────────────────────────────┼──────────────────────────────────────────────────────── │
     │ ──────┤                                                                                                 │
     │ │ 14  │ Views/Settings/SettingsView.swift     │ Add .mail tab to SettingsTab enum                       │
     │       │                                                                                                 │
     │ ├─────┼───────────────────────────────────────┼──────────────────────────────────────────────────────── │
     │ ──────┤                                                                                                 │
     │ │ 15  │ Models/DTOs/OnboardingView.swift      │ Add mail setup step to onboarding flow                  │
     │       │                                                                                                 │
     │ ├─────┼───────────────────────────────────────┼──────────────────────────────────────────────────────── │
     │ ──────┤                                                                                                 │
     │ │ 16  │ Repositories/EvidenceRepository.swift │ Add bulkUpsert(emails:) method, reuse participant       │
     │ resolution │                                                                                            │
     │ ├─────┼───────────────────────────────────────┼──────────────────────────────────────────────────────── │
     │ ──────┤                                                                                                 │
     │ │ 17  │ Views/AppShellView.swift              │ No change needed (Inbox already shows all evidence      │
     │ sources)  │                                                                                             │
     │ └─────┴───────────────────────────────────────┴──────────────────────────────────────────────────────── │
     │ ──────┘                                                                                                 │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step-by-Step Implementation                                                                             │
     │                                                                                                         │
     │ Step 1: Add SwiftNIO IMAP Dependency                                                                    │
     │                                                                                                         │
     │ Add apple/swift-nio-imap as an SPM dependency in the Xcode project.                                     │
     │                                                                                                         │
     │ Package: https://github.com/apple/swift-nio-imap.git                                                    │
     │ Version: from "0.1.0" (or latest)                                                                       │
     │ Product: NIOIMAPCore                                                                                    │
     │                                                                                                         │
     │ In Xcode: Project → Package Dependencies → Add → paste URL → Add to SAM target.                         │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 2: Create KeychainHelper                                                                           │
     │                                                                                                         │
     │ File: SAM/SAM/Utilities/KeychainHelper.swift                                                            │
     │                                                                                                         │
     │ Secure storage for IMAP password. Uses Security framework directly (no third-party keychain wrapper).   │
     │                                                                                                         │
     │ import Foundation                                                                                       │
     │ import Security                                                                                         │
     │                                                                                                         │
     │ enum KeychainHelper {                                                                                   │
     │     private static let service = "com.matthewsessions.SAM.mail"                                         │
     │                                                                                                         │
     │     static func save(password: String, for account: String) throws {                                    │
     │         guard let data = password.data(using: .utf8) else { return }                                    │
     │                                                                                                         │
     │         // Delete existing                                                                              │
     │         let deleteQuery: [String: Any] = [                                                              │
     │             kSecClass as String: kSecClassGenericPassword,                                              │
     │             kSecAttrService as String: service,                                                         │
     │             kSecAttrAccount as String: account                                                          │
     │         ]                                                                                               │
     │         SecItemDelete(deleteQuery as CFDictionary)                                                      │
     │                                                                                                         │
     │         // Add new                                                                                      │
     │         let addQuery: [String: Any] = [                                                                 │
     │             kSecClass as String: kSecClassGenericPassword,                                              │
     │             kSecAttrService as String: service,                                                         │
     │             kSecAttrAccount as String: account,                                                         │
     │             kSecValueData as String: data                                                               │
     │         ]                                                                                               │
     │         let status = SecItemAdd(addQuery as CFDictionary, nil)                                          │
     │         guard status == errSecSuccess else {                                                            │
     │             throw KeychainError.saveFailed(status)                                                      │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     static func load(for account: String) -> String? {                                                  │
     │         let query: [String: Any] = [                                                                    │
     │             kSecClass as String: kSecClassGenericPassword,                                              │
     │             kSecAttrService as String: service,                                                         │
     │             kSecAttrAccount as String: account,                                                         │
     │             kSecReturnData as String: true,                                                             │
     │             kSecMatchLimit as String: kSecMatchLimitOne                                                 │
     │         ]                                                                                               │
     │         var result: AnyObject?                                                                          │
     │         let status = SecItemCopyMatching(query as CFDictionary, &result)                                │
     │         guard status == errSecSuccess, let data = result as? Data else { return nil }                   │
     │         return String(data: data, encoding: .utf8)                                                      │
     │     }                                                                                                   │
     │                                                                                                         │
     │     static func delete(for account: String) {                                                           │
     │         let query: [String: Any] = [                                                                    │
     │             kSecClass as String: kSecClassGenericPassword,                                              │
     │             kSecAttrService as String: service,                                                         │
     │             kSecAttrAccount as String: account                                                          │
     │         ]                                                                                               │
     │         SecItemDelete(query as CFDictionary)                                                            │
     │     }                                                                                                   │
     │                                                                                                         │
     │     enum KeychainError: Error {                                                                         │
     │         case saveFailed(OSStatus)                                                                       │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 3: Create MailFilterRule                                                                           │
     │                                                                                                         │
     │ File: SAM/SAM/Utilities/MailFilterRule.swift                                                            │
     │                                                                                                         │
     │ import Foundation                                                                                       │
     │                                                                                                         │
     │ /// A rule for filtering emails by sender address or domain.                                            │
     │ /// Stored in UserDefaults as JSON.                                                                     │
     │ struct MailFilterRule: Codable, Sendable, Identifiable, Equatable {                                     │
     │     let id: UUID                                                                                        │
     │     let kind: Kind                                                                                      │
     │     let value: String  // e.g. "john@example.com" or "example.com"                                      │
     │                                                                                                         │
     │     enum Kind: String, Codable, Sendable {                                                              │
     │         case senderAddress   // exact email match                                                       │
     │         case senderDomain    // domain suffix match                                                     │
     │     }                                                                                                   │
     │                                                                                                         │
     │     func matches(senderEmail: String) -> Bool {                                                         │
     │         let canonical = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()        │
     │         switch kind {                                                                                   │
     │         case .senderAddress:                                                                            │
     │             return canonical == value.lowercased()                                                      │
     │         case .senderDomain:                                                                             │
     │             let domain = value.lowercased()                                                             │
     │             return canonical.hasSuffix("@\(domain)")                                                    │
     │         }                                                                                               │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 4: Create EmailDTO                                                                                 │
     │                                                                                                         │
     │ File: SAM/SAM/Models/DTOs/EmailDTO.swift                                                                │
     │                                                                                                         │
     │ import Foundation                                                                                       │
     │                                                                                                         │
     │ /// Sendable wrapper for an IMAP email message.                                                         │
     │ /// Crosses actor boundaries from MailService → MailImportCoordinator.                                  │
     │ struct EmailDTO: Sendable, Identifiable {                                                               │
     │     let id: String             // IMAP message UID or Message-ID header                                 │
     │     let messageID: String      // RFC 2822 Message-ID (globally unique)                                 │
     │     let subject: String                                                                                 │
     │     let senderName: String?                                                                             │
     │     let senderEmail: String                                                                             │
     │     let recipientEmails: [String]                                                                       │
     │     let ccEmails: [String]                                                                              │
     │     let date: Date                                                                                      │
     │     let bodyPlainText: String  // Plain text body (stripped HTML if needed)                             │
     │     let bodySnippet: String    // First ~200 chars for display                                          │
     │     let isRead: Bool                                                                                    │
     │     let folderName: String     // e.g. "INBOX"                                                          │
     │                                                                                                         │
     │     /// Format for sourceUID in SamEvidenceItem                                                         │
     │     var sourceUID: String {                                                                             │
     │         "mail:\(messageID)"                                                                             │
     │     }                                                                                                   │
     │                                                                                                         │
     │     /// All participant email addresses (sender + recipients + CC)                                      │
     │     var allParticipantEmails: [String] {                                                                │
     │         [senderEmail] + recipientEmails + ccEmails                                                      │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 5: Create EmailAnalysisDTO                                                                         │
     │                                                                                                         │
     │ File: SAM/SAM/Models/DTOs/EmailAnalysisDTO.swift                                                        │
     │                                                                                                         │
     │ import Foundation                                                                                       │
     │                                                                                                         │
     │ /// Sendable results from on-device LLM analysis of an email body.                                      │
     │ /// Crosses actor boundary from EmailAnalysisService → MailImportCoordinator.                           │
     │ struct EmailAnalysisDTO: Sendable {                                                                     │
     │     let summary: String                  // 1-2 sentence summary                                        │
     │     let namedEntities: [EmailEntityDTO]  // People, orgs, products mentioned                            │
     │     let topics: [String]                 // Financial topics detected                                   │
     │     let temporalEvents: [TemporalEventDTO]  // Dates/events mentioned                                   │
     │     let sentiment: Sentiment             // Overall tone                                                │
     │     let analysisVersion: Int                                                                            │
     │                                                                                                         │
     │     enum Sentiment: String, Sendable {                                                                  │
     │         case positive, neutral, negative, urgent                                                        │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ struct EmailEntityDTO: Sendable, Identifiable {                                                         │
     │     let id: UUID                                                                                        │
     │     let name: String                                                                                    │
     │     let kind: EntityKind                                                                                │
     │     let confidence: Double                                                                              │
     │                                                                                                         │
     │     enum EntityKind: String, Sendable {                                                                 │
     │         case person                                                                                     │
     │         case organization                                                                               │
     │         case product                                                                                    │
     │         case financialInstrument                                                                        │
     │     }                                                                                                   │
     │                                                                                                         │
     │     init(id: UUID = UUID(), name: String, kind: EntityKind, confidence: Double) {                       │
     │         self.id = id                                                                                    │
     │         self.name = name                                                                                │
     │         self.kind = kind                                                                                │
     │         self.confidence = confidence                                                                    │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ struct TemporalEventDTO: Sendable, Identifiable {                                                       │
     │     let id: UUID                                                                                        │
     │     let description: String    // "Annual review meeting"                                               │
     │     let dateString: String     // "March 15, 2026" (raw from email)                                     │
     │     let parsedDate: Date?      // Best-effort parsed date                                               │
     │     let confidence: Double                                                                              │
     │                                                                                                         │
     │     init(id: UUID = UUID(), description: String, dateString: String, parsedDate: Date?, confidence:     │
     │ Double) {                                                                                               │
     │         self.id = id                                                                                    │
     │         self.description = description                                                                  │
     │         self.dateString = dateString                                                                    │
     │         self.parsedDate = parsedDate                                                                    │
     │         self.confidence = confidence                                                                    │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 6: Create MailService (Actor)                                                                      │
     │                                                                                                         │
     │ File: SAM/SAM/Services/MailService.swift                                                                │
     │                                                                                                         │
     │ Actor-isolated IMAP client. Follows the CalendarService pattern: singleton, checks auth before every    │
     │ operation, returns only Sendable DTOs.                                                                  │
     │                                                                                                         │
     │ import Foundation                                                                                       │
     │ import NIOIMAPCore                                                                                      │
     │ import NIO                                                                                              │
     │ import NIOIMAP                                                                                          │
     │ import os.log                                                                                           │
     │                                                                                                         │
     │ /// Actor-isolated service for IMAP email access.                                                       │
     │ /// Returns only Sendable DTOs. Never stores raw messages.                                              │
     │ actor MailService {                                                                                     │
     │     static let shared = MailService()                                                                   │
     │     private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailService")          │
     │                                                                                                         │
     │     private var eventLoopGroup: EventLoopGroup?                                                         │
     │                                                                                                         │
     │     private init() {}                                                                                   │
     │                                                                                                         │
     │     // MARK: - Configuration                                                                            │
     │                                                                                                         │
     │     struct IMAPConfig: Sendable {                                                                       │
     │         let host: String        // e.g. "imap.gmail.com"                                                │
     │         let port: Int           // e.g. 993                                                             │
     │         let username: String    // e.g. "user@gmail.com"                                                │
     │         let password: String    // loaded from Keychain                                                 │
     │         let useSSL: Bool        // default: true                                                        │
     │     }                                                                                                   │
     │                                                                                                         │
     │     // MARK: - Connection Test                                                                          │
     │                                                                                                         │
     │     /// Test IMAP connection with provided credentials.                                                 │
     │     /// Returns nil on success, error message on failure.                                               │
     │     func testConnection(config: IMAPConfig) async -> String? {                                          │
     │         // Connect, LOGIN, LIST, LOGOUT                                                                 │
     │         // Return nil on success, error description on failure                                          │
     │         do {                                                                                            │
     │             let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)                                 │
     │             defer { try? group.syncShutdownGracefully() }                                               │
     │                                                                                                         │
     │             // Implementation: create NIO channel, connect, send LOGIN, verify OK                       │
     │             // ... (full SwiftNIO IMAP connection logic)                                                │
     │                                                                                                         │
     │             logger.info("IMAP connection test successful for \(config.host)")                           │
     │             return nil                                                                                  │
     │         } catch {                                                                                       │
     │             logger.error("IMAP connection test failed: \(error)")                                       │
     │             return error.localizedDescription                                                           │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     // MARK: - Fetch Emails                                                                             │
     │                                                                                                         │
     │     /// Fetch recent emails from INBOX (last N days).                                                   │
     │     /// Returns EmailDTOs for messages matching filter rules.                                           │
     │     func fetchEmails(                                                                                   │
     │         config: IMAPConfig,                                                                             │
     │         since: Date,                                                                                    │
     │         filterRules: [MailFilterRule]                                                                   │
     │     ) async throws -> [EmailDTO] {                                                                      │
     │         logger.info("Fetching emails since \(since, privacy: .public)")                                 │
     │                                                                                                         │
     │         // 1. Connect to IMAP server via SwiftNIO                                                       │
     │         // 2. LOGIN with credentials                                                                    │
     │         // 3. SELECT INBOX                                                                              │
     │         // 4. SEARCH SINCE <date>                                                                       │
     │         // 5. FETCH headers + body for matching UIDs                                                    │
     │         // 6. Filter by sender rules                                                                    │
     │         // 7. Convert to EmailDTO                                                                       │
     │         // 8. LOGOUT                                                                                    │
     │                                                                                                         │
     │         // Pseudocode for the IMAP flow:                                                                │
     │         let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)                                     │
     │         defer { try? group.syncShutdownGracefully() }                                                   │
     │                                                                                                         │
     │         // ... SwiftNIO IMAP channel setup, SSL, connect ...                                            │
     │         // ... Send LOGIN command ...                                                                   │
     │         // ... Send SELECT "INBOX" ...                                                                  │
     │         // ... Send SEARCH SINCE <date> ...                                                             │
     │         // ... For each UID: FETCH (ENVELOPE BODY[TEXT]) ...                                            │
     │         // ... Parse into EmailDTO ...                                                                  │
     │         // ... Apply filterRules: keep only emails where any rule matches senderEmail ...               │
     │         // ... Send LOGOUT ...                                                                          │
     │                                                                                                         │
     │         var results: [EmailDTO] = []                                                                    │
     │         // ... populate results ...                                                                     │
     │                                                                                                         │
     │         logger.info("Fetched \(results.count) emails matching filters")                                 │
     │         return results                                                                                  │
     │     }                                                                                                   │
     │                                                                                                         │
     │     // MARK: - Fetch Single Email                                                                       │
     │                                                                                                         │
     │     /// Fetch a single email by Message-ID (for re-analysis).                                           │
     │     func fetchEmail(                                                                                    │
     │         config: IMAPConfig,                                                                             │
     │         messageID: String                                                                               │
     │     ) async throws -> EmailDTO? {                                                                       │
     │         // SEARCH HEADER Message-ID <messageID>                                                         │
     │         // FETCH if found                                                                               │
     │         return nil                                                                                      │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ Implementation note: The full SwiftNIO IMAP connection logic involves creating a ClientBootstrap,       │
     │ adding the IMAP handler, and sending/receiving IMAP commands. The implementer should reference the      │
     │ swift-nio-imap examples for the exact channel pipeline setup. The key commands are: LOGIN, SELECT,      │
     │ SEARCH, FETCH, LOGOUT.                                                                                  │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 7: Create EmailAnalysisService (Actor)                                                             │
     │                                                                                                         │
     │ File: SAM/SAM/Services/EmailAnalysisService.swift                                                       │
     │                                                                                                         │
     │ Follows the exact same pattern as NoteAnalysisService.swift (lines 17-268). Uses FoundationModels       │
     │ framework, SystemLanguageModel.default, LanguageModelSession.                                           │
     │                                                                                                         │
     │ import Foundation                                                                                       │
     │ import FoundationModels                                                                                 │
     │ import os.log                                                                                           │
     │                                                                                                         │
     │ /// Actor-isolated service for analyzing email content with on-device LLM.                              │
     │ /// Extracts summaries, entities, topics, and temporal events.                                          │
     │ actor EmailAnalysisService {                                                                            │
     │     static let shared = EmailAnalysisService()                                                          │
     │     private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EmailAnalysisService") │
     │                                                                                                         │
     │     private init() {}                                                                                   │
     │                                                                                                         │
     │     static let currentAnalysisVersion = 1                                                               │
     │     private let model = SystemLanguageModel.default                                                     │
     │                                                                                                         │
     │     func checkAvailability() -> ModelAvailability {                                                     │
     │         // Reuse same pattern as NoteAnalysisService.checkAvailability()                                │
     │         switch model.availability {                                                                     │
     │         case .available: return .available                                                              │
     │         case .unavailable(.deviceNotEligible):                                                          │
     │             return .unavailable(reason: "Device not eligible for Apple Intelligence")                   │
     │         case .unavailable(.appleIntelligenceNotEnabled):                                                │
     │             return .unavailable(reason: "Apple Intelligence not enabled")                               │
     │         case .unavailable(.modelNotReady):                                                              │
     │             return .unavailable(reason: "Model is downloading or not ready")                            │
     │         case .unavailable(let other):                                                                   │
     │             return .unavailable(reason: "Model unavailable: \(other)")                                  │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     /// Analyze an email body and extract structured intelligence.                                      │
     │     func analyzeEmail(subject: String, body: String, senderName: String?) async throws ->               │
     │ EmailAnalysisDTO {                                                                                      │
     │         guard case .available = checkAvailability() else {                                              │
     │             throw AnalysisError.modelUnavailable                                                        │
     │         }                                                                                               │
     │                                                                                                         │
     │         let instructions = """                                                                          │
     │         You are analyzing a professional email received by an independent financial strategist.         │
     │         Extract structured intelligence from the email.                                                 │
     │                                                                                                         │
     │         CRITICAL: Respond with ONLY valid JSON. No markdown, no explanation.                            │
     │                                                                                                         │
     │         {                                                                                               │
     │           "summary": "1-2 sentence summary",                                                            │
     │           "entities": [                                                                                 │
     │             { "name": "Full Name", "kind": "person|organization|product|financial_instrument",          │
     │ "confidence": 0.0-1.0 }                                                                                 │
     │           ],                                                                                            │
     │           "topics": ["retirement planning", ...],                                                       │
     │           "temporal_events": [                                                                          │
     │             { "description": "What is happening", "date_string": "March 15, 2026", "confidence":        │
     │ 0.0-1.0 }                                                                                               │
     │           ],                                                                                            │
     │           "sentiment": "positive|neutral|negative|urgent"                                               │
     │         }                                                                                               │
     │                                                                                                         │
     │         Rules:                                                                                          │
     │         - Only extract explicitly stated information                                                    │
     │         - For entities, distinguish people from organizations from financial products                   │
     │         - For temporal events, extract any mentioned dates, deadlines, or scheduled events              │
     │         - Sentiment reflects the overall tone (urgent if action is required immediately)                │
     │         - If the email is too short or generic, return empty arrays                                     │
     │         """                                                                                             │
     │                                                                                                         │
     │         let session = LanguageModelSession(instructions: instructions)                                  │
     │         let prompt = """                                                                                │
     │         Subject: \(subject)                                                                             │
     │         \(senderName.map { "From: \($0)" } ?? "")                                                       │
     │                                                                                                         │
     │         \(body)                                                                                         │
     │         """                                                                                             │
     │                                                                                                         │
     │         let response = try await session.respond(to: prompt)                                            │
     │         return try parseResponse(response.content)                                                      │
     │     }                                                                                                   │
     │                                                                                                         │
     │     private func parseResponse(_ jsonString: String) throws -> EmailAnalysisDTO {                       │
     │         // Same cleanup logic as NoteAnalysisService.parseResponse()                                    │
     │         var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)                        │
     │         if cleaned.hasPrefix("```") {                                                                   │
     │             if let firstNewline = cleaned.firstIndex(of: "\n") {                                        │
     │                 cleaned = String(cleaned[cleaned.index(after: firstNewline)...])                        │
     │             }                                                                                           │
     │             if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }                       │
     │         }                                                                                               │
     │         cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)                               │
     │                                                                                                         │
     │         guard let data = cleaned.data(using: .utf8) else {                                              │
     │             throw AnalysisError.invalidResponse                                                         │
     │         }                                                                                               │
     │                                                                                                         │
     │         let llm = try JSONDecoder().decode(LLMEmailResponse.self, from: data)                           │
     │                                                                                                         │
     │         // Parse dates from temporal events                                                             │
     │         let dateFormatter = DateFormatter()                                                             │
     │         dateFormatter.dateStyle = .long                                                                 │
     │                                                                                                         │
     │         return EmailAnalysisDTO(                                                                        │
     │             summary: llm.summary,                                                                       │
     │             namedEntities: llm.entities.map { e in                                                      │
     │                 EmailEntityDTO(                                                                         │
     │                     name: e.name,                                                                       │
     │                     kind: EmailEntityDTO.EntityKind(rawValue: e.kind.replacingOccurrences(of: "_",      │
     │ with: "")) ?? .person,                                                                                  │
     │                     confidence: e.confidence                                                            │
     │                 )                                                                                       │
     │             },                                                                                          │
     │             topics: llm.topics,                                                                         │
     │             temporalEvents: llm.temporal_events.map { t in                                              │
     │                 TemporalEventDTO(                                                                       │
     │                     description: t.description,                                                         │
     │                     dateString: t.date_string,                                                          │
     │                     parsedDate: dateFormatter.date(from: t.date_string),                                │
     │                     confidence: t.confidence                                                            │
     │                 )                                                                                       │
     │             },                                                                                          │
     │             sentiment: EmailAnalysisDTO.Sentiment(rawValue: llm.sentiment) ?? .neutral,                 │
     │             analysisVersion: Self.currentAnalysisVersion                                                │
     │         )                                                                                               │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ // MARK: - Internal LLM Response Types                                                                  │
     │ private struct LLMEmailResponse: Codable {                                                              │
     │     let summary: String                                                                                 │
     │     let entities: [LLMEntity]                                                                           │
     │     let topics: [String]                                                                                │
     │     let temporal_events: [LLMTemporalEvent]                                                             │
     │     let sentiment: String                                                                               │
     │ }                                                                                                       │
     │                                                                                                         │
     │ private struct LLMEntity: Codable {                                                                     │
     │     let name: String                                                                                    │
     │     let kind: String                                                                                    │
     │     let confidence: Double                                                                              │
     │ }                                                                                                       │
     │                                                                                                         │
     │ private struct LLMTemporalEvent: Codable {                                                              │
     │     let description: String                                                                             │
     │     let date_string: String                                                                             │
     │     let confidence: Double                                                                              │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 8: Create MailImportCoordinator                                                                    │
     │                                                                                                         │
     │ File: SAM/SAM/Coordinators/MailImportCoordinator.swift                                                  │
     │                                                                                                         │
     │ Follows CalendarImportCoordinator pattern exactly: @MainActor @Observable, singleton, ImportStatus      │
     │ enum, importNow() async, UserDefaults-backed settings.                                                  │
     │                                                                                                         │
     │ import Foundation                                                                                       │
     │ import Observation                                                                                      │
     │ import os.log                                                                                           │
     │                                                                                                         │
     │ private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailImportCoordinator")    │
     │                                                                                                         │
     │ @MainActor                                                                                              │
     │ @Observable                                                                                             │
     │ final class MailImportCoordinator {                                                                     │
     │     static let shared = MailImportCoordinator()                                                         │
     │                                                                                                         │
     │     // Dependencies                                                                                     │
     │     private let mailService = MailService.shared                                                        │
     │     private let analysisService = EmailAnalysisService.shared                                           │
     │     private let evidenceRepository = EvidenceRepository.shared                                          │
     │                                                                                                         │
     │     // Observable state                                                                                 │
     │     var importStatus: ImportStatus = .idle                                                              │
     │     var lastImportedAt: Date?                                                                           │
     │     var lastImportCount: Int = 0                                                                        │
     │     var lastError: String?                                                                              │
     │                                                                                                         │
     │     // Settings (UserDefaults-backed, same pattern as CalendarImportCoordinator)                        │
     │     @ObservationIgnored                                                                                 │
     │     var mailEnabled: Bool {                                                                             │
     │         get { UserDefaults.standard.bool(forKey: "mailImportEnabled") }                                 │
     │         set { UserDefaults.standard.set(newValue, forKey: "mailImportEnabled") }                        │
     │     }                                                                                                   │
     │                                                                                                         │
     │     @ObservationIgnored                                                                                 │
     │     var imapHost: String {                                                                              │
     │         get { UserDefaults.standard.string(forKey: "mailImapHost") ?? "" }                              │
     │         set { UserDefaults.standard.set(newValue, forKey: "mailImapHost") }                             │
     │     }                                                                                                   │
     │                                                                                                         │
     │     @ObservationIgnored                                                                                 │
     │     var imapPort: Int {                                                                                 │
     │         get { let v = UserDefaults.standard.integer(forKey: "mailImapPort"); return v > 0 ? v : 993 }   │
     │         set { UserDefaults.standard.set(newValue, forKey: "mailImapPort") }                             │
     │     }                                                                                                   │
     │                                                                                                         │
     │     @ObservationIgnored                                                                                 │
     │     var imapUsername: String {                                                                          │
     │         get { UserDefaults.standard.string(forKey: "mailImapUsername") ?? "" }                          │
     │         set { UserDefaults.standard.set(newValue, forKey: "mailImapUsername") }                         │
     │     }                                                                                                   │
     │                                                                                                         │
     │     @ObservationIgnored                                                                                 │
     │     var importIntervalSeconds: TimeInterval {                                                           │
     │         get { let v = UserDefaults.standard.double(forKey: "mailImportInterval"); return v > 0 ? v :    │
     │ 600 }                                                                                                   │
     │         set { UserDefaults.standard.set(newValue, forKey: "mailImportInterval") }                       │
     │     }                                                                                                   │
     │                                                                                                         │
     │     @ObservationIgnored                                                                                 │
     │     var lookbackDays: Int {                                                                             │
     │         get { let v = UserDefaults.standard.integer(forKey: "mailLookbackDays"); return v > 0 ? v : 30  │
     │ }                                                                                                       │
     │         set { UserDefaults.standard.set(newValue, forKey: "mailLookbackDays") }                         │
     │     }                                                                                                   │
     │                                                                                                         │
     │     // Filter rules (stored as JSON in UserDefaults)                                                    │
     │     @ObservationIgnored                                                                                 │
     │     var filterRules: [MailFilterRule] {                                                                 │
     │         get {                                                                                           │
     │             guard let data = UserDefaults.standard.data(forKey: "mailFilterRules"),                     │
     │                   let rules = try? JSONDecoder().decode([MailFilterRule].self, from: data) else {       │
     │ return [] }                                                                                             │
     │             return rules                                                                                │
     │         }                                                                                               │
     │         set {                                                                                           │
     │             if let data = try? JSONEncoder().encode(newValue) {                                         │
     │                 UserDefaults.standard.set(data, forKey: "mailFilterRules")                              │
     │             }                                                                                           │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     private var lastImportTime: Date?                                                                   │
     │     private var importTask: Task<Void, Never>?                                                          │
     │                                                                                                         │
     │     private init() {}                                                                                   │
     │                                                                                                         │
     │     // MARK: - Public API                                                                               │
     │                                                                                                         │
     │     var isConfigured: Bool {                                                                            │
     │         !imapHost.isEmpty && !imapUsername.isEmpty &&                                                   │
     │         KeychainHelper.load(for: imapUsername) != nil                                                   │
     │     }                                                                                                   │
     │                                                                                                         │
     │     func startAutoImport() {                                                                            │
     │         guard mailEnabled, isConfigured else { return }                                                 │
     │         Task { await importNow() }                                                                      │
     │     }                                                                                                   │
     │                                                                                                         │
     │     func importNow() async {                                                                            │
     │         importTask?.cancel()                                                                            │
     │         importTask = Task { await performImport() }                                                     │
     │         await importTask?.value                                                                         │
     │     }                                                                                                   │
     │                                                                                                         │
     │     /// Test connection with current settings. Returns nil on success.                                  │
     │     func testConnection() async -> String? {                                                            │
     │         guard let password = KeychainHelper.load(for: imapUsername) else {                              │
     │             return "No password stored. Please enter your password."                                    │
     │         }                                                                                               │
     │         let config = MailService.IMAPConfig(                                                            │
     │             host: imapHost, port: imapPort,                                                             │
     │             username: imapUsername, password: password, useSSL: true                                    │
     │         )                                                                                               │
     │         return await mailService.testConnection(config: config)                                         │
     │     }                                                                                                   │
     │                                                                                                         │
     │     /// Save IMAP credentials securely.                                                                 │
     │     func saveCredentials(host: String, port: Int, username: String, password: String) throws {          │
     │         imapHost = host                                                                                 │
     │         imapPort = port                                                                                 │
     │         imapUsername = username                                                                         │
     │         try KeychainHelper.save(password: password, for: username)                                      │
     │     }                                                                                                   │
     │                                                                                                         │
     │     /// Remove stored credentials.                                                                      │
     │     func removeCredentials() {                                                                          │
     │         let username = imapUsername                                                                     │
     │         imapHost = ""                                                                                   │
     │         imapPort = 993                                                                                  │
     │         imapUsername = ""                                                                               │
     │         KeychainHelper.delete(for: username)                                                            │
     │     }                                                                                                   │
     │                                                                                                         │
     │     // MARK: - Private                                                                                  │
     │                                                                                                         │
     │     private func performImport() async {                                                                │
     │         guard isConfigured else {                                                                       │
     │             lastError = "Mail not configured"                                                           │
     │             return                                                                                      │
     │         }                                                                                               │
     │                                                                                                         │
     │         // Throttle                                                                                     │
     │         if let last = lastImportTime, Date().timeIntervalSince(last) < importIntervalSeconds {          │
     │             return                                                                                      │
     │         }                                                                                               │
     │                                                                                                         │
     │         importStatus = .importing                                                                       │
     │         lastError = nil                                                                                 │
     │                                                                                                         │
     │         do {                                                                                            │
     │             guard let password = KeychainHelper.load(for: imapUsername) else {                          │
     │                 throw MailImportError.noCredentials                                                     │
     │             }                                                                                           │
     │                                                                                                         │
     │             let config = MailService.IMAPConfig(                                                        │
     │                 host: imapHost, port: imapPort,                                                         │
     │                 username: imapUsername, password: password, useSSL: true                                │
     │             )                                                                                           │
     │                                                                                                         │
     │             let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ??      │
     │ Date()                                                                                                  │
     │                                                                                                         │
     │             // 1. Fetch emails via IMAP                                                                 │
     │             let emails = try await mailService.fetchEmails(                                             │
     │                 config: config, since: since, filterRules: filterRules                                  │
     │             )                                                                                           │
     │                                                                                                         │
     │             // 2. Analyze each email with on-device LLM                                                 │
     │             var analyzedEmails: [(EmailDTO, EmailAnalysisDTO?)] = []                                    │
     │             for email in emails {                                                                       │
     │                 do {                                                                                    │
     │                     let analysis = try await analysisService.analyzeEmail(                              │
     │                         subject: email.subject,                                                         │
     │                         body: email.bodyPlainText,                                                      │
     │                         senderName: email.senderName                                                    │
     │                     )                                                                                   │
     │                     analyzedEmails.append((email, analysis))                                            │
     │                 } catch {                                                                               │
     │                     logger.warning("Analysis failed for email \(email.messageID): \(error)")            │
     │                     analyzedEmails.append((email, nil))                                                 │
     │                 }                                                                                       │
     │             }                                                                                           │
     │                                                                                                         │
     │             // 3. Upsert into EvidenceRepository                                                        │
     │             try evidenceRepository.bulkUpsertEmails(analyzedEmails)                                     │
     │                                                                                                         │
     │             // 4. Trigger insights                                                                      │
     │             InsightGenerator.shared.startAutoGeneration()                                               │
     │                                                                                                         │
     │             // 5. Prune orphaned mail evidence                                                          │
     │             let validUIDs = Set(emails.map { $0.sourceUID })                                            │
     │             try evidenceRepository.pruneMailOrphans(validSourceUIDs: validUIDs)                         │
     │                                                                                                         │
     │             lastImportedAt = Date()                                                                     │
     │             lastImportTime = Date()                                                                     │
     │             lastImportCount = emails.count                                                              │
     │             importStatus = .success                                                                     │
     │                                                                                                         │
     │             logger.info("Mail import complete: \(emails.count) emails")                                 │
     │                                                                                                         │
     │         } catch {                                                                                       │
     │             lastError = error.localizedDescription                                                      │
     │             importStatus = .failed                                                                      │
     │             logger.error("Mail import failed: \(error)")                                                │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     enum ImportStatus: Equatable {                                                                      │
     │         case idle, importing, success, failed                                                           │
     │     }                                                                                                   │
     │                                                                                                         │
     │     enum MailImportError: Error, LocalizedError {                                                       │
     │         case noCredentials                                                                              │
     │         case notConfigured                                                                              │
     │                                                                                                         │
     │         var errorDescription: String? {                                                                 │
     │             switch self {                                                                               │
     │             case .noCredentials: return "No IMAP password found in Keychain"                            │
     │             case .notConfigured: return "Mail account not configured"                                   │
     │             }                                                                                           │
     │         }                                                                                               │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 9: Add bulkUpsertEmails to EvidenceRepository                                                      │
     │                                                                                                         │
     │ File: SAM/SAM/Repositories/EvidenceRepository.swift                                                     │
     │                                                                                                         │
     │ Add two methods: bulkUpsertEmails(_:) and pruneMailOrphans(validSourceUIDs:). These mirror the existing │
     │  calendar upsert/prune pattern.                                                                         │
     │                                                                                                         │
     │ // Add to EvidenceRepository:                                                                           │
     │                                                                                                         │
     │ /// Bulk upsert email evidence items with optional analysis data.                                       │
     │ func bulkUpsertEmails(_ emails: [(EmailDTO, EmailAnalysisDTO?)]) throws {                               │
     │     guard let context = context else { throw RepositoryError.notConfigured }                            │
     │                                                                                                         │
     │     var created = 0, updated = 0                                                                        │
     │                                                                                                         │
     │     for (email, analysis) in emails {                                                                   │
     │         let sourceUID = email.sourceUID                                                                 │
     │         let participantEmails = email.allParticipantEmails                                              │
     │         let resolved = resolvePeople(byEmails: participantEmails)                                       │
     │         let knownEmails = knownEmailSet(from: resolved)                                                 │
     │                                                                                                         │
     │         // Build participant hints from email participants                                              │
     │         let hints = buildMailParticipantHints(from: email, knownEmails: knownEmails)                    │
     │                                                                                                         │
     │         // Build snippet: use analysis summary if available, otherwise email snippet                    │
     │         let snippet = analysis?.summary ?? email.bodySnippet                                            │
     │                                                                                                         │
     │         // Build signals from analysis                                                                  │
     │         var signals: [EvidenceSignal] = []                                                              │
     │         if let analysis = analysis {                                                                    │
     │             // Convert temporal events to signals                                                       │
     │             for event in analysis.temporalEvents {                                                      │
     │                 signals.append(EvidenceSignal(                                                          │
     │                     type: .lifeEvent,                                                                   │
     │                     message: "\(event.description): \(event.dateString)",                               │
     │                     confidence: event.confidence                                                        │
     │                 ))                                                                                      │
     │             }                                                                                           │
     │             // Convert entities to signals                                                              │
     │             for entity in analysis.namedEntities where entity.kind == .financialInstrument {            │
     │                 signals.append(EvidenceSignal(                                                          │
     │                     type: .financialEvent,                                                              │
     │                     message: "Product mentioned: \(entity.name)",                                       │
     │                     confidence: entity.confidence                                                       │
     │                 ))                                                                                      │
     │             }                                                                                           │
     │         }                                                                                               │
     │                                                                                                         │
     │         if let existing = try fetch(sourceUID: sourceUID) {                                             │
     │             existing.title = email.subject                                                              │
     │             existing.snippet = snippet                                                                  │
     │             existing.bodyText = nil  // Never store raw email body                                      │
     │             existing.occurredAt = email.date                                                            │
     │             existing.participantHints = hints                                                           │
     │             existing.linkedPeople = resolved                                                            │
     │             existing.signals = signals                                                                  │
     │             updated += 1                                                                                │
     │         } else {                                                                                        │
     │             let evidence = SamEvidenceItem(                                                             │
     │                 id: UUID(),                                                                             │
     │                 state: .needsReview,                                                                    │
     │                 sourceUID: sourceUID,                                                                   │
     │                 source: .mail,                                                                          │
     │                 occurredAt: email.date,                                                                 │
     │                 title: email.subject,                                                                   │
     │                 snippet: snippet,                                                                       │
     │                 participantHints: hints,                                                                │
     │                 signals: signals                                                                        │
     │             )                                                                                           │
     │             evidence.linkedPeople = resolved                                                            │
     │             context.insert(evidence)                                                                    │
     │             created += 1                                                                                │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     try context.save()                                                                                  │
     │     logger.info("Mail bulk upsert: \(created) created, \(updated) updated")                             │
     │ }                                                                                                       │
     │                                                                                                         │
     │ /// Build participant hints from email DTO.                                                             │
     │ private func buildMailParticipantHints(from email: EmailDTO, knownEmails: Set<String>) ->               │
     │ [ParticipantHint] {                                                                                     │
     │     var hints: [ParticipantHint] = []                                                                   │
     │                                                                                                         │
     │     // Sender                                                                                           │
     │     let senderCanonical = canonicalizeEmail(email.senderEmail)                                          │
     │     let senderMatched = senderCanonical.map { knownEmails.contains($0) } ?? false                       │
     │     hints.append(ParticipantHint(                                                                       │
     │         displayName: email.senderName ?? email.senderEmail,                                             │
     │         isOrganizer: true,  // Sender is "organizer" for emails                                         │
     │         isVerified: senderMatched,                                                                      │
     │         rawEmail: email.senderEmail                                                                     │
     │     ))                                                                                                  │
     │                                                                                                         │
     │     // Recipients                                                                                       │
     │     for recipient in email.recipientEmails {                                                            │
     │         let canonical = canonicalizeEmail(recipient)                                                    │
     │         let matched = canonical.map { knownEmails.contains($0) } ?? false                               │
     │         hints.append(ParticipantHint(                                                                   │
     │             displayName: recipient,                                                                     │
     │             isOrganizer: false,                                                                         │
     │             isVerified: matched,                                                                        │
     │             rawEmail: recipient                                                                         │
     │         ))                                                                                              │
     │     }                                                                                                   │
     │                                                                                                         │
     │     return hints                                                                                        │
     │ }                                                                                                       │
     │                                                                                                         │
     │ /// Prune mail evidence items whose sourceUID is no longer in the valid set.                            │
     │ func pruneMailOrphans(validSourceUIDs: Set<String>) throws {                                            │
     │     guard let context = context else { throw RepositoryError.notConfigured }                            │
     │                                                                                                         │
     │     let allItems = try fetchAll()                                                                       │
     │     var deleted = 0                                                                                     │
     │                                                                                                         │
     │     for item in allItems {                                                                              │
     │         guard item.source == .mail else { continue }                                                    │
     │         if let sourceUID = item.sourceUID, !validSourceUIDs.contains(sourceUID) {                       │
     │             context.delete(item)                                                                        │
     │             deleted += 1                                                                                │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     try context.save()                                                                                  │
     │     if deleted > 0 {                                                                                    │
     │         logger.info("Pruned \(deleted) orphaned mail evidence items")                                   │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 10: Create MailSettingsView                                                                        │
     │                                                                                                         │
     │ File: SAM/SAM/Views/Settings/MailSettingsView.swift                                                     │
     │                                                                                                         │
     │ Follows the existing CalendarSettingsView pattern. Provides IMAP configuration, connection testing, and │
     │  sender filter management.                                                                              │
     │                                                                                                         │
     │ import SwiftUI                                                                                          │
     │ import os.log                                                                                           │
     │                                                                                                         │
     │ private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailSettingsView")         │
     │                                                                                                         │
     │ struct MailSettingsView: View {                                                                         │
     │     @State private var coordinator = MailImportCoordinator.shared                                       │
     │                                                                                                         │
     │     // Form state                                                                                       │
     │     @State private var host = ""                                                                        │
     │     @State private var port = "993"                                                                     │
     │     @State private var username = ""                                                                    │
     │     @State private var password = ""                                                                    │
     │     @State private var isTestingConnection = false                                                      │
     │     @State private var connectionResult: String?                                                        │
     │     @State private var connectionSuccess = false                                                        │
     │                                                                                                         │
     │     // Filter rule editing                                                                              │
     │     @State private var newFilterValue = ""                                                              │
     │     @State private var newFilterKind: MailFilterRule.Kind = .senderAddress                              │
     │                                                                                                         │
     │     var body: some View {                                                                               │
     │         Form {                                                                                          │
     │             // IMAP Account Section                                                                     │
     │             Section {                                                                                   │
     │                 TextField("IMAP Server", text: $host, prompt: Text("imap.gmail.com"))                   │
     │                 TextField("Port", text: $port, prompt: Text("993"))                                     │
     │                 TextField("Email Address", text: $username, prompt: Text("you@example.com"))            │
     │                 SecureField("Password / App Password", text: $password, prompt: Text("Enter password")) │
     │                                                                                                         │
     │                 HStack {                                                                                │
     │                     Button("Test Connection") { testConnection() }                                      │
     │                         .disabled(host.isEmpty || username.isEmpty || password.isEmpty ||               │
     │ isTestingConnection)                                                                                    │
     │                                                                                                         │
     │                     Button("Save") { saveCredentials() }                                                │
     │                         .disabled(host.isEmpty || username.isEmpty || password.isEmpty)                 │
     │                         .buttonStyle(.borderedProminent)                                                │
     │                                                                                                         │
     │                     if isTestingConnection {                                                            │
     │                         ProgressView().scaleEffect(0.7)                                                 │
     │                     }                                                                                   │
     │                                                                                                         │
     │                     if let result = connectionResult {                                                  │
     │                         Label(                                                                          │
     │                             connectionSuccess ? "Connected" : result,                                   │
     │                             systemImage: connectionSuccess ? "checkmark.circle.fill" :                  │
     │ "xmark.circle.fill"                                                                                     │
     │                         )                                                                               │
     │                         .foregroundStyle(connectionSuccess ? .green : .red)                             │
     │                         .font(.caption)                                                                 │
     │                     }                                                                                   │
     │                 }                                                                                       │
     │             } header: {                                                                                 │
     │                 Text("IMAP Account")                                                                    │
     │             } footer: {                                                                                 │
     │                 Text("For Gmail, use an App Password (Settings → Security → App Passwords). Credentials │
     │  are stored securely in the macOS Keychain.")                                                           │
     │             }                                                                                           │
     │                                                                                                         │
     │             // Import Settings                                                                          │
     │             Section("Import Settings") {                                                                │
     │                 Toggle("Enable Email Import", isOn: Binding(                                            │
     │                     get: { coordinator.mailEnabled },                                                   │
     │                     set: { coordinator.mailEnabled = $0 }                                               │
     │                 ))                                                                                      │
     │                                                                                                         │
     │                 Picker("Check every", selection: Binding(                                               │
     │                     get: { coordinator.importIntervalSeconds },                                         │
     │                     set: { coordinator.importIntervalSeconds = $0 }                                     │
     │                 )) {                                                                                    │
     │                     Text("5 minutes").tag(300.0)                                                        │
     │                     Text("10 minutes").tag(600.0)                                                       │
     │                     Text("30 minutes").tag(1800.0)                                                      │
     │                     Text("1 hour").tag(3600.0)                                                          │
     │                 }                                                                                       │
     │                                                                                                         │
     │                 Picker("Look back", selection: Binding(                                                 │
     │                     get: { coordinator.lookbackDays },                                                  │
     │                     set: { coordinator.lookbackDays = $0 }                                              │
     │                 )) {                                                                                    │
     │                     Text("7 days").tag(7)                                                               │
     │                     Text("14 days").tag(14)                                                             │
     │                     Text("30 days").tag(30)                                                             │
     │                     Text("90 days").tag(90)                                                             │
     │                 }                                                                                       │
     │             }                                                                                           │
     │                                                                                                         │
     │             // Sender Filters                                                                           │
     │             Section {                                                                                   │
     │                 ForEach(coordinator.filterRules) { rule in                                              │
     │                     HStack {                                                                            │
     │                         Image(systemName: rule.kind == .senderAddress ? "envelope" : "globe")           │
     │                             .foregroundStyle(.secondary)                                                │
     │                         Text(rule.value)                                                                │
     │                         Spacer()                                                                        │
     │                         Text(rule.kind == .senderAddress ? "Address" : "Domain")                        │
     │                             .font(.caption)                                                             │
     │                             .foregroundStyle(.secondary)                                                │
     │                         Button(action: { removeFilter(rule) }) {                                        │
     │                             Image(systemName: "xmark.circle.fill")                                      │
     │                                 .foregroundStyle(.secondary)                                            │
     │                         }                                                                               │
     │                         .buttonStyle(.plain)                                                            │
     │                     }                                                                                   │
     │                 }                                                                                       │
     │                                                                                                         │
     │                 HStack {                                                                                │
     │                     Picker("", selection: $newFilterKind) {                                             │
     │                         Text("Address").tag(MailFilterRule.Kind.senderAddress)                          │
     │                         Text("Domain").tag(MailFilterRule.Kind.senderDomain)                            │
     │                     }                                                                                   │
     │                     .frame(width: 100)                                                                  │
     │                                                                                                         │
     │                     TextField(                                                                          │
     │                         newFilterKind == .senderAddress ? "sender@example.com" : "example.com",         │
     │                         text: $newFilterValue                                                           │
     │                     )                                                                                   │
     │                                                                                                         │
     │                     Button("Add") { addFilter() }                                                       │
     │                         .disabled(newFilterValue.isEmpty)                                               │
     │                 }                                                                                       │
     │             } header: {                                                                                 │
     │                 Text("Sender Filters")                                                                  │
     │             } footer: {                                                                                 │
     │                 Text("Only emails from these senders/domains will be imported. If no filters are set,   │
     │ all emails are imported.")                                                                              │
     │             }                                                                                           │
     │                                                                                                         │
     │             // Status                                                                                   │
     │             if coordinator.isConfigured {                                                               │
     │                 Section("Status") {                                                                     │
     │                     HStack {                                                                            │
     │                         Text("Last Import")                                                             │
     │                         Spacer()                                                                        │
     │                         if let date = coordinator.lastImportedAt {                                      │
     │                             Text("\(coordinator.lastImportCount) emails, \(date, style: .relative)      │
     │ ago")                                                                                                   │
     │                                 .foregroundStyle(.secondary)                                            │
     │                         } else {                                                                        │
     │                             Text("Never")                                                               │
     │                                 .foregroundStyle(.secondary)                                            │
     │                         }                                                                               │
     │                     }                                                                                   │
     │                                                                                                         │
     │                     Button("Import Now") {                                                              │
     │                         Task { await coordinator.importNow() }                                          │
     │                     }                                                                                   │
     │                     .disabled(coordinator.importStatus == .importing)                                   │
     │                 }                                                                                       │
     │             }                                                                                           │
     │                                                                                                         │
     │             // Danger Zone                                                                              │
     │             if coordinator.isConfigured {                                                               │
     │                 Section {                                                                               │
     │                     Button("Remove Account", role: .destructive) {                                      │
     │                         coordinator.removeCredentials()                                                 │
     │                     }                                                                                   │
     │                 }                                                                                       │
     │             }                                                                                           │
     │         }                                                                                               │
     │         .onAppear { loadExistingCredentials() }                                                         │
     │     }                                                                                                   │
     │                                                                                                         │
     │     // MARK: - Actions                                                                                  │
     │                                                                                                         │
     │     private func loadExistingCredentials() {                                                            │
     │         host = coordinator.imapHost                                                                     │
     │         port = String(coordinator.imapPort)                                                             │
     │         username = coordinator.imapUsername                                                             │
     │         // Don't load password into field — it stays in Keychain                                        │
     │     }                                                                                                   │
     │                                                                                                         │
     │     private func testConnection() {                                                                     │
     │         isTestingConnection = true                                                                      │
     │         connectionResult = nil                                                                          │
     │         Task {                                                                                          │
     │             // Temporarily save to test                                                                 │
     │             try? coordinator.saveCredentials(                                                           │
     │                 host: host, port: Int(port) ?? 993,                                                     │
     │                 username: username, password: password                                                  │
     │             )                                                                                           │
     │             let result = await coordinator.testConnection()                                             │
     │             isTestingConnection = false                                                                 │
     │             connectionSuccess = result == nil                                                           │
     │             connectionResult = result ?? "Connection successful"                                        │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     private func saveCredentials() {                                                                    │
     │         do {                                                                                            │
     │             try coordinator.saveCredentials(                                                            │
     │                 host: host, port: Int(port) ?? 993,                                                     │
     │                 username: username, password: password                                                  │
     │             )                                                                                           │
     │             password = ""  // Clear password field after save                                           │
     │         } catch {                                                                                       │
     │             logger.error("Failed to save credentials: \(error)")                                        │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     private func addFilter() {                                                                          │
     │         var rules = coordinator.filterRules                                                             │
     │         rules.append(MailFilterRule(id: UUID(), kind: newFilterKind, value:                             │
     │ newFilterValue.trimmingCharacters(in: .whitespacesAndNewlines)))                                        │
     │         coordinator.filterRules = rules                                                                 │
     │         newFilterValue = ""                                                                             │
     │     }                                                                                                   │
     │                                                                                                         │
     │     private func removeFilter(_ rule: MailFilterRule) {                                                 │
     │         var rules = coordinator.filterRules                                                             │
     │         rules.removeAll { $0.id == rule.id }                                                            │
     │         coordinator.filterRules = rules                                                                 │
     │     }                                                                                                   │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 11: Add Mail Tab to SettingsView                                                                   │
     │                                                                                                         │
     │ File: SAM/SAM/Views/Settings/SettingsView.swift                                                         │
     │                                                                                                         │
     │ Add case mail = "Mail" to SettingsTab enum and add the tab.                                             │
     │                                                                                                         │
     │ // In SettingsTab enum, add:                                                                            │
     │ case mail = "Mail"                                                                                      │
     │                                                                                                         │
     │ // In icon computed property, add:                                                                      │
     │ case .mail: return "envelope"                                                                           │
     │                                                                                                         │
     │ // In TabView body, add before GeneralSettingsView:                                                     │
     │ MailSettingsView()                                                                                      │
     │     .tabItem {                                                                                          │
     │         Label("Mail", systemImage: "envelope")                                                          │
     │     }                                                                                                   │
     │     .tag(SettingsTab.mail)                                                                              │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 12: Wire Up in SAMApp.swift                                                                        │
     │                                                                                                         │
     │ File: SAM/SAM/App/SAMApp.swift                                                                          │
     │                                                                                                         │
     │ Add MailImportCoordinator to the import trigger chain, same as CalendarImportCoordinator.               │
     │                                                                                                         │
     │ // In the setup task (where CalendarImportCoordinator.shared.startAutoImport() is called):              │
     │                                                                                                         │
     │ // After calendar auto-import:                                                                          │
     │ if MailImportCoordinator.shared.mailEnabled {                                                           │
     │     MailImportCoordinator.shared.startAutoImport()                                                      │
     │ }                                                                                                       │
     │                                                                                                         │
     │ // In permission checking (if mail enabled was previously on but config removed):                       │
     │ // No special permission needed — IMAP uses user-provided credentials, not system permissions           │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Step 13: Add Mail Step to Onboarding (Optional Enhancement)                                             │
     │                                                                                                         │
     │ File: SAM/SAM/Models/DTOs/OnboardingView.swift                                                          │
     │                                                                                                         │
     │ Add an optional mail configuration step after the calendar selection step. This is non-blocking — the   │
     │ user can skip it.                                                                                       │
     │                                                                                                         │
     │ // Add to OnboardingStep enum:                                                                          │
     │ case mailSetup                                                                                          │
     │                                                                                                         │
     │ // Add a step view that embeds a simplified MailSettingsView                                            │
     │ // with a "Skip for now" button                                                                         │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Background Fetching Strategy                                                                            │
     │                                                                                                         │
     │ Use NSBackgroundActivityScheduler for periodic background fetch (macOS native). This is simpler than    │
     │ BGTaskScheduler (iOS-only).                                                                             │
     │                                                                                                         │
     │ // In MailImportCoordinator, add:                                                                       │
     │                                                                                                         │
     │ private var backgroundActivity: NSBackgroundActivityScheduler?                                          │
     │                                                                                                         │
     │ func scheduleBackgroundFetch() {                                                                        │
     │     let activity = NSBackgroundActivityScheduler(identifier: "com.matthewsessions.SAM.mailFetch")       │
     │     activity.repeats = true                                                                             │
     │     activity.interval = importIntervalSeconds                                                           │
     │     activity.qualityOfService = .utility                                                                │
     │                                                                                                         │
     │     activity.schedule { [weak self] completion in                                                       │
     │         guard let self else {                                                                           │
     │             completion(.finished)                                                                       │
     │             return                                                                                      │
     │         }                                                                                               │
     │         Task { @MainActor in                                                                            │
     │             await self.importNow()                                                                      │
     │             completion(.finished)                                                                       │
     │         }                                                                                               │
     │     }                                                                                                   │
     │                                                                                                         │
     │     backgroundActivity = activity                                                                       │
     │ }                                                                                                       │
     │                                                                                                         │
     │ ---                                                                                                     │
     │ Privacy & Security Considerations                                                                       │
     │                                                                                                         │
     │ 1. Credentials: Stored in macOS Keychain via Security.framework — never in UserDefaults or on disk      │
     │ 2. Email bodies: Never stored in SwiftData. Only LLM-generated summaries and extracted entities are     │
     │ persisted (per CLAUDE.md policy)                                                                        │
     │ 3. On-device processing: All LLM analysis uses FoundationModels framework — no data leaves the device   │
     │ 4. User consent: Mail integration is opt-in, requires explicit configuration, can be disabled at any    │
     │ time                                                                                                    │
     │ 5. Minimal scope: Only fetches from configured INBOX with sender filters applied server-side where      │
     │ possible                                                                                                │
     │                                                                                                         │
     │ File Structure Summary                                                                                  │
     │                                                                                                         │
     │ SAM/SAM/                                                                                                │
     │ ├── Utilities/                                                                                          │
     │ │   ├── KeychainHelper.swift          ← NEW (Step 2)                                                    │
     │ │   └── MailFilterRule.swift           ← NEW (Step 3)                                                   │
     │ ├── Models/DTOs/                                                                                        │
     │ │   ├── EmailDTO.swift                 ← NEW (Step 4)                                                   │
     │ │   └── EmailAnalysisDTO.swift         ← NEW (Step 5)                                                   │
     │ ├── Services/                                                                                           │
     │ │   ├── MailService.swift              ← NEW (Step 6)                                                   │
     │ │   └── EmailAnalysisService.swift     ← NEW (Step 7)                                                   │
     │ ├── Coordinators/                                                                                       │
     │ │   └── MailImportCoordinator.swift    ← NEW (Step 8)                                                   │
     │ ├── Repositories/                                                                                       │
     │ │   └── EvidenceRepository.swift       ← MODIFY (Step 9)                                                │
     │ ├── Views/Settings/                                                                                     │
     │ │   ├── MailSettingsView.swift         ← NEW (Step 10)                                                  │
     │ │   └── SettingsView.swift             ← MODIFY (Step 11)                                               │
     │ ├── App/                                                                                                │
     │ │   └── SAMApp.swift                   ← MODIFY (Step 12)                                               │
     │ └── Models/DTOs/                                                                                        │
     │     └── OnboardingView.swift           ← MODIFY (Step 13, optional)                                     │
     │                                                                                                         │
     │ Verification                                                                                            │
     │                                                                                                         │
     │ 1. Build: cd /Users/david/Swift/SAM/SAM && xcodebuild build -scheme SAM -destination 'platform=macOS'   │
     │ 2. Test connection: Settings → Mail → enter test IMAP credentials → Test Connection                     │
     │ 3. Test import: Settings → Mail → add sender filter → Import Now → verify evidence appears in Inbox     │
     │ 4. Test analysis: Verify email evidence items show summaries and signals (not raw body text)            │
     │ 5. Test pruning: Delete an email from the mail server → re-import → verify evidence item is pruned      │
     │ 6. Existing tests: cd /Users/david/Swift/SAM/SAM && xcodebuild test -scheme SAM -destination            │
     │ 'platform=macOS' — all 67 existing tests should still pass                                              │
     │ 7. Verify no raw bodies stored: Inspect SwiftData store to confirm bodyText is nil for mail evidence    │
     │ items                                                                                                   │
     │                                                                                                         │
     │ Implementation Order                                                                                    │
     │                                                                                                         │
     │ Implement in this exact order (each step builds on the previous):                                       │
     │                                                                                                         │
     │ 1. SPM dependency (swift-nio-imap)                                                                      │
     │ 2. KeychainHelper                                                                                       │
     │ 3. MailFilterRule                                                                                       │
     │ 4. EmailDTO                                                                                             │
     │ 5. EmailAnalysisDTO                                                                                     │
     │ 6. MailService (actor)                                                                                  │
     │ 7. EmailAnalysisService (actor)                                                                         │
     │ 8. MailImportCoordinator                                                                                │
     │ 9. EvidenceRepository additions                                                                         │
     │ 10. MailSettingsView                                                                                    │
     │ 11. SettingsView tab addition                                                                           │
     │ 12. SAMApp wiring                                                                                       │
     │ 13. Onboarding step (optional)
