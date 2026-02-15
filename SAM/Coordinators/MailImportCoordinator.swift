//
//  MailImportCoordinator.swift
//  SAM_crm
//
//  Email Integration - Import Coordinator
//
//  Orchestrates email fetch → analyze → upsert pipeline via Mail.app.
//

import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailImportCoordinator")

@MainActor
@Observable
final class MailImportCoordinator {
    static let shared = MailImportCoordinator()

    // Dependencies
    private let mailService = MailService.shared
    private let analysisService = EmailAnalysisService.shared
    private let evidenceRepository = EvidenceRepository.shared

    // Observable state
    var importStatus: ImportStatus = .idle
    var lastImportedAt: Date?
    var lastImportCount: Int = 0
    var lastError: String?

    /// Available Mail.app accounts (loaded from service, not persisted)
    var availableAccounts: [MailAccountDTO] = []

    // Settings (observable vars synced to UserDefaults)
    private(set) var mailEnabled: Bool = false
    private(set) var selectedAccountIDs: [String] = []
    private(set) var importIntervalSeconds: TimeInterval = 600
    private(set) var lookbackDays: Int = 30
    private(set) var filterRules: [MailFilterRule] = []

    private var lastImportTime: Date?
    private var importTask: Task<Void, Never>?

    private init() {
        mailEnabled = UserDefaults.standard.bool(forKey: "mailImportEnabled")
        selectedAccountIDs = UserDefaults.standard.stringArray(forKey: "mailSelectedAccountIDs") ?? []
        let interval = UserDefaults.standard.double(forKey: "mailImportInterval")
        importIntervalSeconds = interval > 0 ? interval : 600
        let days = UserDefaults.standard.integer(forKey: "mailLookbackDays")
        lookbackDays = days > 0 ? days : 30
        if let data = UserDefaults.standard.data(forKey: "mailFilterRules"),
           let rules = try? JSONDecoder().decode([MailFilterRule].self, from: data) {
            filterRules = rules
        }
    }

    // MARK: - Settings Setters

    func setMailEnabled(_ value: Bool) {
        mailEnabled = value
        UserDefaults.standard.set(value, forKey: "mailImportEnabled")
    }

    func setSelectedAccountIDs(_ value: [String]) {
        selectedAccountIDs = value
        UserDefaults.standard.set(value, forKey: "mailSelectedAccountIDs")
    }

    func setImportInterval(_ value: TimeInterval) {
        importIntervalSeconds = value
        UserDefaults.standard.set(value, forKey: "mailImportInterval")
    }

    func setLookbackDays(_ value: Int) {
        lookbackDays = value
        UserDefaults.standard.set(value, forKey: "mailLookbackDays")
    }

    func setFilterRules(_ value: [MailFilterRule]) {
        filterRules = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "mailFilterRules")
        }
    }

    // MARK: - Public API

    var isConfigured: Bool {
        !selectedAccountIDs.isEmpty
    }

    /// Load available accounts from Mail.app.
    func loadAccounts() async {
        availableAccounts = await mailService.fetchAccounts()
    }

    func startAutoImport() {
        guard mailEnabled, isConfigured else { return }
        Task { await importNow() }
    }

    func importNow() async {
        importTask?.cancel()
        importTask = Task { await performImport() }
        await importTask?.value
    }

    /// Check if Mail.app is accessible. Returns nil on success.
    func checkMailAccess() async -> String? {
        await mailService.checkAccess()
    }

    // MARK: - Private

    private func performImport() async {
        guard isConfigured else {
            lastError = "No Mail accounts selected"
            return
        }

        if let last = lastImportTime, Date().timeIntervalSince(last) < importIntervalSeconds {
            return
        }

        importStatus = .importing
        lastError = nil

        do {
            let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()

            // 1. Fetch emails from Mail.app
            let emails = try await mailService.fetchEmails(
                accountIDs: selectedAccountIDs, since: since, filterRules: filterRules
            )

            // 2. Analyze each email with on-device LLM
            var analyzedEmails: [(EmailDTO, EmailAnalysisDTO?)] = []
            for email in emails {
                do {
                    let analysis = try await analysisService.analyzeEmail(
                        subject: email.subject,
                        body: email.bodyPlainText,
                        senderName: email.senderName
                    )
                    analyzedEmails.append((email, analysis))
                } catch {
                    logger.warning("Analysis failed for email \(email.messageID): \(error)")
                    analyzedEmails.append((email, nil))
                }
            }

            // 3. Upsert into EvidenceRepository
            try evidenceRepository.bulkUpsertEmails(analyzedEmails)

            // 4. Trigger insights
            InsightGenerator.shared.startAutoGeneration()

            // 5. Prune orphaned mail evidence (only if we got results)
            if !emails.isEmpty {
                let validUIDs = Set(emails.map { $0.sourceUID })
                try evidenceRepository.pruneMailOrphans(validSourceUIDs: validUIDs)
            }

            lastImportedAt = Date()
            lastImportTime = Date()
            lastImportCount = emails.count
            importStatus = .success

            logger.info("Mail import complete: \(emails.count) emails")

        } catch {
            lastError = error.localizedDescription
            importStatus = .failed
            logger.error("Mail import failed: \(error)")
        }
    }

    enum ImportStatus: Equatable {
        case idle, importing, success, failed
    }
}
