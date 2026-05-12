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

final class SAMAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private let log = Logger(subsystem: "com.matthewsessions.SAM", category: "AppDelegate")

    /// Fires every 30 s to flush any pending main-context changes that slipped past
    /// an explicit repository save (e.g., SwiftUI bindings, environment mutations).
    private var periodicSaveTimer: Timer?

    /// Disable all menu items when the app is locked (except Quit, Hide, Minimize).
    @MainActor
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        AppLockService.shared.validateMenuItem(menuItem)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // In Safe Mode, skip all normal startup — no data layer, no coordinators
        if NSEvent.modifierFlags.contains(.option)
            && !UserDefaults.standard.bool(forKey: "sam.safeMode.justCompleted") {
            return
        }

        SystemNotificationService.shared.configure()

        // § Main-actor responsiveness watchdog (Phase 1a). Starts before any
        // heavy launch work so the first 15 minutes — when beachballs are
        // most common — are covered. Skipped in Safe Mode (above guard).
        HangWatchdog.shared.start()

        // Register global clipboard capture hotkey if enabled + Accessibility granted
        if UserDefaults.standard.bool(forKey: GlobalHotkeyService.enabledKey),
           GlobalHotkeyService.shared.checkAccessibilityPermission() {
            GlobalHotkeyService.shared.registerHotkey()
        }

        // Start event reminder scheduler
        EventCoordinator.shared.startReminderScheduler()

        // § Window-close save — macOS does NOT autosave on ⌘W.
        // Flush the main context whenever any app window closes so edits
        // made via @Environment(\.modelContext) are never silently discarded.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                try? SAMModelContainer.shared.mainContext.save()
            }
        }

        // § Periodic save safety net — every 30 s flush any pending main-context
        // changes.  Repositories save explicitly on every write, but this covers
        // edge-cases where mutations reach the environment context directly.
        periodicSaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                let ctx = SAMModelContainer.shared.mainContext
                guard ctx.hasChanges else { return }
                try? ctx.save()
            }
        }
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // In Safe Mode the data layer was never initialized — just terminate.
        guard periodicSaveTimer != nil else { return .terminateNow }

        // If the user clicks Quit again while we're already waiting, just
        // keep waiting — don't fire a second settle/teardown pass that
        // would race with the in-flight one.
        if ShutdownCoordinator.shared.isShuttingDown {
            log.info("App termination requested but graceful-quit wait already in progress — continuing wait")
            return .terminateLater
        }

        // If background AI work is in flight (outcome generation, strategic
        // digest, role deduction, briefing refresh, or any active import),
        // block quit and surface the BlockingActivityOverlay until they
        // settle. Forcing teardown while these are mid-call has previously
        // crashed on dropped MLX containers and partially-saved SwiftData.
        if BackgroundWorkProbe.isAnyBusy {
            log.info("App termination requested but background work is busy — entering graceful-quit wait")
            ShutdownCoordinator.shared.isShuttingDown = true
            Task { @MainActor in
                _ = await ShutdownCoordinator.shared.settle()
                self.performShutdownTeardown()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        performShutdownTeardown()
        return .terminateNow
    }

    /// Cancel timers, stop coordinators, flush SwiftData, and tear down the
    /// MLX runtime. Shared between the immediate quit path and the deferred
    /// `.terminateLater` path so both routes drain through identical cleanup.
    @MainActor
    private func performShutdownTeardown() {
        log.info("App termination — running shutdown teardown")
        CrashReportService.shared.markCleanShutdown()
        HangWatchdog.shared.stop()
        periodicSaveTimer?.invalidate()
        periodicSaveTimer = nil
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
        // Flush any pending SwiftData changes before exit. macOS does NOT
        // automatically trigger autosave on quit, so unsaved mutations
        // from the main context would be silently lost without this call.
        try? SAMModelContainer.shared.mainContext.save()
        // Open the MLX circuit breaker and drop the model container so any
        // in-flight generation stream exhausts before the process exits.
        Task { await AIService.shared.prepareForTermination() }
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
    @State private var shutdownCoordinator = ShutdownCoordinator.shared
    @State private var showImportFilePicker = false
    @State private var showImportConfirmation = false
    @State private var pendingImportURL: URL?
    @State private var pendingImportPreview: ImportPreview?

    // Social imports run in standalone Window scenes — see openWindow calls
    // posted from File menu and from import coordinators (Phase 2 of modal
    // arbiter rewrite). No @State sheets here.

    // Backup passphrase
    @State private var showPassphraseSheet = false
    @State private var backupPassphrase = ""
    @State private var pendingBackupURL: URL?
    @State private var showImportPassphraseSheet = false
    @State private var importPassphrase = ""

    // Debug menu
    @State private var showClearDataConfirmation = false

    // Safe Mode — activated by holding Option key during launch
    @State private var safeModeActive: Bool

    // MARK: - Lifecycle

    /// True when launched as a test host (XCTest / Swift Testing).
    private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        // Initialize showOnboarding FIRST before any other operations
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        _showOnboarding = State(initialValue: !hasCompletedOnboarding)

        // Safe Mode: hold Option key during launch to enter safe mode.
        // Skip if we just completed a safe mode session (prevents re-entry
        // if Option is still held when the app relaunches).
        if UserDefaults.standard.bool(forKey: "sam.safeMode.justCompleted") {
            UserDefaults.standard.removeObject(forKey: "sam.safeMode.justCompleted")
            _safeModeActive = State(initialValue: false)
        } else {
            let optionHeld = NSEvent.modifierFlags.contains(.option)
            _safeModeActive = State(initialValue: optionHeld)
            if optionHeld {
                logger.notice("Option key held at launch — entering Safe Mode")
            }
        }

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

        // Safe Mode: skip all data layer initialization — SafeModeView handles
        // raw SQLite checks before SwiftData ever opens the store.
        if NSEvent.modifierFlags.contains(.option)
            && !UserDefaults.standard.bool(forKey: "sam.safeMode.justCompleted") {
            logger.notice("Safe Mode — skipping data layer configuration")
            return
        }

        // Crash detection: check if previous session exited cleanly,
        // and scan for .ips crash reports if not.
        CrashReportService.shared.markLaunchAndCheckPreviousCrash()

        // Crash guard: if the app crashed within 10 seconds of last launch,
        // reset sidebar to "today" to avoid crash loops from corrupted data
        // in a specific section (e.g., Events with corrupted SwiftData relationships).
        let lastLaunch = UserDefaults.standard.double(forKey: "sam.lastLaunchTimestamp")
        let now = Date.now.timeIntervalSince1970
        if lastLaunch > 0 && (now - lastLaunch) < 10 {
            let currentSidebar = UserDefaults.standard.string(forKey: "sam.sidebar.selection") ?? "today"
            if currentSidebar != "today" {
                logger.warning("Crash loop detected — resetting sidebar from '\(currentSidebar, privacy: .public)' to 'today'")
                UserDefaults.standard.set("today", forKey: "sam.sidebar.selection")
            }
        }
        UserDefaults.standard.set(now, forKey: "sam.lastLaunchTimestamp")

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

    @ViewBuilder
    private var mainContent: some View {
        if safeModeActive {
            SafeModeView()
        } else if isBlockingActivity {
            // Render the overlay INSTEAD OF AppShellView so the entire view
            // tree tears down for the duration. Otherwise @Query observers
            // keep firing during a restore wipe and crash on deleted models.
            BlockingActivityOverlay()
        } else {
            AppShellView()
                .modelContainer(SAMModelContainer.shared)
        }
    }

    private var isBlockingActivity: Bool {
        if case .importing = backupCoordinator.status { return true }
        if shutdownCoordinator.isShuttingDown { return true }
        return false
    }

    var body: some Scene {
        WindowGroup {
            mainContent
                .environment(\.samTextScale, SAMTextSize(rawValue: textSizeRawValue)?.scale ?? 1.0)
                .managedSheet(
                    isPresented: $showOnboarding,
                    priority: .critical,
                    identifier: "app.onboarding"
                ) {
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
                        .dismissOnLock(isPresented: $showImportFilePicker)
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
                        .dismissOnLock(isPresented: $showImportConfirmation)
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
                    let perf = PerformanceMonitor.shared

                    // Configure app lock on launch
                    perf.measureSync("Launch.task.configureLockService") {
                        lockService.configureOnLaunch()
                    }

                    // Check permissions ONCE on first launch
                    // This runs before user interaction, preventing the race condition
                    // where users could click on people before permissions are verified
                    guard !hasCheckedPermissions else { return }
                    await perf.measure("Launch.task.checkPermissionsAndSetup") {
                        await checkPermissionsAndSetup()
                    }
                    hasCheckedPermissions = true

                    // Briefing generation is deferred until after imports complete
                    // (triggered by PostImportOrchestrator). This ensures calendar
                    // events are available when the briefing is built. If no imports
                    // run (e.g. no sources enabled), generate the briefing now.
                    if !UserDefaults.standard.bool(forKey: "sam.contacts.enabled")
                        && !UserDefaults.standard.bool(forKey: "calendarAutoImportEnabled") {
                        if DailyBriefingCoordinator.shared.morningBriefing == nil {
                            await perf.measure("Launch.task.briefingFirstOpenOfDay") {
                                await DailyBriefingCoordinator.shared.checkFirstOpenOfDay()
                            }
                        }
                    }

                    // Tell the system about our App Shortcuts so Siri/Spotlight can surface them.
                    // Runs in background — the AppleEvent can timeout and block main thread.
                    Task.detached(priority: .utility) {
                        SAMShortcutsProvider.updateAppShortcutParameters()
                    }

                    // Load pairing state (macDeviceID + token from Keychain, whitelist
                    // from UserDefaults) before the listener starts accepting connections.
                    await perf.measure("Launch.task.devicePairingBootstrap") {
                        await DevicePairingService.shared.bootstrap()
                    }

                    // Start the always-on transcription listener so the iPhone can
                    // connect and record without needing the user to click Start on Mac.
                    // Safe to call even if this runs before onboarding completes —
                    // startListening() is idempotent.
                    perf.measureSync("Launch.task.transcriptionConfigure") {
                        TranscriptionSessionCoordinator.shared.configure(container: SAMModelContainer.shared)
                    }
                    perf.measureSync("Launch.task.transcriptionStartListening") {
                        TranscriptionSessionCoordinator.shared.startListening()
                    }

                    // Run the audio retention pass on launch in the background.
                    // Looks for sessions signed off >30d ago (configurable) and
                    // purges their WAV files to free disk + reduce privacy
                    // surface. Polished text + summary + linked note remain.
                    Task(priority: .utility) {
                        await RetentionService.shared.runOnce(container: SAMModelContainer.shared)
                    }

                    // If the selected MLX model isn't on disk (e.g. user
                    // onboarded before Qwen became the default, or skipped
                    // the onboarding download), pull it down quietly in the
                    // background so narrative generation stops silently
                    // falling back to FoundationModels on every call.
                    Task(priority: .utility) {
                        let mgr = MLXModelManager.shared
                        let ready = await mgr.isSelectedModelReady()
                        let downloading = await mgr.isDownloading
                        guard !ready, !downloading,
                              let id = await mgr.selectedModelID else { return }
                        do {
                            try await mgr.downloadModel(id: id)
                        } catch {
                            // Non-fatal — narrative paths will keep falling
                            // back to FoundationModels. Settings surfaces
                            // the state so the user can retry.
                        }
                    }

                    #if DEBUG
                    // Start the test inbox watcher so the dev cycle can drive
                    // pipeline tests via Bash without needing the iPhone or
                    // a microphone. See TESTING.md for the workflow.
                    TestInboxWatcher.shared.configure(container: SAMModelContainer.shared)
                    TestInboxWatcher.shared.start()
                    #endif
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
                .dismissOnLock(isPresented: $showImportFilePicker)
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
                .dismissOnLock(isPresented: $showImportConfirmation)
                .alert("Clear All Data?", isPresented: $showClearDataConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear Data", role: .destructive) {
                        clearAllData()
                    }
                } message: {
                    Text("This will delete all people, notes, evidence, and settings, then quit the app. On relaunch you will go through onboarding again.")
                }
                .dismissOnLock(isPresented: $showClearDataConfirmation)
                .managedSheet(
                    isPresented: $showPassphraseSheet,
                    priority: .userInitiated,
                    identifier: "backup.export-passphrase"
                ) {
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
                .managedSheet(
                    isPresented: $showImportPassphraseSheet,
                    priority: .userInitiated,
                    identifier: "backup.import-passphrase"
                ) {
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
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    lockService.appDidResignActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    lockService.appDidBecomeActive()
                }
                .observeForLock()
        }
        .defaultSize(Self.mainWindowSize)

        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SAM") {
                    let buildDateString: String = {
                        guard let execURL = Bundle.main.executableURL,
                              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
                              let date = attrs[.modificationDate] as? Date else {
                            return "Unknown"
                        }
                        let fmt = DateFormatter()
                        fmt.dateStyle = .medium
                        fmt.timeStyle = .short
                        return fmt.string(from: date)
                    }()
                    let credits = NSAttributedString(
                        string: "Built: \(buildDateString)",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: credits
                    ])
                }
            }

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
                    NotificationCenter.default.post(name: .samShowSubstackImportWindow, object: nil)
                }

                Button("Import LinkedIn...") {
                    NotificationCenter.default.post(name: .samShowLinkedInImportWindow, object: nil)
                }

                Button("Import Facebook...") {
                    NotificationCenter.default.post(name: .samShowFacebookImportWindow, object: nil)
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

                Button("Re-scan Mail (reset watermark)") {
                    MailImportCoordinator.shared.resetWatermark()
                    MailImportCoordinator.shared.startImport()
                    logger.notice("Mail watermark reset + import triggered via Debug menu")
                }
                .disabled(!MailImportCoordinator.shared.mailEnabled || !MailImportCoordinator.shared.isConfigured)

                Button("Re-scan iMessage & Calls (reset watermark)") {
                    CommunicationsImportCoordinator.shared.resetWatermarks()
                    CommunicationsImportCoordinator.shared.startImport()
                    logger.notice("Comms watermarks reset + import triggered via Debug menu")
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

                Button("Compare Content Topic Models") {
                    Task {
                        let results = await ContentTopicModelComparison.shared.runComparison()
                        for result in results {
                            if let error = result.error {
                                logger.notice("[\(result.backend)] ERROR: \(error)")
                            } else {
                                logger.notice("[\(result.backend)] \(result.topicCount) topics in \(String(format: "%.1f", result.durationSeconds))s")
                            }
                        }
                    }
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
                    .observeForLock()
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
                    .observeForLock()
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
                    .observeForLock()
            }
        }
        .defaultSize(width: 540, height: 400)
        .windowResizability(.contentSize)
        .commandsRemoved()

        #if os(macOS)
        Settings {
            SettingsView()
                .modelContainer(SAMModelContainer.shared)
                .observeForLock()
        }

        Window("Prompt Lab", id: "prompt-lab") {
            PromptLabView()
                .observeForLock()
        }
        .defaultSize(width: 1200, height: 700)

        Window("SAM Guide", id: "guide") {
            GuideWindowView()
                .observeForLock()
        }
        .defaultSize(width: 700, height: 550)

        // Social imports as standalone windows — they no longer present as
        // sheets on the main window, so an incoming post-call capture (or
        // any other sheet) can't dismiss them mid-review.
        Window("Import LinkedIn", id: "import-linkedin") {
            LinkedInImportSheet()
                .modelContainer(SAMModelContainer.shared)
                .observeForLock()
        }
        .defaultSize(width: 720, height: 560)

        Window("Import Facebook", id: "import-facebook") {
            FacebookImportSheet()
                .modelContainer(SAMModelContainer.shared)
                .observeForLock()
        }
        .defaultSize(width: 720, height: 560)

        Window("Import Substack", id: "import-substack") {
            SubstackImportSheet()
                .modelContainer(SAMModelContainer.shared)
                .observeForLock()
        }
        .defaultSize(width: 720, height: 560)

        Window("Import Evernote", id: "import-evernote") {
            EvernoteImportWindowContent()
                .modelContainer(SAMModelContainer.shared)
                .observeForLock()
        }
        .defaultSize(width: 720, height: 560)
        #endif
    }
    
    private func importEvernoteNotes() async {
        let coordinator = EvernoteImportCoordinator.shared
        guard let folderURL = coordinator.pickEvernoteFolder() else { return }
        await coordinator.loadDirectory(url: folderURL)
        // Evernote uses previewing status (not awaitingReview) — open the standalone window
        if coordinator.importStatus == .previewing {
            NotificationCenter.default.post(name: .samShowEvernoteImportWindow, object: nil)
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
        // The first touch of `SAMModelContainer.shared` opens the SwiftData
        // store on the main actor — measured separately so a slow open is
        // attributed to "container open" rather than "configure repositories".
        let perf = PerformanceMonitor.shared
        let c: ModelContainer = perf.measureSync("Launch.openSAMModelContainer") {
            container ?? SAMModelContainer.shared
        }

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
        CommitmentRepository.shared.configure(container: c)
        TripRepository.shared.configure(container: c)
        TripIngestCoordinator.shared.configure(container: c)
        SphereRepository.shared.configure(container: c)
        TrajectoryRepository.shared.configure(container: c)
        PersonTrajectoryRepository.shared.configure(container: c)

        // One-time migration: isArchived → lifecycleStatusRawValue (v31→v32)
        perf.measureSync("Launch.runMigrationV32IfNeeded") {
            SAMModelContainer.runMigrationV32IfNeeded()
        }

        // One-time migration: backfill directionRaw on existing evidence
        perf.measureSync("Launch.runDirectionBackfillIfNeeded") {
            SAMModelContainer.runDirectionBackfillIfNeeded()
        }

        // Bundled-outcome repository + one-time legacy SamOutcome wipe.
        // Wipe runs AFTER the repository is configured so the dismissal
        // preservation pass has a context to write into. The next
        // OutcomeEngine pass repopulates the queue via OutcomeBundles.
        OutcomeBundleRepository.shared.configure(container: c)
        WeeklyBundleRatingRepository.shared.configure(container: c)
        perf.measureSync("Launch.runOutcomeBundleWipeIfNeeded") {
            SAMModelContainer.runOutcomeBundleWipeIfNeeded()
        }

        // Defer heavy database maintenance to background — these were
        // blocking the main actor during startup and causing beachball.
        // EventRepository.repairIntegrity() has N+1 fetch patterns that
        // scale with data size (events × populations × people).
        Task(priority: .utility) {
            let perf = PerformanceMonitor.shared
            await perf.measure("Launch.eventRepairIntegrity") {
                EventRepository.shared.repairIntegrity()
            }
            await perf.measure("Launch.backfillPersonNameCache") {
                EventRepository.shared.backfillPersonNameCache()
            }
            await perf.measure("Launch.pruneComplianceAudits") {
                let retentionDays = UserDefaults.standard.object(forKey: "complianceAuditRetentionDays") as? Int ?? 90
                try? ComplianceAuditRepository.shared.pruneExpired(retentionDays: retentionDays)
            }
            await perf.measure("Launch.sphereBootstrap") {
                await SphereBootstrapCoordinator.runIfNeeded()
            }
            // Phase 4: retroactively open a Stewardship arc for every person
            // already sitting at a Funnel-terminal stage. Idempotent — guarded
            // by its own UserDefaults flag.
            await perf.measure("Launch.stewardshipBackfill") {
                await StewardshipSpawnService.runBackfillIfNeeded()
            }
            // One-time back-fill of rawPhone hints on iMessage / call / WA
            // evidence imported before phone hints were stored. Reads source
            // SQLite DBs by sourceUID; idempotent — guarded by a UserDefaults flag.
            await perf.measure("Launch.handleHintBackfill") {
                await Self.runHandleHintBackfillIfNeeded()
            }
        }
    }

    private static let handleHintBackfillKey = "handleHintBackfillDone_v1"

    @MainActor
    private static func runHandleHintBackfillIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: handleHintBackfillKey) else { return }
        do {
            let updated = try await EvidenceRepository.shared.backfillHandleHints(
                bookmarkManager: BookmarkManager.shared
            )
            UserDefaults.standard.set(true, forKey: handleHintBackfillKey)
            Logger(subsystem: "com.matthewsessions.SAM", category: "SAMApp")
                .notice("Handle-hint back-fill complete — updated \(updated) evidence items")
        } catch {
            Logger(subsystem: "com.matthewsessions.SAM", category: "SAMApp")
                .error("Handle-hint back-fill failed: \(error.localizedDescription)")
        }
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
        await Self.triggerImportsForEnabledSources()
    }
    
    /// Check if permissions that should be granted (based on settings) are actually missing
    /// Returns true if onboarding should be reset due to lost permissions
    private func checkIfPermissionsLost() async -> Bool {
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
            await Self.triggerImportsForEnabledSources()
        }
    }

    /// Re-run the launch-time import + deferred work after a backup restore.
    /// Mirrors what `checkPermissionsAndSetup → triggerImportsForEnabledSources`
    /// does at app launch, but without the onboarding/permission gate (a restore
    /// only completes when the app is already past onboarding).
    @MainActor
    static func runPostRestoreStartup() {
        logger.info("Post-restore: re-running startup imports + deferred work")
        Task { @MainActor in
            await triggerImportsForEnabledSources()
        }
    }

    /// Shared function to trigger imports based on which sources are enabled.
    /// Contacts must run first (other sources depend on known people),
    /// then remaining imports fire concurrently and are non-blocking — the
    /// app can terminate at any time without waiting for them to finish.
    @MainActor
    static func triggerImportsForEnabledSources() async {
        // Never run real imports while Harvey Snodgrass test data is active —
        // real contacts would overwrite the seed dataset.
        // Briefing + outcome generation still run (they only read existing data).
        #if DEBUG
        if UserDefaults.standard.isTestDataLoaded || UserDefaults.standard.isTestDataActive {
            logger.notice("triggerImportsForEnabledSources: skipping imports — test data is active")

            // Prune + generate outcomes and briefing even with test data.
            // Heavy generation work is deferred so first paint completes
            // before the engine starts iterating the entire dataset.
            try? OutcomeRepository.shared.pruneExpired()
            try? OutcomeRepository.shared.purgeOld()

            let autoGenerateOutcomes = UserDefaults.standard.object(forKey: "outcomeAutoGenerate") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "outcomeAutoGenerate")
            scheduleDeferredLaunchWork(autoGenerateOutcomes: autoGenerateOutcomes, runPipelineBackfill: false)
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

        if !contactsEnabled && !calendarEnabled && !mailEnabled && !commsMessagesEnabled && !commsCallsEnabled {
            logger.info("No sources enabled — app running in limited mode")
            return
        }

        // Contacts first — other sources resolve people by known emails/phones.
        // Uses startImport() (non-blocking) instead of await importNow()
        // which was blocking the main actor for the full 256-contact upsert.
        // Calendar import defers automatically if contacts import is in progress.
        if contactsEnabled {
            Task { await ContactsImportCoordinator.shared.importNow() }
        }
        if calendarEnabled {
            CalendarImportCoordinator.shared.startImport()
        }
        if mailEnabled {
            MailImportCoordinator.shared.startImport()
        }
        if commsMessagesEnabled || commsCallsEnabled {
            CommunicationsImportCoordinator.shared.startImport()
        }

        // Outcome / undo pruning is deferred along with the rest of the
        // launch-time generation work — they each fetch every row of their
        // table on the main actor, and the user does not need yesterday's
        // expired outcomes marked the instant the app opens.

        let autoGenerateOutcomes = UserDefaults.standard.object(forKey: "outcomeAutoGenerate") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "outcomeAutoGenerate")

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

        // Defer outcome engine, briefing, and pipeline backfill until after first
        // paint. Each one walks the entire SwiftData store on @MainActor; running
        // them inline at launch was burning the main thread for minutes on a
        // 14 MB store and causing the app to appear hung. The display side reads
        // outcomeRepo.fetchActive() and the persisted SamDailyBriefing directly,
        // so the UI shows real (if slightly stale) state while these refresh.
        scheduleDeferredLaunchWork(autoGenerateOutcomes: autoGenerateOutcomes, runPipelineBackfill: true)
    }

    /// Run the launch-time generation passes after the UI has had a chance to render.
    /// Held at `.utility` priority and behind a short sleep so first paint completes
    /// before any of these touch the SwiftData store. Each step is a no-op when the
    /// caller's gate (settings, completion flag) says so.
    @MainActor
    private static func scheduleDeferredLaunchWork(autoGenerateOutcomes: Bool, runPipelineBackfill: Bool) {
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(3))

            // Don't pile OutcomeEngine + Briefing + pipeline backfill on top of
            // an in-flight ContactsImport. ContactsImport runs on the main actor
            // and routinely takes 6–8 s; layering the engine on top produced
            // 4-deep main-actor stacks (ContactsImport.performImport ↔
            // OutcomeEngine.generateOutcomes ↔ devicePairingBootstrap) and
            // multi-second beachballs at launch. Wait — yielding — until
            // imports settle, with a hard cap so we never block forever.
            let waitDeadline = Date().addingTimeInterval(30)
            while ContactsImportCoordinator.isImportingContacts && Date() < waitDeadline {
                try? await Task.sleep(for: .milliseconds(250))
            }

            let perf = PerformanceMonitor.shared

            // Pruning and purging used to run inline during launch on the
            // main actor; they fetch every row of their respective tables
            // and were a small but noticeable beachball just before contact
            // import logged "Starting import from group ID..."
            await perf.measure("Launch.deferred.pruneExpiredOutcomes") {
                try? OutcomeRepository.shared.pruneExpired()
            }
            await perf.measure("Launch.deferred.purgeOldOutcomes") {
                try? OutcomeRepository.shared.purgeOld()
            }
            await perf.measure("Launch.deferred.pruneExpiredUndo") {
                try? UndoRepository.shared.pruneExpired()
            }

            if autoGenerateOutcomes {
                await perf.measure("Launch.deferred.startOutcomeGeneration") {
                    OutcomeEngine.shared.startGeneration()
                }
            }

            if runPipelineBackfill, !UserDefaults.standard.bool(forKey: "pipelineBackfillComplete") {
                await perf.measure("Launch.deferred.pipelineBackfill") {
                    do {
                        let allPeople = try PeopleRepository.shared.fetchAll()
                        let count = try PipelineRepository.shared.backfillInitialTransitions(allPeople: allPeople)
                        UserDefaults.standard.set(true, forKey: "pipelineBackfillComplete")
                        logger.debug("Pipeline backfill complete: \(count) transitions created")
                    } catch {
                        logger.error("Pipeline backfill failed: \(error)")
                    }
                }
            }

            await perf.measure("Launch.deferred.briefingFirstOpenOfDay") {
                await DailyBriefingCoordinator.shared.checkFirstOpenOfDay()
            }
        }
    }
}

