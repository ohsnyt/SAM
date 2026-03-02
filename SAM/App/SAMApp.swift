//
//  SAMApp.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Clean rebuild - Phase A: Foundation
//

import AppIntents
import SwiftUI
import SwiftData
import Contacts
import EventKit
import TipKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SAMApp")

// MARK: - App Delegate (Termination Handling)

final class SAMAppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.matthewsessions.SAM", category: "AppDelegate")

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        SystemNotificationService.shared.configure()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log.info("App termination requested — cancelling background tasks")
        ContactsImportCoordinator.shared.cancelAll()
        CalendarImportCoordinator.shared.cancelAll()
        MailImportCoordinator.shared.cancelAll()
        CommunicationsImportCoordinator.shared.cancelAll()
        EvernoteImportCoordinator.shared.cancelAll()
        return .terminateNow
    }
}

@main
struct SAMApp: App {

    @NSApplicationDelegateAdaptor(SAMAppDelegate.self) var appDelegate

    // Check onboarding status immediately
    @State private var showOnboarding: Bool
    @State private var hasCheckedPermissions = false

    // MARK: - Lifecycle

    /// True when launched as a test host (XCTest / Swift Testing).
    private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        // Initialize showOnboarding FIRST before any other operations
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        _showOnboarding = State(initialValue: !hasCompletedOnboarding)

        // Skip heavy initialization when running as a test host.
        // Each parallel test runner spawns a full app instance;
        // without this guard, N suites = N concurrent app launches,
        // each triggering imports, LLM inference, and SwiftData I/O
        // — enough to exhaust system resources.
        guard !Self.isTestHost else {
            logger.info("Running as test host — skipping data layer configuration")
            return
        }

        #if DEBUG
        // DEVELOPMENT ONLY: Uncomment the next line to force reset onboarding on every launch
        // UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")

        // Alternative: Use launch argument "-resetOnboarding YES" in your scheme
        if UserDefaults.standard.bool(forKey: "resetOnboarding") {
            logger.notice("Launch argument detected — resetting onboarding")
            UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.set(false, forKey: "sam.contacts.enabled")
            UserDefaults.standard.set(false, forKey: "calendarAutoImportEnabled")
        }
        #endif

        // Configure repositories with shared container
        // Must happen before any data access
        SAMApp.configureDataLayer()

        // Log person count before any import runs — confirms whether store was cleared
        let preImportCount = (try? PeopleRepository.shared.count()) ?? -1
        logger.notice("Pre-import SamPerson count: \(preImportCount, privacy: .public)")

        #if DEBUG
        // Seed Harvey Snodgrass test data if test mode is active and store is empty.
        // This runs synchronously at launch because we need the data present before
        // any views render. The seeder inserts directly into a fresh ModelContext.
        if UserDefaults.standard.isTestDataActive && preImportCount == 0 {
            let seedContext = ModelContext(SAMModelContainer.shared)
            Task { @MainActor in
                await TestDataSeeder.shared.insertData(into: seedContext)
                logger.notice("TestDataSeeder: Harvey Snodgrass dataset inserted")
            }
        }
        #endif

        // If a data clear was performed last session, reset TipKit datastore now —
        // before configure() — so tips reappear fresh. This must happen before
        // configure() because resetDatastore() fails once TipKit is configured.
        if UserDefaults.standard.bool(forKey: "sam.tips.pendingReset") {
            do {
                try Tips.resetDatastore()
                UserDefaults.standard.removeObject(forKey: "sam.tips.pendingReset")
                logger.notice("TipKit datastore reset on launch after data clear")
            } catch {
                logger.error("TipKit pending reset failed: \(error)")
            }
        }

        // Configure TipKit for contextual guidance
        do {
            try Tips.configure([
                .displayFrequency(.immediate)
            ])
        } catch {
            logger.error("TipKit configuration failed: \(error)")
        }

        // Ensure guidance defaults to on if the user has never explicitly turned it off.
        // Guards against resetDatastore() or first-launch scenarios writing false.
        let tipsKey = "sam.tips.guidanceEnabled"
        if UserDefaults.standard.object(forKey: tipsKey) == nil {
            UserDefaults.standard.set(true, forKey: tipsKey)
        }
    }
    
    // MARK: - Scene
    
    var body: some Scene {
        WindowGroup {
            AppShellView()
                .modelContainer(SAMModelContainer.shared)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                        .interactiveDismissDisabled() // Prevent accidental dismissal
                        // Users can use "Skip" buttons for each step or "Quit" to exit entirely
                        // This ensures intentional choices rather than accidental dismissal
                        .onDisappear {
                            // When onboarding completes, trigger imports then show intro.
                            // Imports run at .utility so they don't compete with the intro
                            // sequence, which runs at .userInitiated.
                            Task(priority: .utility) {
                                await triggerImportsAfterOnboarding()
                                // Brief delay so the onboarding sheet fully dismisses
                                // before we present the intro sheet
                                try? await Task.sleep(for: .milliseconds(600))
                                await MainActor.run {
                                    IntroSequenceCoordinator.shared.checkAndShow()
                                }
                            }
                        }
                }
                .task {
                    // Check permissions ONCE on first launch
                    // This runs before user interaction, preventing the race condition
                    // where users could click on people before permissions are verified
                    guard !hasCheckedPermissions else { return }
                    await checkPermissionsAndSetup()
                    hasCheckedPermissions = true

                    // Tell the system about our App Shortcuts so Siri/Spotlight can surface them
                    SAMShortcutsProvider.updateAppShortcutParameters()
                }
        }
        .commands {
            // ⌘K Command Palette + ⌘1–4 sidebar navigation
            CommandGroup(after: .sidebar) {
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .samToggleCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Button("Go to Today") {
                    NotificationCenter.default.post(name: .samNavigateToSection, object: nil, userInfo: ["section": "today"])
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Go to People") {
                    NotificationCenter.default.post(name: .samNavigateToSection, object: nil, userInfo: ["section": "people"])
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Go to Business") {
                    NotificationCenter.default.post(name: .samNavigateToSection, object: nil, userInfo: ["section": "business"])
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Go to Search") {
                    NotificationCenter.default.post(name: .samNavigateToSection, object: nil, userInfo: ["section": "search"])
                }
                .keyboardShortcut("4", modifiers: .command)
            }

            #if DEBUG
            CommandMenu("Debug") {
                Button("Reset Onboarding") {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    UserDefaults.standard.set(false, forKey: "sam.contacts.enabled")
                    UserDefaults.standard.set(false, forKey: "calendarAutoImportEnabled")
                    UserDefaults.standard.set(false, forKey: "mailImportEnabled")
                    UserDefaults.standard.set(false, forKey: "sam.intro.hasSeenIntroSequence")
                    logger.notice("Onboarding + intro reset via Debug menu — terminating")
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Reset Tips") {
                    SAMTipState.resetAllTips()
                    logger.notice("Tips reset via Debug menu")
                }

                Button("Reset Intro") {
                    UserDefaults.standard.set(false, forKey: "sam.intro.hasSeenIntroSequence")
                    logger.notice("Intro reset via Debug menu")
                }

                Divider()

                Button("Log Store Info") {
                    let url = SAMModelContainer.shared.configurations.first?.url
                    logger.notice("SwiftData store: \(url?.path(percentEncoded: false) ?? "<in-memory>", privacy: .public)")
                    let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                    logger.notice("Store file exists on disk: \(exists, privacy: .public)")
                    let count = (try? PeopleRepository.shared.count()) ?? -1
                    logger.notice("SamPerson count in store: \(count, privacy: .public)")
                }

                Divider()

                Button("Seed Harvey Snodgrass Test Data") {
                    Task { await TestDataSeeder.shared.seedFresh() }
                }
                .help("Wipes all data in-process, seeds the Harvey Snodgrass fictional dataset, and disables real imports. No relaunch needed.")

                if UserDefaults.standard.isTestDataActive {
                    Button("Clear Test Data & Re-enable Imports") {
                        UserDefaults.standard.isTestDataActive = false
                        UserDefaults.standard.set(true, forKey: "sam.tips.pendingReset")
                        logger.notice("Test data mode disabled — relaunching")
                        NSApplication.shared.terminate(nil)
                    }
                    .help("Wipes test data, re-enables real imports, and relaunches.")
                }
            }
            #endif
        }

        // Quick Note auxiliary window — opened from outcome cards
        WindowGroup("Quick Note", id: "quick-note", for: QuickNotePayload.self) { $payload in
            if let payload {
                QuickNoteWindowView(payload: payload)
                    .modelContainer(SAMModelContainer.shared)
            }
        }
        .defaultSize(width: 500, height: 300)
        .windowResizability(.contentSize)

        // Compose Message window — opened from communicate-lane outcomes
        WindowGroup("Compose", id: "compose-message", for: ComposePayload.self) { $payload in
            if let payload {
                ComposeWindowView(payload: payload)
                    .modelContainer(SAMModelContainer.shared)
            }
        }
        .defaultSize(width: 540, height: 400)
        .windowResizability(.contentSize)

        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(SAMModelContainer.shared)
        }
        #endif
    }
    
    // MARK: - Configuration
    
    /// Wire all repositories to the given container.
    /// Called at launch and again after an in-process store replacement (e.g. test data seed).
    static func configureDataLayer(container: ModelContainer? = nil) {
        let c = container ?? SAMModelContainer.shared

        // Log the store path so we can verify the correct file is being used/deleted
        let storeURL = c.configurations.first?.url
        logger.notice("SwiftData store: \(storeURL?.path(percentEncoded: false) ?? "<in-memory>", privacy: .public)")

        // Wire repositories to the container
        PeopleRepository.shared.configure(container: c)
        EvidenceRepository.shared.configure(container: c)
        ContextsRepository.shared.configure(container: c)
        NotesRepository.shared.configure(container: c)
        UnknownSenderRepository.shared.configure(container: c)
        InsightGenerator.shared.configure(container: c)
        OutcomeRepository.shared.configure(container: c)
        CoachingAdvisor.shared.configure(container: c)
        DailyBriefingCoordinator.shared.configure(container: c)
        UndoRepository.shared.configure(container: c)
        TimeTrackingRepository.shared.configure(container: c)
        PipelineRepository.shared.configure(container: c)
        ProductionRepository.shared.configure(container: c)
        StrategicCoordinator.shared.configure(container: c)
        ContentPostRepository.shared.configure(container: c)
        GoalRepository.shared.configure(container: c)
        ComplianceAuditRepository.shared.configure(container: c)
        DeducedRelationRepository.shared.configure(container: c)

        // Prune expired compliance audit entries on launch
        let retentionDays = UserDefaults.standard.object(forKey: "complianceAuditRetentionDays") as? Int ?? 90
        try? ComplianceAuditRepository.shared.pruneExpired(retentionDays: retentionDays)
    }
    
    /// Check permissions and decide whether to show onboarding or proceed with imports
    /// This runs once at app launch, before user can interact with the UI
    private func checkPermissionsAndSetup() async {
        // Skip when running as test host
        guard !Self.isTestHost else { return }

        // Check if onboarding was completed
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if !hasCompletedOnboarding {
            return
        }
        
        // Onboarding is marked complete - verify permissions are still valid
        // This handles the case where app was rebuilt and macOS revoked permissions
        let shouldResetOnboarding = await checkIfPermissionsLost()
        
        if shouldResetOnboarding {
            logger.warning("Permissions lost (likely due to rebuild) — resetting onboarding")
            await MainActor.run {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                showOnboarding = true
            }
            return
        }
        
        // Onboarding is marked complete and permissions are valid - trigger imports
        await triggerImportsForEnabledSources()
    }
    
    /// Check if permissions that should be granted (based on settings) are actually missing
    /// Returns true if onboarding should be reset due to lost permissions
    private func checkIfPermissionsLost() async -> Bool {
        // Check if auto-detection is enabled
        let autoDetectEnabled = UserDefaults.standard.bool(forKey: "autoDetectPermissionLoss")
        
        // Default to true if never set (first launch)
        let shouldAutoDetect = UserDefaults.standard.object(forKey: "autoDetectPermissionLoss") == nil ? true : autoDetectEnabled
        
        if !shouldAutoDetect {
            return false
        }

        let contactsEnabled = UserDefaults.standard.bool(forKey: "sam.contacts.enabled")
        let calendarEnabled = UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled")

        // If nothing was ever enabled, don't reset (user might have skipped everything)
        if !contactsEnabled && !calendarEnabled {
            return false
        }
        
        var permissionsLost = false
        
        // Check contacts if it was enabled
        if contactsEnabled {
            let contactsAuth = await ContactsService.shared.authorizationStatus()
            if contactsAuth != .authorized {
                logger.warning("Contacts was enabled but permission is now \(contactsAuth.rawValue)")
                permissionsLost = true
            }
        }
        
        // Check calendar if it was enabled
        if calendarEnabled {
            let calendarAuth = await CalendarService.shared.authorizationStatus()
            if calendarAuth != .fullAccess {


                logger.warning("Calendar was enabled but permission is now \(calendarAuth.rawValue)")
                permissionsLost = true
            }
        }
        
        return permissionsLost
    }
    
    /// Triggers imports after onboarding completes in the same session
    private func triggerImportsAfterOnboarding() async {
        // Check if onboarding was actually completed (not just dismissed via Quit)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if hasCompletedOnboarding {
            logger.info("Onboarding completed — triggering imports")
            await triggerImportsForEnabledSources()
        }
    }
    
    /// Shared function to trigger imports based on which sources are enabled.
    /// Contacts must run first (other sources depend on known people),
    /// then remaining imports fire concurrently and are non-blocking — the
    /// app can terminate at any time without waiting for them to finish.
    private func triggerImportsForEnabledSources() async {
        let contactsEnabled = UserDefaults.standard.bool(forKey: "sam.contacts.enabled")
        let calendarEnabled = UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled")
        let mailEnabled = UserDefaults.standard.bool(forKey: "mailImportEnabled")
        let commsMessagesEnabled = UserDefaults.standard.bool(forKey: "commsMessagesEnabled")
        let commsCallsEnabled = UserDefaults.standard.bool(forKey: "commsCallsEnabled")

        // Contacts first — other sources resolve people by known emails/phones
        if contactsEnabled {
            await ContactsImportCoordinator.shared.importNow()
        }

        if !contactsEnabled && !calendarEnabled && !mailEnabled && !commsMessagesEnabled && !commsCallsEnabled {
            logger.info("No sources enabled — app running in limited mode")
            return
        }

        // Remaining imports fire concurrently, non-blocking.
        // Each coordinator stores its own Task so AppDelegate can cancel on quit.
        if calendarEnabled {
            CalendarImportCoordinator.shared.startImport()
        }
        if mailEnabled {
            MailImportCoordinator.shared.startImport()
        }
        if commsMessagesEnabled || commsCallsEnabled {
            CommunicationsImportCoordinator.shared.startImport()
        }

        // Prune expired outcomes and undo entries (fast, synchronous)
        try? OutcomeRepository.shared.pruneExpired()
        try? OutcomeRepository.shared.purgeOld()
        try? UndoRepository.shared.pruneExpired()

        let autoGenerateOutcomes = UserDefaults.standard.bool(forKey: "outcomeAutoGenerate")
        if autoGenerateOutcomes {
            OutcomeEngine.shared.startGeneration()
        }

        // Pipeline backfill — one-time creation of initial transitions from existing role badges
        if !UserDefaults.standard.bool(forKey: "pipelineBackfillComplete") {
            do {
                let allPeople = try PeopleRepository.shared.fetchAll()
                let count = try PipelineRepository.shared.backfillInitialTransitions(allPeople: allPeople)
                UserDefaults.standard.set(true, forKey: "pipelineBackfillComplete")
                logger.info("Pipeline backfill complete: \(count) transitions created")
            } catch {
                logger.error("Pipeline backfill failed: \(error)")
            }
        }

        // Daily briefing — check first open after imports complete
        await DailyBriefingCoordinator.shared.checkFirstOpenOfDay()
    }
}

