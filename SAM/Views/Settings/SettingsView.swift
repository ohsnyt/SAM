//
//  SettingsView.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Updated February 24, 2026 - Settings consolidation: 10 tabs → 4
//
//  Settings view with permission management, data source configuration,
//  AI settings, and general app preferences.
//

import SwiftUI
import SwiftData
import EventKit
import Contacts
import TipKit
import UniformTypeIdentifiers
import UserNotifications
import AVFoundation
import Speech
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SettingsView")

struct SettingsView: View {

    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case permissions = "Permissions"
        case dataSources = "Data Sources"
        case ai = "AI & Coaching"
        case business = "Business"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .permissions: return "lock.shield"
            case .dataSources: return "externaldrive"
            case .ai: return "brain"
            case .business: return "briefcase"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
                .tag(SettingsTab.permissions)

            DataSourcesSettingsView()
                .tabItem {
                    Label("Data Sources", systemImage: "externaldrive")
                }
                .tag(SettingsTab.dataSources)

            AISettingsView()
                .tabItem {
                    Label("AI & Coaching", systemImage: "brain")
                }
                .tag(SettingsTab.ai)

            BusinessSettingsView()
                .tabItem {
                    Label("Business", systemImage: "briefcase")
                }
                .tag(SettingsTab.business)
        }
        .frame(width: 650, height: 600)
    }
}

// MARK: - Import Status Dashboard

private struct ImportStatusDashboard: View {

    @State private var contactsCoordinator = ContactsImportCoordinator.shared
    @State private var calendarCoordinator = CalendarImportCoordinator.shared
    @State private var mailCoordinator = MailImportCoordinator.shared
    @State private var commsCoordinator = CommunicationsImportCoordinator.shared
    @State private var substackCoordinator = SubstackImportCoordinator.shared
    @State private var linkedInCoordinator = LinkedInImportCoordinator.shared
    @State private var facebookCoordinator = FacebookImportCoordinator.shared
    @State private var bookmarkManager = BookmarkManager.shared

    var body: some View {
        Section("Import Status") {
            importRow("Contacts", icon: "person.crop.circle",
                      statusText: coordinatorStatusText(contactsCoordinator.importStatus, contactsCoordinator.lastImportedAt),
                      isImporting: isImporting(contactsCoordinator.importStatus)) {
                Task { await contactsCoordinator.importNow() }
            }

            importRow("Calendar", icon: "calendar",
                      statusText: coordinatorStatusText(calendarCoordinator.importStatus, calendarCoordinator.lastImportedAt),
                      isImporting: isImporting(calendarCoordinator.importStatus)) {
                calendarCoordinator.startImport()
            }

            importRow("Mail", icon: "envelope",
                      statusText: mailCoordinator.mailEnabled
                          ? coordinatorStatusText(mailCoordinator.importStatus, mailCoordinator.lastImportedAt)
                          : "Not configured",
                      isImporting: isImporting(mailCoordinator.importStatus)) {
                if mailCoordinator.mailEnabled {
                    mailCoordinator.startImport()
                }
            }

            importRow("iMessage & Calls", icon: "message",
                      statusText: (bookmarkManager.hasMessagesAccess || bookmarkManager.hasCallHistoryAccess)
                          ? coordinatorStatusText(commsCoordinator.importStatus, commsCoordinator.lastImportedAt)
                          : "Not configured",
                      isImporting: isImporting(commsCoordinator.importStatus)) {
                if bookmarkManager.hasMessagesAccess || bookmarkManager.hasCallHistoryAccess {
                    commsCoordinator.startImport()
                }
            }

            importRow("Substack", icon: "newspaper.fill",
                      statusText: substackStatusText,
                      isImporting: isImportingSubstack,
                      canImport: false) { }
                .help("Use File → Import → Substack to configure")

            importRow("LinkedIn", icon: "network",
                      statusText: bookmarkManager.hasLinkedInFolderAccess
                          ? coordinatorStatusText(linkedInCoordinator.importStatus, linkedInCoordinator.lastImportedAt)
                          : "File → Import",
                      isImporting: isImporting(linkedInCoordinator.importStatus),
                      canImport: false) { }
                .help("Use File → Import → LinkedIn to configure")

            importRow("Facebook", icon: "person.2.fill",
                      statusText: bookmarkManager.hasFacebookFolderAccess
                          ? coordinatorStatusText(facebookCoordinator.importStatus, facebookCoordinator.lastImportedAt)
                          : "File → Import",
                      isImporting: isImporting(facebookCoordinator.importStatus),
                      canImport: false) { }
                .help("Use File → Import → Facebook to configure")
        }
    }

    // MARK: - Row Builder

    private func importRow(_ name: String, icon: String, statusText: String,
                           isImporting: Bool, canImport: Bool = true,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(statusText == "Not configured" ? .secondary : .primary)

            Text(name)
                .frame(width: 120, alignment: .leading)

            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Status Helpers

    private func coordinatorStatusText<S: Equatable>(_ status: S, _ lastDate: Date?) -> String {
        if "\(status)".contains("importing") { return "Importing..." }
        if let date = lastDate {
            return "Last: \(date.formatted(.relative(presentation: .named)))"
        }
        return "Ready"
    }

    private func isImporting<S: Equatable>(_ status: S) -> Bool {
        "\(status)".contains("importing")
    }

    private var substackStatusText: String {
        if case .importing = substackCoordinator.importStatus { return "Importing..." }
        let hasFeed = !substackCoordinator.feedURL.isEmpty
        if !hasFeed { return "File \u{2192} Import" }
        if let lastImport = substackCoordinator.lastSubscriberImportDate {
            return "Last: \(lastImport.formatted(.relative(presentation: .named)))"
        }
        return "Ready"
    }

    private var isImportingSubstack: Bool {
        if case .importing = substackCoordinator.importStatus { return true }
        return false
    }
}

// MARK: - Data Sources Settings (consolidated tab)

struct DataSourcesSettingsView: View {

    @State private var globalLookbackDays: Int = {
        UserDefaults.standard.object(forKey: "globalLookbackDays") == nil
            ? 30
            : UserDefaults.standard.integer(forKey: "globalLookbackDays")
    }()

    var body: some View {
        Form {
            ImportStatusDashboard()

            Section {
                // ── Global Lookback Period ──────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("History Lookback Period")
                        .font(.headline)

                    Text("How far back SAM scans when importing from Calendar, Mail, and Communications. Applies to all sources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Look back", selection: $globalLookbackDays) {
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                        Text("180 days").tag(180)
                        Text("All").tag(0)
                    }
                    .onChange(of: globalLookbackDays) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "globalLookbackDays")
                        // Push to each coordinator so they re-read correctly
                        CalendarImportCoordinator.shared.lookbackDays = newValue
                        MailImportCoordinator.shared.setLookbackDays(newValue)
                        CommunicationsImportCoordinator.shared.setLookbackDays(newValue)
                    }

                    if globalLookbackDays == 0 {
                        Text("First import will scan all available history. Subsequent imports use incremental sync.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 6)

                Divider()

                DisclosureGroup {
                    ContactsSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Contacts", systemImage: "person.crop.circle")
                }

                DisclosureGroup {
                    CalendarSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Calendar", systemImage: "calendar")
                }

                DisclosureGroup {
                    MailSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Mail", systemImage: "envelope")
                }

                DisclosureGroup {
                    CommunicationsSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Communications", systemImage: "message.fill")
                }


                // Substack configuration moved to File → Import → Substack sheet
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Settings (consolidated tab)

struct AISettingsView: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                DisclosureGroup {
                    IntelligenceSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Intelligence", systemImage: "brain")
                }

                DisclosureGroup {
                    CoachingSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Coaching", systemImage: "brain.head.profile")
                }

                DisclosureGroup {
                    BriefingSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Briefings", systemImage: "text.book.closed")
                }
            }

            Section {
                Button {
                    openWindow(id: "prompt-lab")
                } label: {
                    HStack {
                        Label("Open Prompt Lab", systemImage: "wand.and.stars")
                        Spacer()
                        Text("Compare and refine AI prompts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Business Settings (new tab)

struct BusinessSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Business", systemImage: "briefcase")
                        .font(.title2).bold()
                    Divider()
                    DisclosureGroup("Business Profile") {
                        BusinessProfileSettingsContent()
                            .padding(.top, 8)
                    }
                    Divider()
                    DisclosureGroup("Compliance") {
                        ComplianceSettingsContent()
                            .padding(.top, 8)
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Guidance & Tips Settings

struct GuidanceSettingsContent: View {

    @AppStorage("sam.tips.guidanceEnabled") private var tipsEnabled: Bool = true
    @AppStorage("sam.guide.showHelpButtons") private var showHelpButtons: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show contextual tips", isOn: Binding(
                get: { tipsEnabled },
                set: { newValue in
                    if newValue {
                        SAMTipState.enableTips()
                        tipsEnabled = true
                    } else {
                        SAMTipState.disableTips()
                        tipsEnabled = false
                    }
                }
            ))

            Text("Contextual tips appear near features to help you learn SAM's interface.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Suggest features you haven't tried", isOn: Binding(
                get: { FeatureAdoptionTracker.shared.isEnabled },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: "sam.coaching.featureAdoptionEnabled")
                }
            ))

            Text("SAM will suggest features over your first weeks to help you get the most out of the app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show help buttons in views", isOn: $showHelpButtons)

            Text("Small \"?\" buttons in toolbars and headers that open the SAM Guide to the relevant article.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Reset All Tips") {
                    SAMTipState.resetAllTips()
                    tipsEnabled = true
                }
                .buttonStyle(.bordered)

                Button("Replay Welcome") {
                    IntroSequenceCoordinator.shared.replay()
                }
                .buttonStyle(.bordered)

                Button("Open SAM Guide") {
                    GuideContentService.shared.navigateTo(sectionID: "getting-started")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Clipboard Capture Settings

struct ClipboardCaptureSettingsContent: View {

    @State private var hotkeyEnabled: Bool = UserDefaults.standard.bool(forKey: GlobalHotkeyService.enabledKey)
    @State private var hotkeyService = GlobalHotkeyService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clipboard Capture")
                .font(.headline)

            Text("Copy a conversation from any app and press ⌃⇧V to capture it as evidence in SAM.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Enable global hotkey (⌃⇧V)", isOn: $hotkeyEnabled)
                .onChange(of: hotkeyEnabled) { _, newValue in
                    hotkeyService.isEnabled = newValue
                    if newValue {
                        if hotkeyService.checkAccessibilityPermission() {
                            hotkeyService.registerHotkey()
                        } else {
                            hotkeyService.promptForAccessibility()
                        }
                    } else {
                        hotkeyService.unregisterHotkey()
                    }
                }

            // Accessibility permission status
            HStack(spacing: 8) {
                Text("Accessibility Permission")
                    .font(.subheadline)

                Spacer()

                if hotkeyService.accessibilityGranted {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Granted")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.orange)
                            Text("Not Granted")
                                .font(.caption)
                                .foregroundStyle(.orange)

                            Button("Open Accessibility Settings") {
                                hotkeyService.promptForAccessibility()
                            }
                            .controlSize(.small)
                        }

                        HStack(spacing: 8) {
                            Button("Reveal App in Finder") {
                                let appURL = Bundle.main.bundleURL
                                NSWorkspace.shared.activateFileViewerSelecting([appURL])
                            }
                            .controlSize(.small)
                        }

                        Text("In the Accessibility list, click + and add the app shown in Finder. When running from Xcode, you may also need to add Xcode itself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if hotkeyService.isRegistered {
                Text("Global hotkey is active — press ⌃⇧V from any app to capture a conversation.")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if hotkeyEnabled && !hotkeyService.accessibilityGranted {
                Text("Grant Accessibility permission, then restart SAM to activate the global hotkey.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("The in-app menu command (Edit → Capture Clipboard Conversation) works without Accessibility permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Permissions Settings (Compact Grid)

struct PermissionsSettingsView: View {

    @State private var contactsStatus: String = "Checking..."
    @State private var calendarStatus: String = "Checking..."
    @State private var notificationsStatus: String = "Checking..."
    @State private var mailStatus: String = "Checking..."
    @State private var microphoneStatus: String = "Checking..."
    @State private var speechStatus: String = "Checking..."

    @State private var isRequestingContacts = false
    @State private var isRequestingCalendar = false
    @State private var isRequestingNotifications = false

    @State private var bookmarkManager = BookmarkManager.shared
    @State private var hotkeyService = GlobalHotkeyService.shared

    @AppStorage("autoDetectPermissionLoss") private var autoDetectPermissionLoss = true

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Permissions", systemImage: "lock.shield")
                            .font(.title2)
                            .bold()
                        Spacer()
                        GuideButton(articleID: "getting-started.settings")
                    }

                    Divider()

                    // Contacts
                    permissionRow(
                        icon: "person.crop.circle.fill", color: .blue, name: "Contacts",
                        status: contactsStatus
                    ) {
                        if contactsStatus != "Authorized" {
                            Button("Request Access") { requestContactsPermission() }
                                .controlSize(.small)
                                .disabled(isRequestingContacts)
                        }
                    }

                    // Calendar
                    permissionRow(
                        icon: "calendar.circle.fill", color: .orange, name: "Calendar",
                        status: calendarStatus
                    ) {
                        if calendarStatus != "Authorized" {
                            Button("Request Access") { requestCalendarPermission() }
                                .controlSize(.small)
                                .disabled(isRequestingCalendar)
                        }
                    }

                    // Mail
                    permissionRow(
                        icon: "envelope.circle.fill", color: .blue, name: "Mail",
                        status: mailStatus
                    ) {
                        if mailStatus != "Authorized" {
                            Button("Check Access") {
                                Task {
                                    if let error = await MailImportCoordinator.shared.checkMailAccess() {
                                        mailStatus = error
                                    } else {
                                        mailStatus = "Authorized"
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    // iMessage
                    permissionRow(
                        icon: "message.fill", color: .green, name: "iMessage",
                        status: bookmarkManager.hasMessagesAccess ? "Authorized" : "Not Configured"
                    ) {
                        if !bookmarkManager.hasMessagesAccess {
                            Text("Grant in Data Sources")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Call History
                    permissionRow(
                        icon: "phone.fill", color: .green, name: "Call History",
                        status: bookmarkManager.hasCallHistoryAccess ? "Authorized" : "Not Configured"
                    ) {
                        if !bookmarkManager.hasCallHistoryAccess {
                            Text("Grant in Data Sources")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Microphone
                    permissionRow(
                        icon: "mic.fill", color: .purple, name: "Microphone",
                        status: microphoneStatus
                    ) {
                        if microphoneStatus != "Authorized" {
                            Button("Open System Settings") { openPrivacySettings() }
                                .controlSize(.small)
                        }
                    }

                    // Speech Recognition
                    permissionRow(
                        icon: "waveform.circle.fill", color: .purple, name: "Speech",
                        status: speechStatus
                    ) {
                        if speechStatus != "Authorized" {
                            Button("Open System Settings") { openPrivacySettings() }
                                .controlSize(.small)
                        }
                    }

                    // Notifications
                    permissionRow(
                        icon: "bell.circle.fill", color: .red, name: "Notifications",
                        status: notificationsStatus
                    ) {
                        if notificationsStatus == "Not Requested" {
                            Button("Request") { requestNotificationsPermission() }
                                .controlSize(.small)
                                .disabled(isRequestingNotifications)
                        }
                    }

                    // Accessibility
                    permissionRow(
                        icon: "accessibility", color: .gray, name: "Accessibility",
                        status: hotkeyService.accessibilityGranted ? "Authorized" : "Not Granted"
                    ) {
                        if !hotkeyService.accessibilityGranted {
                            Button("Open System Settings") {
                                hotkeyService.promptForAccessibility()
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    Toggle("Auto-detect permission loss", isOn: $autoDetectPermissionLoss)

                    Text("Automatically reset onboarding if permissions are revoked (e.g., after rebuilding in Xcode).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .task {
            await checkPermissions()
        }
    }

    // MARK: - Row Builder

    @ViewBuilder
    private func permissionRow<Actions: View>(
        icon: String, color: Color, name: String, status: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 24)

            Text(name)
                .frame(width: 100, alignment: .leading)

            statusBadge(status)

            Spacer()

            actions()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let isGranted = status == "Authorized"
        HStack(spacing: 4) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption)
                .foregroundStyle(isGranted ? .green : .orange)
            Text(status)
                .font(.caption)
                .foregroundStyle(isGranted ? .green : .secondary)
        }
    }

    // MARK: - Permission Checks

    private func checkPermissions() async {
        let contactsAuth = CNContactStore.authorizationStatus(for: .contacts)
        contactsStatus = authStatusString(contactsAuth)

        let calendarAuth = await CalendarService.shared.authorizationStatus()
        calendarStatus = authStatusString(calendarAuth)

        // Mail — try a quick access check
        if MailImportCoordinator.shared.mailEnabled {
            if let error = await MailImportCoordinator.shared.checkMailAccess() {
                mailStatus = error
            } else {
                mailStatus = "Authorized"
            }
        } else {
            mailStatus = "Not Configured"
        }

        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = "Authorized"
        case .denied, .restricted: microphoneStatus = "Denied"
        case .notDetermined: microphoneStatus = "Not Requested"
        @unknown default: microphoneStatus = "Unknown"
        }

        // Speech
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        switch speechAuth {
        case .authorized: speechStatus = "Authorized"
        case .denied, .restricted: speechStatus = "Denied"
        case .notDetermined: speechStatus = "Not Requested"
        @unknown default: speechStatus = "Unknown"
        }

        // Notifications
        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        switch notifSettings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationsStatus = "Authorized"
        case .denied:
            notificationsStatus = "Denied"
        case .notDetermined:
            notificationsStatus = "Not Requested"
        @unknown default:
            notificationsStatus = "Unknown"
        }
    }

    private func authStatusString(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private func authStatusString(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "Authorized"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        case .restricted: return "Restricted"
        case .writeOnly: return "Write Only"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Permission Requests

    private func requestContactsPermission() {
        isRequestingContacts = true
        Task {
            let granted = await ContactsService.shared.requestAuthorization()
            await MainActor.run {
                contactsStatus = granted ? "Authorized" : "Denied"
                isRequestingContacts = false
                if granted {
                    ContactsImportCoordinator.shared.permissionGranted()
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        await ContactsImportCoordinator.shared.importNow()
                    }
                }
            }
        }
    }

    private func requestCalendarPermission() {
        isRequestingCalendar = true
        Task {
            let granted = await CalendarImportCoordinator.shared.requestAuthorization()
            await MainActor.run {
                calendarStatus = granted ? "Authorized" : "Denied"
                isRequestingCalendar = false
                if granted {
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        await CalendarImportCoordinator.shared.importNow()
                    }
                }
            }
        }
    }

    private func requestNotificationsPermission() {
        isRequestingNotifications = true
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await MainActor.run {
                    notificationsStatus = granted ? "Authorized" : "Denied"
                    isRequestingNotifications = false
                }
            } catch {
                await MainActor.run {
                    notificationsStatus = "Denied"
                    isRequestingNotifications = false
                }
            }
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Contacts Settings Content

struct ContactsSettingsContent: View {

    @State private var coordinator = ContactsImportCoordinator.shared
    @AppStorage("sam.contacts.enabled") private var autoImportEnabled: Bool = true
    @AppStorage("selectedContactGroupIdentifier") private var selectedGroupIdentifier: String = ""

    @State private var availableGroups: [ContactGroupDTO] = []
    @State private var isLoadingGroups = false
    @State private var isCreatingGroup = false
    @State private var errorMessage: String?
    @State private var authorizationStatus: CNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Authorization Check
            if authorizationStatus != .authorized {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Authorization Required")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text("Please grant Contacts access in the Permissions tab first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)

                Divider()
            }

            // Group Selection
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Contact Group")
                        .font(.headline)

                    Text("SAM reads all contacts to identify matches and avoid duplicates, but only imports and updates contacts in this group.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if authorizationStatus != .authorized {
                        Text("Contacts access required to load groups.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if isLoadingGroups {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading groups...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !availableGroups.isEmpty {
                        Picker("Group:", selection: $selectedGroupIdentifier) {
                            if !availableGroups.contains(where: { $0.name == "SAM" }) {
                                Text("Create SAM")
                                    .tag("__create_sam__")

                                Divider()
                            }

                            ForEach(availableGroups.sorted(by: { $0.name < $1.name })) { group in
                                Text(group.name)
                                    .tag(group.identifier)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedGroupIdentifier) { _, newValue in
                            handleGroupSelection(newValue)
                            if !newValue.isEmpty && newValue != "__create_sam__" {
                                ContactsImportCoordinator.shared.selectedGroupDidChange()
                            }
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("No contact groups found. Create one in the Contacts app, or click 'Refresh Groups' below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Refresh Groups") {
                            Task {
                                await loadGroups()
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Auto-import toggle
            Toggle("Automatically import contacts", isOn: $autoImportEnabled)

            Text("When enabled, SAM will automatically sync with Contacts when changes are detected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Status
            HStack {
                Text("Import Status:")
                    .foregroundStyle(.secondary)

                Text(coordinator.importStatus.displayText)
                    .bold()

                Spacer()

                if let date = coordinator.lastImportedAt {
                    Text("\(coordinator.lastImportCount) contacts, \(date, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = coordinator.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if coordinator.importStatus == .importing {
                ProgressView()
                    .progressViewStyle(.linear)
            }

        }
        .task {
            await checkAuthAndLoadGroups()
        }
        .onChange(of: authorizationStatus) { _, newStatus in
            if newStatus == .authorized {
                Task {
                    await loadGroups()
                }
            }
        }
    }

    private func checkAuthAndLoadGroups() async {
        let status = await ContactsService.shared.authorizationStatus()

        await MainActor.run {
            authorizationStatus = status
        }

        if status == .authorized {
            await loadGroups()
        }
    }

    private func loadGroups() async {
        isLoadingGroups = true
        errorMessage = nil

        let groups = await ContactsService.shared.fetchGroups()

        await MainActor.run {
            availableGroups = groups
            isLoadingGroups = false

            if selectedGroupIdentifier.isEmpty,
               let samGroup = groups.first(where: { $0.name == "SAM" }) {
                selectedGroupIdentifier = samGroup.identifier
            }
        }
    }

    private func handleGroupSelection(_ newValue: String) {
        if newValue == "__create_sam__" {
            createSAMGroup()
        }
    }

    private func createSAMGroup() {
        isCreatingGroup = true
        errorMessage = nil

        Task {
            let success = await ContactsService.shared.createGroup(named: "SAM")

            await MainActor.run {
                isCreatingGroup = false

                if success {
                    Task {
                        await loadGroups()

                        if let samGroup = availableGroups.first(where: { $0.name == "SAM" }) {
                            selectedGroupIdentifier = samGroup.identifier
                            ContactsImportCoordinator.shared.selectedGroupDidChange()
                        }
                    }
                } else {
                    logger.error("Failed to create SAM contact group")
                    errorMessage = "Failed to create SAM group. Please create it manually in Contacts."
                    selectedGroupIdentifier = ""
                }
            }
        }
    }
}

// MARK: - Contacts Settings (standalone wrapper)

struct ContactsSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Contacts Import", systemImage: "person.crop.circle")
                        .font(.title2)
                        .bold()

                    Divider()

                    ContactsSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Calendar Settings Content

struct CalendarSettingsContent: View {

    @State private var coordinator = CalendarImportCoordinator.shared
    @AppStorage("calendarAutoImportEnabled") private var autoImportEnabled: Bool = true
    @AppStorage("selectedCalendarIdentifier") private var selectedCalendarIdentifier: String = ""

    @State private var availableCalendars: [CalendarDTO] = []
    @State private var isLoadingCalendars = false
    @State private var isCreatingCalendar = false
    @State private var errorMessage: String?
    @State private var authorizationStatus: EKAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Authorization Check
            if authorizationStatus != .fullAccess {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Authorization Required")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Text("Please grant Calendar access in the Permissions tab first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)

                Divider()
            }

            // Calendar Selection
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Calendar")
                        .font(.headline)

                    Text("Select which Calendar SAM should access. Only events from this calendar will be imported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if authorizationStatus != .fullAccess {
                        Text("Calendar access required to load calendars.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if isLoadingCalendars {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading calendars...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !availableCalendars.isEmpty {
                        Picker("Calendar:", selection: $selectedCalendarIdentifier) {
                            if !availableCalendars.contains(where: { $0.title == "SAM" }) {
                                Text("Create SAM")
                                    .tag("__create_sam__")

                                Divider()
                            }

                            ForEach(availableCalendars.sorted(by: { $0.title < $1.title })) { calendar in
                                HStack {
                                    if let color = calendar.color {
                                        Circle()
                                            .fill(Color(
                                                red: color.red,
                                                green: color.green,
                                                blue: color.blue
                                            ))
                                            .frame(width: 10, height: 10)
                                    }
                                    Text(calendar.title)
                                }
                                .tag(calendar.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedCalendarIdentifier) { _, newValue in
                            handleCalendarSelection(newValue)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("No calendars found. Create one in the Calendar app, or click 'Refresh Calendars' below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Refresh Calendars") {
                            Task {
                                await loadCalendars()
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Auto-import toggle
            Toggle("Automatically import calendar events", isOn: $autoImportEnabled)

            Text("When enabled, SAM will automatically sync with Calendar when changes are detected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Status
            HStack {
                Text("Import Status:")
                    .foregroundStyle(.secondary)

                Text(coordinator.importStatus.displayText)
                    .bold()

                Spacer()

                if let lastImport = coordinator.lastImportedAt {
                    Text("Last: \(lastImport, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if coordinator.importStatus == .importing {
                ProgressView()
                    .progressViewStyle(.linear)
            }

        }
        .task {
            await checkAuthAndLoadCalendars()
        }
        .onChange(of: authorizationStatus) { _, newStatus in
            if newStatus == .fullAccess {
                Task {
                    await loadCalendars()
                }
            }
        }
    }

    private func checkAuthAndLoadCalendars() async {
        let status = await CalendarService.shared.authorizationStatus()

        await MainActor.run {
            authorizationStatus = status
        }

        if status == .fullAccess {
            await loadCalendars()
        }
    }

    private func loadCalendars() async {
        isLoadingCalendars = true
        errorMessage = nil

        let calendars = await CalendarService.shared.fetchCalendars()

        await MainActor.run {
            if let calendars = calendars {
                availableCalendars = calendars

                if selectedCalendarIdentifier.isEmpty,
                   let samCalendar = calendars.first(where: { $0.title == "SAM" }) {
                    selectedCalendarIdentifier = samCalendar.id
                }
            }

            isLoadingCalendars = false
        }
    }

    private func handleCalendarSelection(_ newValue: String) {
        if newValue == "__create_sam__" {
            createSAMCalendar()
        }
    }

    private func createSAMCalendar() {
        isCreatingCalendar = true
        errorMessage = nil

        Task {
            let success = await CalendarService.shared.createCalendar(titled: "SAM")

            await MainActor.run {
                isCreatingCalendar = false

                if success {
                    Task {
                        await loadCalendars()

                        if let samCalendar = availableCalendars.first(where: { $0.title == "SAM" }) {
                            selectedCalendarIdentifier = samCalendar.id
                        }
                    }
                } else {
                    logger.error("Failed to create SAM calendar")
                    errorMessage = "Failed to create SAM calendar. Please create it manually in Calendar."
                    selectedCalendarIdentifier = ""
                }
            }
        }
    }
}

// MARK: - Calendar Settings (standalone wrapper)

struct CalendarSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Calendar Import", systemImage: "calendar")
                        .font(.title2)
                        .bold()

                    Divider()

                    CalendarSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Business Profile Settings Content

struct BusinessProfileSettingsContent: View {

    @State private var profile = BusinessProfile()
    @State private var isLoaded = false
    @State private var marketFocusText: String = ""

    // Common market focus options for quick selection
    private let commonMarketFocus = [
        "Life Insurance", "Retirement Planning", "Mortgage Protection",
        "College Funding", "Annuities", "Debt Elimination"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Tell SAM about your practice so coaching suggestions are relevant and grounded.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Practice Structure
            GroupBox("Practice Structure") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Solo practitioner (no team, no employees)", isOn: $profile.isSoloPractitioner)
                        .onChange(of: profile.isSoloPractitioner) { _, _ in saveProfile() }

                    HStack {
                        Text("Organization:")
                            .frame(width: 100, alignment: .leading)
                        TextField("e.g., World Financial Group", text: $profile.organization)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveProfile() }
                    }

                    HStack {
                        Text("Your role:")
                            .frame(width: 100, alignment: .leading)
                        TextField("e.g., Senior Marketing Director", text: $profile.roleTitle)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveProfile() }
                    }

                    HStack {
                        Text("Experience:")
                            .frame(width: 100, alignment: .leading)
                        Picker("", selection: $profile.yearsExperience) {
                            Text("New").tag(0)
                            Text("1-2 years").tag(1)
                            Text("3-5 years").tag(3)
                            Text("5-10 years").tag(5)
                            Text("10+ years").tag(10)
                            Text("20+ years").tag(20)
                        }
                        .labelsHidden()
                        .onChange(of: profile.yearsExperience) { _, _ in saveProfile() }
                    }
                }
                .padding(.vertical, 4)
            }

            // Market Focus
            GroupBox("Market Focus") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select your primary focus areas:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(commonMarketFocus, id: \.self) { focus in
                            Toggle(focus, isOn: Binding(
                                get: { profile.marketFocus.contains(focus) },
                                set: { isOn in
                                    if isOn {
                                        if !profile.marketFocus.contains(focus) {
                                            profile.marketFocus.append(focus)
                                        }
                                    } else {
                                        profile.marketFocus.removeAll { $0 == focus }
                                    }
                                    saveProfile()
                                }
                            ))
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Toggle("Actively recruiting agents", isOn: $profile.isActivelyRecruiting)
                        .onChange(of: profile.isActivelyRecruiting) { _, _ in saveProfile() }

                    HStack {
                        Text("Geographic market:")
                        TextField("e.g., San Diego, CA", text: $profile.geographicMarket)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveProfile() }
                    }
                }
                .padding(.vertical, 4)
            }

            // Tools & Capabilities
            GroupBox("Tools & Capabilities") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("SAM is my CRM (prevent suggestions to buy other CRM tools)", isOn: $profile.samIsCRM)
                        .onChange(of: profile.samIsCRM) { _, _ in saveProfile() }

                    Text("Social platforms:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(["Facebook", "LinkedIn", "Instagram", "X/Twitter"], id: \.self) { platform in
                            Toggle(platform, isOn: Binding(
                                get: { profile.activeSocialPlatforms.contains(platform) },
                                set: { isOn in
                                    if isOn {
                                        if !profile.activeSocialPlatforms.contains(platform) {
                                            profile.activeSocialPlatforms.append(platform)
                                        }
                                    } else {
                                        profile.activeSocialPlatforms.removeAll { $0 == platform }
                                    }
                                    saveProfile()
                                }
                            ))
                            .toggleStyle(.button)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Additional Context
            GroupBox("Additional Context") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Anything else SAM's AI should always know about your practice:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $profile.additionalContext)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if profile.additionalContext.isEmpty {
                                Text("e.g., \"I specialize in serving military families\" or \"My warm market is exhausted, focusing on referrals\"")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 4)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: profile.additionalContext) { _, _ in saveProfile() }
                }
                .padding(.vertical, 4)
            }
        }
        .task {
            await loadProfile()
        }
    }

    private func loadProfile() async {
        let loaded = await BusinessProfileService.shared.profile()
        profile = loaded
        isLoaded = true
    }

    private func saveProfile() {
        guard isLoaded else { return }
        Task {
            await BusinessProfileService.shared.save(profile)
        }
    }
}

// MARK: - Intelligence Settings Content

struct IntelligenceSettingsContent: View {

    @State private var insightGenerator = InsightGenerator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Insight Generation Settings
            VStack(alignment: .leading, spacing: 12) {
                Text("Insight Generation")
                    .font(.headline)

                Toggle("Auto-generate insights", isOn: Binding(
                    get: { insightGenerator.autoGenerateEnabled },
                    set: { insightGenerator.autoGenerateEnabled = $0 }
                ))

                Text("When enabled, SAM automatically generates insights after importing contacts, calendar events, or emails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Alert threshold for untagged contacts:")
                    Picker("", selection: Binding(
                        get: { insightGenerator.daysSinceContactThreshold > 0 ? insightGenerator.daysSinceContactThreshold : 60 },
                        set: { insightGenerator.daysSinceContactThreshold = $0 }
                    )) {
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                        Text("120 days").tag(120)
                    }
                    .frame(width: 120)
                }

                Text("Alert when an untagged contact (no role badge) hasn't been reached within this period. Contacts with role badges use adaptive role-based thresholds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Intelligence Settings (standalone wrapper)

struct IntelligenceSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Intelligence", systemImage: "brain")
                        .font(.title2)
                        .bold()

                    Divider()

                    IntelligenceSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {

    @AppStorage("sam.user.firstName") private var userFirstName = ""
    @AppStorage("sam.user.lastName") private var userLastName = ""
    @AppStorage("sam.user.defaultClosing") private var defaultClosing = "Best,"
    @AppStorage("sam.messages.allowEmoji") private var allowEmoji = false
    @State private var silenceTimeout: Double = {
        let stored = UserDefaults.standard.double(forKey: "sam.dictation.silenceTimeout")
        return stored > 0 ? stored : 2.0
    }()
    @State private var migrationService = LegacyStoreMigrationService.shared
    @State private var showCleanupConfirmation = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("General", systemImage: "gearshape")
                        .font(.title2)
                        .bold()

                    Divider()

                    // App info
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Version:")
                                .foregroundStyle(.secondary)
                            Text(appVersion)
                        }

                        HStack {
                            Text("Schema:")
                                .foregroundStyle(.secondary)
                            Text(SAMModelContainer.schemaVersion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // Identity & Signature
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Identity")
                            .font(.headline)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("First Name")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("First name", text: $userFirstName)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Last Name")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Last name", text: $userLastName)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default Closing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("e.g. Best, / Yours, / Warm regards,", text: $defaultClosing)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 250)
                        }

                        Text("Used to sign AI-generated messages. SAM uses your first name for people you interact with regularly, and your full name for others. SAM learns your preferred closing style as you edit drafts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if userFirstName.isEmpty {
                            Button("Auto-fill from Me Contact") {
                                autoFillFromMeContact()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    // AI Messages
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Allow emoji and icons in AI messages", isOn: $allowEmoji)
                        Text("When off, SAM will not use emoji, emoticons, or Unicode symbols in generated messages, briefings, and coaching text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    // Dictation
                    dictationSection

                    Divider()

                    // Guidance & Tips
                    DisclosureGroup {
                        GuidanceSettingsContent()
                            .padding(.top, 8)
                    } label: {
                        Label("Guidance & Tips", systemImage: "lightbulb")
                    }

                    Divider()

                    // Clipboard Capture
                    DisclosureGroup {
                        ClipboardCaptureSettingsContent()
                            .padding(.top, 8)
                    } label: {
                        Label("Clipboard Capture", systemImage: "doc.on.clipboard")
                    }

                    // Legacy Data — only visible when orphaned stores are detected
                    if let discovery = migrationService.discovery, !discovery.isEmpty {
                        Divider()
                        legacyDataSection(discovery: discovery)
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if migrationService.discovery == nil {
                migrationService.discoverLegacyStores()
            }
            // Auto-populate name from Me contact if not yet set
            if userFirstName.isEmpty {
                autoFillFromMeContact()
            }
        }
        .alert("Clean Up Legacy Files?", isPresented: $showCleanupConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Old Files", role: .destructive) {
                migrationService.cleanupLegacyStores()
            }
        } message: {
            if let discovery = migrationService.discovery {
                Text("This will permanently delete \(discovery.count) legacy store\(discovery.count == 1 ? "" : "s") (\(discovery.formattedSize)). Make sure you have migrated any data you need first.")
            }
        }
    }

    // MARK: - Legacy Data Section

    private func legacyDataSection(discovery: LegacyStoreDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Legacy Data", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            Text("Data from a previous SAM version was found on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("\(discovery.count) legacy store\(discovery.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(discovery.formattedSize)
                    .foregroundStyle(.secondary)
            }

            if let mostRecent = discovery.mostRecent {
                Text("Most recent: \(mostRecent.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Status display
            switch migrationService.status {
            case .migrating(let message):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .cleaning:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cleaning up...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if message.contains("schemas too old") {
                        Text("Try \"Import Roles Only\" to recover role assignments via direct database read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                EmptyView()
            }

            HStack(spacing: 12) {
                Button("Migrate All Data...") {
                    Task { await migrationService.migrate() }
                }
                .disabled(migrationService.isBusy)

                Button("Import Roles Only...") {
                    Task { await migrationService.migrateRolesOnly() }
                }
                .disabled(migrationService.isBusy)
                .help("Reads role assignments directly from the legacy database and applies them to matching contacts. Works even when full migration fails.")

                Button("Clean Up Old Files...", role: .destructive) {
                    showCleanupConfirmation = true
                }
                .disabled(migrationService.isBusy)
            }
        }
    }

    // MARK: - Dictation Section

    // MARK: - Auto-fill from Me Contact

    private func autoFillFromMeContact() {
        guard let me = try? PeopleRepository.shared.fetchMe(),
              let fullName = me.displayNameCache, !fullName.isEmpty else { return }

        let parts = fullName.split(separator: " ", maxSplits: 1)
        if let first = parts.first {
            userFirstName = String(first)
        }
        if parts.count > 1 {
            userLastName = String(parts[1])
        }
    }

    // MARK: - Dictation Section

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictation")
                .font(.headline)

            Text("How long SAM waits after you stop speaking before ending dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Silence timeout")
                Spacer()
                Text(String(format: "%.1fs", silenceTimeout))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: $silenceTimeout, in: 0.5...5.0, step: 0.5)
                .onChange(of: silenceTimeout) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "sam.dictation.silenceTimeout")
                }

            HStack {
                Text("0.5s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("5.0s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#Preview {
    SettingsView()
}
