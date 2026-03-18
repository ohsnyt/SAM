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
import UniformTypeIdentifiers
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

        // Start event reminder scheduler
        EventCoordinator.shared.startReminderScheduler()
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log.info("App termination requested — cancelling background tasks")
        ContactsImportCoordinator.shared.cancelAll()
        CalendarImportCoordinator.shared.cancelAll()
        MailImportCoordinator.shared.cancelAll()
        CommunicationsImportCoordinator.shared.cancelAll()
        EvernoteImportCoordinator.shared.cancelAll()
        SubstackImportCoordinator.shared.cancelAll()
        LinkedInImportCoordinator.shared.cancelAll()
        FacebookImportCoordinator.shared.cancelAll()
        EventCoordinator.shared.stopReminderScheduler()
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

    // Display
    @AppStorage("sam.display.textSize") private var textSizeRawValue = SAMTextSize.standard.rawValue

    // Security
    @State private var lockService = AppLockService.shared

    // Backup/restore (moved from GeneralSettingsView to File menu)
    @State private var backupCoordinator = BackupCoordinator.shared
    @State private var showImportFilePicker = false
    @State private var showImportConfirmation = false
    @State private var pendingImportURL: URL?
    @State private var pendingImportPreview: ImportPreview?

    // Social import sheets from File menu
    @State private var showLinkedInImportSheet = false
    @State private var showFacebookImportSheet = false
    @State private var showEvernotePreviewSheet = false
    @State private var showSubstackImportSheet = false

    // Backup passphrase
    @State private var showPassphraseSheet = false
    @State private var backupPassphrase = ""
    @State private var pendingBackupURL: URL?
    @State private var showImportPassphraseSheet = false
    @State private var importPassphrase = ""

    // Debug menu
    @State private var showClearDataConfirmation = false

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
            logger.debug("Running as test host — skipping data layer configuration")
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

        // Legacy store detection: if current store is empty and legacy stores exist,
        // set a flag so the Today view can show a migration notice.
        if preImportCount == 0 && LegacyStoreMigrationService.hasLegacyStores() {
            UserDefaults.standard.set(true, forKey: "sam.legacyStores.detected")
            logger.notice("Empty current store + legacy stores detected — migration notice will be shown")
        } else {
            UserDefaults.standard.removeObject(forKey: "sam.legacyStores.detected")
        }

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

    /// Compute a comfortable default window size based on screen dimensions.
    private static var mainWindowSize: CGSize {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width  = max(900, screen.width * 0.6)
        let height = screen.height * 0.7
        return CGSize(width: width, height: height)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppShellView()
                    .modelContainer(SAMModelContainer.shared)

                if lockService.isLocked {
                    AppLockView()
                        .transition(.opacity)
                }
            }
                .environment(\.samTextScale, SAMTextSize(rawValue: textSizeRawValue)?.scale ?? 1.0)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                        .interactiveDismissDisabled() // Prevent accidental dismissal
                        // Users can use "Skip" buttons for each step or "Quit" to exit entirely
                        // This ensures intentional choices rather than accidental dismissal
                        .fileImporter(
                            isPresented: $showImportFilePicker,
                            allowedContentTypes: [.samBackup, .json],
                            allowsMultipleSelection: false
                        ) { result in
                            switch result {
                            case .success(let urls):
                                guard let url = urls.first else { return }
                                Task {
                                    do {
                                        let preview = try await backupCoordinator.validateBackup(from: url)
                                        pendingImportURL = url
                                        pendingImportPreview = preview
                                        showImportConfirmation = true
                                    } catch {
                                        backupCoordinator.status = .failed(error.localizedDescription)
                                    }
                                }
                            case .failure(let error):
                                backupCoordinator.status = .failed(error.localizedDescription)
                            }
                        }
                        .alert("Replace All Data?", isPresented: $showImportConfirmation) {
                            Button("Cancel", role: .cancel) {
                                pendingImportURL = nil
                                pendingImportPreview = nil
                            }
                            Button("Replace All Data", role: .destructive) {
                                guard let url = pendingImportURL else { return }
                                Task {
                                    await backupCoordinator.performImport(from: url)
                                    // After successful restore, dismiss onboarding
                                    if case .success = backupCoordinator.status {
                                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                                        showOnboarding = false
                                    }
                                }
                                pendingImportURL = nil
                                pendingImportPreview = nil
                            }
                        } message: {
                            if let preview = pendingImportPreview {
                                let counts = preview.metadata.counts
                                let schemaNote = preview.schemaMatch ? "" : "\n\nNote: This backup was created with a different schema version (\(preview.metadata.schemaVersion))."
                                Text("This will delete ALL existing data and replace it with:\n\n\(counts.people) people, \(counts.notes) notes, \(counts.evidence) evidence items, \(counts.contexts) contexts\n\nA safety backup will be saved to your temp directory first.\(schemaNote)")
                            }
                        }
                        .onDisappear {
                            // Show intro immediately after onboarding dismisses.
                            // Brief delay so the sheet animation completes first.
                            Task {
                                try? await Task.sleep(for: .milliseconds(600))
                                IntroSequenceCoordinator.shared.checkAndShow()
                            }

                            // Imports run independently at .utility priority so they
                            // don't block the intro sequence.
                            Task(priority: .utility) {
                                await triggerImportsAfterOnboarding()
                            }
                        }
                }
                .task {
                    // Configure app lock on launch
                    lockService.configureOnLaunch()

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
                .fileImporter(
                    isPresented: $showImportFilePicker,
                    allowedContentTypes: [.samBackup, .json],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        Task {
                            do {
                                let preview = try await backupCoordinator.validateBackup(from: url)
                                pendingImportURL = url
                                pendingImportPreview = preview
                                showImportConfirmation = true
                            } catch let error as BackupError where error == .authenticationRequired {
                                // Encrypted backup — ask for passphrase
                                pendingImportURL = url
                                importPassphrase = ""
                                showImportPassphraseSheet = true
                            } catch {
                                backupCoordinator.status = .failed(error.localizedDescription)
                            }
                        }
                    case .failure(let error):
                        backupCoordinator.status = .failed(error.localizedDescription)
                    }
                }
                .alert("Replace All Data?", isPresented: $showImportConfirmation) {
                    Button("Cancel", role: .cancel) {
                        pendingImportURL = nil
                        pendingImportPreview = nil
                    }
                    Button("Replace All Data", role: .destructive) {
                        guard let url = pendingImportURL else { return }
                        let phrase = importPassphrase.isEmpty ? nil : importPassphrase
                        Task {
                            await backupCoordinator.performImport(from: url, passphrase: phrase)
                        }
                        pendingImportURL = nil
                        pendingImportPreview = nil
                        importPassphrase = ""
                    }
                } message: {
                    if let preview = pendingImportPreview {
                        let counts = preview.metadata.counts
                        let schemaNote = preview.schemaMatch ? "" : "\n\nNote: This backup was created with a different schema version (\(preview.metadata.schemaVersion))."
                        Text("This will delete ALL existing data and replace it with:\n\n\(counts.people) people, \(counts.notes) notes, \(counts.evidence) evidence items, \(counts.contexts) contexts\n\nA safety backup will be saved to your temp directory first.\(schemaNote)")
                    }
                }
                .alert("Clear All Data?", isPresented: $showClearDataConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear Data", role: .destructive) {
                        clearAllData()
                    }
                } message: {
                    Text("This will delete all people, notes, evidence, and settings, then quit the app. On relaunch you will go through onboarding again.")
                }
                .sheet(isPresented: $showLinkedInImportSheet) {
                    LinkedInImportSheet()
                }
                .sheet(isPresented: $showFacebookImportSheet) {
                    FacebookImportSheet()
                }
                .sheet(isPresented: $showEvernotePreviewSheet) {
                    EvernoteImportPreviewSheet {
                        showEvernotePreviewSheet = false
                    }
                }
                .sheet(isPresented: $showSubstackImportSheet) {
                    SubstackImportSheet()
                }
                .sheet(isPresented: $showPassphraseSheet) {
                    BackupPassphraseSheet(
                        passphrase: $backupPassphrase,
                        isExport: true
                    ) {
                        showPassphraseSheet = false
                        guard let url = pendingBackupURL else { return }
                        Task {
                            await backupCoordinator.exportBackup(to: url, passphrase: backupPassphrase)
                        }
                        pendingBackupURL = nil
                    } onCancel: {
                        showPassphraseSheet = false
                        pendingBackupURL = nil
                    }
                }
                .sheet(isPresented: $showImportPassphraseSheet) {
                    BackupPassphraseSheet(
                        passphrase: $importPassphrase,
                        isExport: false
                    ) {
                        showImportPassphraseSheet = false
                        guard let url = pendingImportURL else { return }
                        Task {
                            do {
                                let preview = try await backupCoordinator.validateBackup(from: url, passphrase: importPassphrase.isEmpty ? nil : importPassphrase)
                                pendingImportPreview = preview
                                showImportConfirmation = true
                            } catch {
                                backupCoordinator.status = .failed(error.localizedDescription)
                            }
                        }
                    } onCancel: {
                        showImportPassphraseSheet = false
                        pendingImportURL = nil
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .samLinkedInAwaitingReview)) { _ in
                    showLinkedInImportSheet = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .samLinkedInZipDetected)) { _ in
                    showLinkedInImportSheet = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .samFacebookAwaitingReview)) { _ in
                    showFacebookImportSheet = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .samFacebookZipDetected)) { _ in
                    showFacebookImportSheet = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .samSubstackZipDetected)) { _ in
                    showSubstackImportSheet = true
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    lockService.appDidResignActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    lockService.appDidBecomeActive()
                }
        }
        .defaultSize(Self.mainWindowSize)

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

            // File → Import + Backup/Restore
            CommandGroup(replacing: .importExport) {
                Button("Import Substack...") {
                    showSubstackImportSheet = true
                }

                Button("Import LinkedIn...") {
                    showLinkedInImportSheet = true
                }

                Button("Import Facebook...") {
                    showFacebookImportSheet = true
                }

                Button("Import Evernote Notes...") {
                    Task { await importEvernoteNotes() }
                }

                Divider()

                Button("Backup Data...") {
                    Task {
                        // Auth gate for export
                        guard await AppLockService.shared.authenticateForExport() else { return }

                        let panel = NSSavePanel()
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yyyy-MM-dd"
                        panel.nameFieldStringValue = "SAM-Backup-\(formatter.string(from: .now)).sambackup"
                        panel.allowedContentTypes = [.samBackup]
                        panel.canCreateDirectories = true

                        if panel.runModal() == .OK, let url = panel.url {
                            pendingBackupURL = url
                            backupPassphrase = ""
                            showPassphraseSheet = true
                        }
                    }
                }

                Button("Restore Data...") {
                    Task {
                        guard await AppLockService.shared.authenticateForExport() else { return }
                        showImportFilePicker = true
                    }
                }
            }

            #if DEBUG
            CommandMenu("Debug") {
                // Auto-import triggers (normally automatic, here for testing)
                Button("Import Contacts") {
                    Task { await ContactsImportCoordinator.shared.importNow() }
                }
                .disabled(CNContactStore.authorizationStatus(for: .contacts) != .authorized)

                Button("Import Calendar") {
                    CalendarImportCoordinator.shared.startImport()
                }
                .disabled(!UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled"))

                Button("Import Mail") {
                    MailImportCoordinator.shared.startImport()
                }
                .disabled(!MailImportCoordinator.shared.mailEnabled || !MailImportCoordinator.shared.isConfigured)

                Button("Import iMessage & Calls") {
                    CommunicationsImportCoordinator.shared.startImport()
                }
                .disabled(!BookmarkManager.shared.hasMessagesAccess && !BookmarkManager.shared.hasCallHistoryAccess)

                Divider()

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

                Button("Clear All Data") {
                    showClearDataConfirmation = true
                }

                Toggle("Reset on version change", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "autoResetOnVersionChange") },
                    set: { UserDefaults.standard.set($0, forKey: "autoResetOnVersionChange") }
                ))

                Divider()

                if LegacyStoreMigrationService.hasLegacyStores() {
                    Button("Migrate Legacy Data") {
                        Task { await LegacyStoreMigrationService.shared.migrate() }
                    }

                    Button("Clean Up Legacy Files") {
                        LegacyStoreMigrationService.shared.cleanupLegacyStores()
                    }

                    Divider()
                }

                Button("Log Store Info") {
                    let url = SAMModelContainer.shared.configurations.first?.url
                    logger.notice("SwiftData store: \(url?.path(percentEncoded: false) ?? "<in-memory>", privacy: .public)")
                    let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                    logger.notice("Store file exists on disk: \(exists, privacy: .public)")
                    let count = (try? PeopleRepository.shared.count()) ?? -1
                    logger.notice("SamPerson count in store: \(count, privacy: .public)")
                }

                Divider()

                Button("Open Prompt Lab") {
                    NotificationCenter.default.post(name: .samOpenPromptLab, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("Capture Guide Screenshots") {
                    Task { await GuideScreenshotRunner.shared.run() }
                }
                .help("Navigates through app sections and captures screenshots for the Guide help system. Requires test data.")

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

            // Help menu (⌘?)
            CommandGroup(replacing: .help) {
                Button("SAM Guide") {
                    GuideContentService.shared.navigateTo(sectionID: "getting-started")
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                Button("Getting Started") {
                    GuideContentService.shared.navigateTo(sectionID: "getting-started")
                }
                Button("Today & Coaching") {
                    GuideContentService.shared.navigateTo(sectionID: "today")
                }
                Button("People & Relationships") {
                    GuideContentService.shared.navigateTo(sectionID: "people")
                }
                Button("Business Dashboard") {
                    GuideContentService.shared.navigateTo(sectionID: "business")
                }
                Button("Events & Presentations") {
                    GuideContentService.shared.navigateTo(sectionID: "events")
                }
                Button("Grow & Content") {
                    GuideContentService.shared.navigateTo(sectionID: "grow")
                }

                Divider()

                Button("Keyboard Shortcuts") {
                    GuideContentService.shared.navigateTo(articleID: "getting-started.keyboard-shortcuts")
                }
            }
        }

        // Quick Note auxiliary window — opened from outcome cards
        WindowGroup("Quick Note", id: "quick-note", for: QuickNotePayload.self) { $payload in
            if let payload {
                QuickNoteWindowView(payload: payload)
                    .modelContainer(SAMModelContainer.shared)
                    .environment(\.samTextScale, SAMTextSize(rawValue: textSizeRawValue)?.scale ?? 1.0)
            }
        }
        .defaultSize(width: 500, height: 300)
        .windowResizability(.contentSize)
        .commandsRemoved()

        // Clipboard Capture window — opened from ⌃⇧V hotkey or menu command
        WindowGroup("Clipboard Capture", id: "clipboard-capture", for: ClipboardCapturePayload.self) { $payload in
            if let payload {
                ClipboardCaptureWindowView(payload: payload)
                    .modelContainer(SAMModelContainer.shared)
                    .environment(\.samTextScale, SAMTextSize(rawValue: textSizeRawValue)?.scale ?? 1.0)
            }
        }
        .defaultSize(width: 600, height: 500)
        .windowResizability(.contentSize)
        .commandsRemoved()

        // Compose Message window — opened from communicate-lane outcomes
        WindowGroup("Compose", id: "compose-message", for: ComposePayload.self) { $payload in
            if let payload {
                ComposeWindowView(payload: payload)
                    .modelContainer(SAMModelContainer.shared)
                    .environment(\.samTextScale, SAMTextSize(rawValue: textSizeRawValue)?.scale ?? 1.0)
            }
        }
        .defaultSize(width: 540, height: 400)
        .windowResizability(.contentSize)
        .commandsRemoved()

        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(SAMModelContainer.shared)
        }

        Window("Prompt Lab", id: "prompt-lab") {
            PromptLabView()
        }
        .defaultSize(width: 1200, height: 700)

        Window("SAM Guide", id: "guide") {
            GuideWindowView()
        }
        .defaultSize(width: 700, height: 550)
        #endif
    }
    
    private func importEvernoteNotes() async {
        let coordinator = EvernoteImportCoordinator.shared
        guard let folderURL = coordinator.pickEvernoteFolder() else { return }
        await coordinator.loadDirectory(url: folderURL)
        // Evernote uses previewing status (not awaitingReview) — show the preview sheet
        if coordinator.importStatus == .previewing {
            showEvernotePreviewSheet = true
        }
    }

    // MARK: - Clear All Data

    private func clearAllData() {
        ContactsImportCoordinator.shared.cancelAll()
        CalendarImportCoordinator.shared.cancelAll()
        MailImportCoordinator.shared.cancelAll()
        CommunicationsImportCoordinator.shared.cancelAll()
        EvernoteImportCoordinator.shared.cancelAll()

        if let storeURL = SAMModelContainer.shared.configurations.first?.url {
            let fm = FileManager.default
            let companions = [storeURL,
                              storeURL.appendingPathExtension("shm"),
                              storeURL.appendingPathExtension("wal")]
            for url in companions {
                do {
                    if fm.fileExists(atPath: url.path) {
                        try fm.removeItem(at: url)
                        logger.notice("Deleted store file: \(url.lastPathComponent, privacy: .public)")
                    }
                } catch {
                    logger.error("Failed to delete \(url.lastPathComponent, privacy: .public): \(error)")
                }
            }
        } else {
            logger.error("Could not resolve store URL — store files not deleted")
        }

        let keysToRemove = [
            "hasCompletedOnboarding",
            "sam.intro.hasSeenIntroSequence",
            "selectedContactGroupIdentifier",
            "selectedGroupIdentifier",
            "selectedCalendarIdentifier",
            "autoImportContacts",
            "lastContactsImport",
            "lastCalendarImport",
            "sam.contacts.enabled",
            "calendarAutoImportEnabled",
            "mailImportEnabled",
            "commsMessagesEnabled",
            "commsCallsEnabled",
            "pipelineBackfillComplete",
            "outcomeAutoGenerate",
            "sam.contacts.import.lastRunAt",
            "sam.testData.active",
            "sam.testData.loaded",
            "sam.linkedin.enabled",
            "sam.linkedin.messages.lastImportAt",
            "sam.linkedin.connections.lastImportAt",
            "sam.linkedin.emailWatcherActive",
            "sam.linkedin.emailWatcherStartDate",
            "sam.linkedin.fileWatcherActive",
            "sam.linkedin.fileWatcherStartDate",
            "sam.linkedin.extractedDownloadURL",
            "linkedInFolderBookmark",
            "sam.facebook.emailWatcherActive",
            "sam.facebook.emailWatcherStartDate",
            "sam.facebook.fileWatcherActive",
            "sam.facebook.fileWatcherStartDate",
            "sam.facebook.extractedDownloadURL",
        ]
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }

        UserDefaults.standard.set(true, forKey: "sam.tips.pendingReset")

        logger.notice("All SAM data cleared — terminating so fresh state loads on relaunch")
        NSApplication.shared.terminate(nil)
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
        LinkedInImportCoordinator.shared.configure(container: c)
        FacebookImportCoordinator.shared.configure(container: c)
        EventRepository.shared.configure(container: c)
        RoleRecruitingRepository.shared.configure(container: c)
        GoalJournalRepository.shared.configure(container: c)

        // One-time migration: isArchived → lifecycleStatusRawValue (v31→v32)
        SAMModelContainer.runMigrationV32IfNeeded()

        // One-time migration: backfill directionRaw on existing evidence
        SAMModelContainer.runDirectionBackfillIfNeeded()

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
        let mailEnabled = UserDefaults.standard.bool(forKey: "mailImportEnabled")

        // If nothing was ever enabled, don't reset (user might have skipped everything)
        if !contactsEnabled && !calendarEnabled && !mailEnabled {
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

        // Check mail if it was enabled.
        // Prefer direct database access (bookmark) — only fall back to AppleScript check
        // if no bookmark exists. Direct access never triggers privilege violations.
        if mailEnabled {
            if BookmarkManager.shared.hasMailDirAccess {
                // Direct DB access is available — no AppleScript needed
            } else {
                let mailCheck = await MailService.shared.checkAccessDetailed()
                switch mailCheck {
                case .ok:
                    break
                case .permissionDenied(let msg):
                    logger.warning("Mail was enabled but permission is now revoked: \(msg)")
                    permissionsLost = true
                case .transientError(let msg):
                    logger.debug("Mail access check returned transient error (not resetting onboarding): \(msg)")
                }
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
            PostImportOrchestrator.shared.importDidComplete(source: "app-launch")

            // Post-onboarding: create a role review outcome if suggestions were found
            let roleReviewKey = "sam.onboarding.roleReviewCreated"
            if !UserDefaults.standard.bool(forKey: roleReviewKey) {
                try? await Task.sleep(for: .seconds(4))
                let hasSuggestions = RoleDeductionEngine.shared.pendingSuggestions.count > 0
                if hasSuggestions {
                    let outcome = SamOutcome(
                        title: "Review roles SAM suggested for your contacts",
                        rationale: "SAM analyzed your calendar, messages, and contacts to identify likely roles (Client, Lead, Agent, etc.). Review and confirm them in the Relationship Graph.",
                        outcomeKind: .setup,
                        priorityScore: 0.95,
                        sourceInsightSummary: "Post-onboarding role deduction completed with pending suggestions",
                        suggestedNextStep: "Open People → Graph to review role suggestions"
                    )
                    outcome.actionLaneRawValue = ActionLane.reviewGraph.rawValue
                    _ = try? OutcomeRepository.shared.upsert(outcome: outcome)
                    UserDefaults.standard.set(true, forKey: roleReviewKey)
                    logger.debug("Created post-onboarding role review outcome")
                }
            }
        }

        // Pipeline backfill — one-time creation of initial transitions from existing role badges
        if !UserDefaults.standard.bool(forKey: "pipelineBackfillComplete") {
            do {
                let allPeople = try PeopleRepository.shared.fetchAll()
                let count = try PipelineRepository.shared.backfillInitialTransitions(allPeople: allPeople)
                UserDefaults.standard.set(true, forKey: "pipelineBackfillComplete")
                logger.debug("Pipeline backfill complete: \(count) transitions created")
            } catch {
                logger.error("Pipeline backfill failed: \(error)")
            }
        }

        // Daily briefing — check first open after imports complete
        await DailyBriefingCoordinator.shared.checkFirstOpenOfDay()
    }
}

