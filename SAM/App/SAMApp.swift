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

        // Register global clipboard capture hotkey if enabled + Accessibility granted
        if UserDefaults.standard.bool(forKey: GlobalHotkeyService.enabledKey),
           GlobalHotkeyService.shared.checkAccessibilityPermission() {
            GlobalHotkeyService.shared.registerHotkey()
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log.info("App termination requested — cancelling background tasks")
        ContactsImportCoordinator.shared.cancelAll()
        CalendarImportCoordinator.shared.cancelAll()
        MailImportCoordinator.shared.cancelAll()
        CommunicationsImportCoordinator.shared.cancelAll()
        EvernoteImportCoordinator.shared.cancelAll()
        GlobalHotkeyService.shared.unregisterHotkey()
        // Open the MLX circuit breaker and drop the model container so any
        // in-flight generation stream exhausts before the process exits.
        Task { await AIService.shared.prepareForTermination() }
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

        // Pending seed wipe: delete store files BEFORE _shared is ever accessed.
        // The seeder set this flag then terminated; now we wipe on the way back up
        // so the lazy _shared initializer creates a completely fresh store.
        // This must run before configureDataLayer() (which touches _shared).
        if UserDefaults.standard.bool(forKey: "sam.seed.pending") {
            let storeURL = SAMModelContainer.defaultStoreURL
            let fm = FileManager.default
            let existsBefore = fm.fileExists(atPath: storeURL.path)
            logger.notice("SAMApp: store file exists before wipe: \(existsBefore, privacy: .public) — \(storeURL.path(percentEncoded: false), privacy: .public)")
            SAMModelContainer.deleteStoreFiles()
            let existsAfter = fm.fileExists(atPath: storeURL.path)
            logger.notice("SAMApp: store file exists after wipe: \(existsAfter, privacy: .public)")
            UserDefaults.standard.removeObject(forKey: "sam.seed.pending")
            logger.notice("SAMApp: store files wiped for pending seed — fresh container will be created")
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
        // isTestDataLoaded is set TRUE here synchronously — before any Task or .task fires —
        // so all import coordinators see the flag immediately and skip real imports.
        //
        // Also re-assert isTestDataLoaded on every subsequent Harvey launch:
        // isTestDataActive is cleared after the first seed, but isTestDataLoaded persists
        // across launches in UserDefaults — so if it's already true we just ensure it stays
        // set before any coordinator init tasks can race against it.
        let testLoaded = UserDefaults.standard.isTestDataLoaded
        let testActive = UserDefaults.standard.isTestDataActive
        logger.notice("DEBUG launch flags — isTestDataLoaded: \(testLoaded, privacy: .public), isTestDataActive: \(testActive, privacy: .public)")
        if testLoaded || testActive {
            UserDefaults.standard.isTestDataLoaded = true   // block imports immediately (re-assert on every Harvey launch)
            logger.notice("SAMApp: Harvey session active — imports blocked for this launch")
        }
        if UserDefaults.standard.isTestDataActive && preImportCount == 0 {
            let seedContext = ModelContext(SAMModelContainer.shared)
            Task { @MainActor in
                await TestDataSeeder.shared.insertData(into: seedContext)
                // Clear the one-shot trigger (loaded flag stays true for the lifetime of the Harvey session)
                UserDefaults.standard.isTestDataActive = false
                logger.notice("TestDataSeeder: Harvey Snodgrass dataset inserted — isTestDataActive cleared")
                let postSeedCount = (try? PeopleRepository.shared.count()) ?? -1
                logger.notice("SAMApp: post-seed SamPerson count: \(postSeedCount, privacy: .public)")
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

                    // Ensure briefing generation runs regardless of onboarding/import state.
                    // checkPermissionsAndSetup may skip triggerImports (e.g. test data, pending
                    // onboarding, lost permissions), but the briefing only reads existing data.
                    if DailyBriefingCoordinator.shared.morningBriefing == nil {
                        await DailyBriefingCoordinator.shared.checkFirstOpenOfDay()
                    }

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

                Button("Go to Grow") {
                    NotificationCenter.default.post(name: .samNavigateToSection, object: nil, userInfo: ["section": "grow"])
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Go to Search") {
                    NotificationCenter.default.post(name: .samNavigateToSection, object: nil, userInfo: ["section": "search"])
                }
                .keyboardShortcut("5", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button("Capture Clipboard Conversation") {
                    NotificationCenter.default.post(name: .samOpenClipboardCapture, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.control, .shift])
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

                if UserDefaults.standard.isTestDataLoaded {
                    Button("Clear Test Data & Re-enable Imports") {
                        UserDefaults.standard.isTestDataLoaded = false
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

        // Clipboard Capture window — opened from ⌃⇧V hotkey or menu command
        WindowGroup("Clipboard Capture", id: "clipboard-capture", for: ClipboardCapturePayload.self) { $payload in
            if let payload {
                ClipboardCaptureWindowView(payload: payload)
                    .modelContainer(SAMModelContainer.shared)
            }
        }
        .defaultSize(width: 600, height: 500)
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
        ContactEnrichmentCoordinator.shared.configure(container: c)
        IntentionalTouchRepository.shared.configure(container: c)
        SubstackImportCoordinator.shared.configure(container: c)

        // One-time migration: isArchived → lifecycleStatusRawValue (v31→v32)
        SAMModelContainer.runMigrationV32IfNeeded()

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
        // Never run real imports while Harvey Snodgrass test data is active —
        // real contacts would overwrite the seed dataset.
        // Briefing + outcome generation still run (they only read existing data).
        #if DEBUG
        if UserDefaults.standard.isTestDataLoaded || UserDefaults.standard.isTestDataActive {
            logger.notice("triggerImportsForEnabledSources: skipping imports — test data is active")

            // Prune + generate outcomes and briefing even with test data
            try? OutcomeRepository.shared.pruneExpired()
            try? OutcomeRepository.shared.purgeOld()

            let autoGenerateOutcomes = UserDefaults.standard.object(forKey: "outcomeAutoGenerate") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "outcomeAutoGenerate")
            if autoGenerateOutcomes {
                OutcomeEngine.shared.startGeneration()
            }

            await DailyBriefingCoordinator.shared.checkFirstOpenOfDay()
            return
        }
        #endif

        let contactsEnabled = UserDefaults.standard.bool(forKey: "sam.contacts.enabled")
        let calendarEnabled = UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled")
        let mailEnabled = MailImportCoordinator.shared.mailEnabled
            && MailImportCoordinator.shared.isConfigured
        // CommunicationsImportCoordinator defaults both to true when unset —
        // mirror that logic here so the launch trigger matches the coordinator.
        let commsMessagesEnabled = UserDefaults.standard.object(forKey: "commsMessagesEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "commsMessagesEnabled")
        let commsCallsEnabled = UserDefaults.standard.object(forKey: "commsCallsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "commsCallsEnabled")

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

        let autoGenerateOutcomes = UserDefaults.standard.object(forKey: "outcomeAutoGenerate") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "outcomeAutoGenerate")
        if autoGenerateOutcomes {
            OutcomeEngine.shared.startGeneration()
        }

        // Role deduction — run after imports settle
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(8))
            await RoleDeductionEngine.shared.deduceRoles()
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

