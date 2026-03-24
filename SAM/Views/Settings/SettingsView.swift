//
//  SettingsView.swift
//  SAM_crm
//
//  Created by Assistant on 2/9/26.
//  Xcode-style sidebar navigation with focused detail panes.
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

// MARK: - Settings Section Enum

enum SettingsSection: String, CaseIterable, Identifiable {
    // General
    case personalization = "Personalization"
    case appearance = "Appearance"
    case security = "Security"
    // Data
    case contacts = "Contacts"
    case calendar = "Calendar"
    case mail = "Mail"
    case communications = "Communications"
    case clipboardCapture = "Clipboard Capture"
    // AI
    case coaching = "Coaching"
    case briefings = "Briefings"
    case dictationVoice = "Dictation & Voice"
    case promptLab = "Prompt Lab"
    // Business
    case businessType = "Business Type"
    case compliance = "Compliance"
    case roles = "Roles"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .personalization: return "person.crop.circle"
        case .appearance: return "paintbrush"
        case .security: return "lock.shield"
        case .contacts: return "person.crop.circle.fill"
        case .calendar: return "calendar"
        case .mail: return "envelope"
        case .communications: return "message.fill"
        case .clipboardCapture: return "doc.on.clipboard"
        case .coaching: return "brain.head.profile"
        case .briefings: return "text.book.closed"
        case .dictationVoice: return "mic.fill"
        case .promptLab: return "wand.and.stars"
        case .businessType: return "briefcase"
        case .compliance: return "checkmark.shield"
        case .roles: return "person.badge.key"
        }
    }

    var group: String {
        switch self {
        case .personalization, .appearance, .security: return "General"
        case .contacts, .calendar, .mail, .communications, .clipboardCapture: return "Data"
        case .coaching, .briefings, .dictationVoice, .promptLab: return "AI"
        case .businessType, .compliance, .roles: return "Business"
        }
    }

    static var grouped: [(header: String, sections: [SettingsSection])] {
        let order = ["General", "Data", "AI", "Business"]
        let dict = Dictionary(grouping: allCases, by: \.group)
        return order.compactMap { key in
            guard let sections = dict[key] else { return nil }
            return (header: key, sections: sections)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {

    @State private var selectedSection: SettingsSection = .personalization

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsSection.grouped, id: \.header) { group in
                    Section(group.header) {
                        ForEach(group.sections) { section in
                            Label(section.rawValue, systemImage: section.icon)
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            detailPane
        }
        .frame(width: 880, height: 580)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedSection {
        case .personalization:
            PersonalizationSettingsPane()
        case .appearance:
            AppearanceSettingsPane()
        case .security:
            SecuritySettingsPane()
        case .contacts:
            ContactsSettingsPane()
        case .calendar:
            CalendarSettingsPane()
        case .mail:
            MailSettingsPane()
        case .communications:
            CommunicationsSettingsPane()
        case .clipboardCapture:
            ClipboardCaptureSettingsPane()
        case .coaching:
            CoachingSettingsPane()
        case .briefings:
            BriefingsSettingsPane()
        case .dictationVoice:
            DictationVoiceSettingsPane()
        case .promptLab:
            PromptLabSettingsPane()
        case .businessType:
            BusinessTypeSettingsPane()
        case .compliance:
            ComplianceSettingsPane()
        case .roles:
            RolesSettingsPane()
        }
    }
}

// MARK: - Helpers

private func lookbackStartDescription(days: Int) -> String {
    if days == 0 { return "the beginning of history" }
    let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    return formatter.string(from: date)
}

// MARK: - Shared Permission Badge

func permissionBadge(icon: String, color: Color, name: String, status: String) -> some View {
    HStack(spacing: 8) {
        Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(color)
            .frame(width: 20)

        Text(name)
            .frame(width: 140, alignment: .leading)

        let isGranted = status == "Authorized"
        HStack(spacing: 4) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle")
                .samFont(.caption)
                .foregroundStyle(isGranted ? .green : .orange)
            Text(status)
                .samFont(.caption)
                .foregroundStyle(isGranted ? .green : .secondary)
        }
    }
    .padding(.vertical, 2)
}

// MARK: - Pane Wrappers (reuse existing content views)

private struct SecuritySettingsPane: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    SecuritySettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

private struct ContactsSettingsPane: View {
    @State private var contactsStatus: String = "Checking..."
    @State private var isRequestingContacts = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    permissionBadge(
                        icon: "person.crop.circle.fill", color: .blue,
                        name: "Contacts", status: contactsStatus
                    )

                    if contactsStatus != "Authorized" {
                        Button("Request Access") { requestContactsPermission() }
                            .controlSize(.small)
                            .disabled(isRequestingContacts)
                    }

                    Divider()

                    ContactsSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .task {
            let auth = CNContactStore.authorizationStatus(for: .contacts)
            contactsStatus = authStatusString(auth)
        }
    }

    private func requestContactsPermission() {
        isRequestingContacts = true
        Task {
            let granted = await ContactsService.shared.requestAuthorization()
            contactsStatus = granted ? "Authorized" : "Denied"
            isRequestingContacts = false
            if granted {
                ContactsImportCoordinator.shared.permissionGranted()
                try? await Task.sleep(for: .milliseconds(500))
                await ContactsImportCoordinator.shared.importNow()
            }
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
}

private struct CalendarSettingsPane: View {
    @State private var calendarStatus: String = "Checking..."
    @State private var isRequestingCalendar = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    permissionBadge(
                        icon: "calendar.circle.fill", color: .orange,
                        name: "Calendar", status: calendarStatus
                    )

                    if calendarStatus != "Authorized" {
                        Button("Request Access") { requestCalendarPermission() }
                            .controlSize(.small)
                            .disabled(isRequestingCalendar)
                    }

                    Divider()

                    CalendarSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .task {
            let auth = await CalendarService.shared.authorizationStatus()
            calendarStatus = authStatusString(auth)
        }
    }

    private func requestCalendarPermission() {
        isRequestingCalendar = true
        Task {
            let granted = await CalendarImportCoordinator.shared.requestAuthorization()
            calendarStatus = granted ? "Authorized" : "Denied"
            isRequestingCalendar = false
            if granted {
                try? await Task.sleep(for: .milliseconds(500))
                await CalendarImportCoordinator.shared.importNow()
            }
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
}

private struct MailSettingsPane: View {
    @State private var mailStatus: String = "Checking..."

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    permissionBadge(
                        icon: "envelope.circle.fill", color: .blue,
                        name: "Mail", status: mailStatus
                    )

                    Divider()

                    MailSettingsContent()

                    if MailImportCoordinator.shared.mailEnabled {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Troubleshooting")
                                .samFont(.headline)

                            Button {
                                MailImportCoordinator.shared.resetWatermark()
                                MailImportCoordinator.shared.startImport()
                            } label: {
                                Label("Re-scan Mail", systemImage: "arrow.counterclockwise")
                            }
                            .help("Reset import watermark and re-scan from the lookback date")

                            Text("Re-imports mail starting from \(lookbackStartDescription(days: MailImportCoordinator.shared.lookbackDays)). Use this if emails were missed.")
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .task {
            if MailImportCoordinator.shared.mailEnabled {
                if let error = await MailImportCoordinator.shared.checkMailAccess() {
                    mailStatus = error
                } else {
                    mailStatus = "Authorized"
                }
            } else {
                mailStatus = "Not Configured"
            }
        }
    }
}

private struct CommunicationsSettingsPane: View {
    @State private var bookmarkManager = BookmarkManager.shared
    @State private var hotkeyService = GlobalHotkeyService.shared
    @State private var globalLookbackDays: Int = {
        UserDefaults.standard.object(forKey: "globalLookbackDays") == nil
            ? 30
            : UserDefaults.standard.integer(forKey: "globalLookbackDays")
    }()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    // Permission badges
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permissions")
                            .samFont(.headline)

                        permissionBadge(
                            icon: "message.fill", color: .green,
                            name: "iMessage", status: bookmarkManager.hasMessagesAccess ? "Authorized" : "Not Configured"
                        )
                        permissionBadge(
                            icon: "phone.fill", color: .green,
                            name: "Call History", status: bookmarkManager.hasCallHistoryAccess ? "Authorized" : "Not Configured"
                        )
                        permissionBadge(
                            icon: "accessibility", color: .gray,
                            name: "Accessibility", status: hotkeyService.accessibilityGranted ? "Authorized" : "Not Granted"
                        )
                    }

                    Divider()

                    // History Lookback
                    VStack(alignment: .leading, spacing: 8) {
                        Text("History Lookback Period")
                            .samFont(.headline)

                        Text("How far back SAM scans when importing from Calendar, Mail, and Communications.")
                            .samFont(.caption)
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
                            CalendarImportCoordinator.shared.lookbackDays = newValue
                            MailImportCoordinator.shared.setLookbackDays(newValue)
                            CommunicationsImportCoordinator.shared.setLookbackDays(newValue)
                        }

                        if globalLookbackDays == 0 {
                            Text("First import will scan all available history. Subsequent imports use incremental sync.")
                                .samFont(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Divider()

                    // Communications settings
                    CommunicationsSettingsContent()

                    if bookmarkManager.hasMessagesAccess || bookmarkManager.hasCallHistoryAccess {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Troubleshooting")
                                .samFont(.headline)

                            Button {
                                CommunicationsImportCoordinator.shared.resetWatermarks()
                                CommunicationsImportCoordinator.shared.startImport()
                            } label: {
                                Label("Re-scan iMessage & Calls", systemImage: "arrow.counterclockwise")
                            }
                            .help("Reset import watermark and re-scan from the lookback date")

                            Text("Re-imports messages and calls starting from \(lookbackStartDescription(days: globalLookbackDays)). Use this if communications were missed.")
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClipboardCaptureSettingsPane: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    ClipboardCaptureSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

private struct CoachingSettingsPane: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    IntelligenceSettingsContent()
                    Divider()
                    CoachingSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

private struct BriefingsSettingsPane: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    BriefingSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

private struct PromptLabSettingsPane: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Prompt Lab lets you compare and refine the AI prompts SAM uses for coaching, briefings, and analysis.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        openWindow(id: "prompt-lab")
                    } label: {
                        HStack {
                            Label("Open Prompt Lab", systemImage: "wand.and.stars")
                            Spacer()
                            Text("Opens in a separate window")
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

private struct BusinessTypeSettingsPane: View {
    @State private var practiceType: PracticeType = .financialAdvisor

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    BusinessProfileSettingsContent(practiceTypeBinding: $practiceType)
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .task {
            let profile = await BusinessProfileService.shared.profile()
            practiceType = profile.practiceType
        }
    }
}

private struct ComplianceSettingsPane: View {
    @State private var practiceType: PracticeType = .financialAdvisor

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    ComplianceSettingsContent(isFinancial: practiceType == .financialAdvisor)
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .task {
            let profile = await BusinessProfileService.shared.profile()
            practiceType = profile.practiceType
        }
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
                .samFont(.caption)
                .foregroundStyle(.secondary)

            Toggle("Suggest features you haven't tried", isOn: Binding(
                get: { FeatureAdoptionTracker.shared.isEnabled },
                set: { newValue in
                    UserDefaults.standard.set(newValue, forKey: "sam.coaching.featureAdoptionEnabled")
                }
            ))

            Text("SAM will suggest features over your first weeks to help you get the most out of the app.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show help buttons in views", isOn: $showHelpButtons)

            Text("Small \"?\" buttons in toolbars and headers that open the SAM Guide to the relevant article.")
                .samFont(.caption)
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
                .samFont(.headline)

            Text("Copy a conversation from any app and press ⌃⇧V to capture it as evidence in SAM.")
                .samFont(.caption)
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
                    .samFont(.subheadline)

                Spacer()

                if hotkeyService.accessibilityGranted {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Granted")
                            .samFont(.caption)
                            .foregroundStyle(.green)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.orange)
                            Text("Not Granted")
                                .samFont(.caption)
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
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if hotkeyService.isRegistered {
                Text("Global hotkey is active — press ⌃⇧V from any app to capture a conversation.")
                    .samFont(.caption)
                    .foregroundStyle(.green)
            } else if hotkeyEnabled && !hotkeyService.accessibilityGranted {
                Text("Grant Accessibility permission, then restart SAM to activate the global hotkey.")
                    .samFont(.caption)
                    .foregroundStyle(.orange)
            }

            Text("The in-app menu command (Edit → Capture Clipboard Conversation) works without Accessibility permission.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
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
    @State private var isMigrating = false
    @State private var samGroupInICloud = true
    @State private var errorMessage: String?
    @State private var authorizationStatus: CNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Authorization Check
            if authorizationStatus != .authorized {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Authorization Required")
                        .samFont(.headline)
                        .foregroundStyle(.orange)

                    Text("Please grant Contacts access in the Permissions tab first.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)

                Divider()
            }

            // Group Selection
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Contact Group")
                        .samFont(.headline)

                    Text("SAM reads all contacts to identify matches and avoid duplicates, but only imports and updates contacts in this group.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    if authorizationStatus != .authorized {
                        Text("Contacts access required to load groups.")
                            .samFont(.caption)
                            .foregroundStyle(.orange)
                    } else if isLoadingGroups {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading groups...")
                                .samFont(.caption)
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
                                .samFont(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("No contact groups found. Create one in the Contacts app, or click 'Refresh Groups' below.")
                            .samFont(.caption)
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

            // iCloud migration warning
            if !samGroupInICloud && !selectedGroupIdentifier.isEmpty && authorizationStatus == .authorized {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("SAM group is not in iCloud", systemImage: "exclamationmark.icloud")
                            .samFont(.headline)
                            .foregroundStyle(.orange)

                        Text("Your SAM group is stored locally. Contacts in other accounts (like iCloud) can't be added to it, and it won't sync to other devices. Migrate to iCloud to fix this.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            Task {
                                isMigrating = true
                                if let _ = await ContactsService.shared.migrateSAMGroupToICloud() {
                                    samGroupInICloud = true
                                    await loadGroups()
                                    // Update the picker to reflect the new group ID
                                    let newID = UserDefaults.standard.string(forKey: "selectedContactGroupIdentifier") ?? ""
                                    if !newID.isEmpty {
                                        selectedGroupIdentifier = newID
                                        ContactsImportCoordinator.shared.selectedGroupDidChange()
                                    }
                                } else {
                                    errorMessage = "Migration failed. Check that you have an iCloud account configured in Contacts."
                                }
                                isMigrating = false
                            }
                        } label: {
                            if isMigrating {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Migrating...")
                                }
                            } else {
                                Text("Move SAM Group to iCloud")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isMigrating)
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Auto-import toggle
            Toggle("Automatically import contacts", isOn: $autoImportEnabled)

            Text("When enabled, SAM will automatically sync with Contacts when changes are detected.")
                .samFont(.caption)
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
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = coordinator.lastError {
                Text(error)
                    .samFont(.caption)
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
            let inICloud = await ContactsService.shared.isSAMGroupInICloud()
            await MainActor.run {
                samGroupInICloud = inICloud
            }
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
                        .samFont(.headline)
                        .foregroundStyle(.orange)

                    Text("Please grant Calendar access in the Permissions tab first.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)

                Divider()
            }

            // Calendar Selection
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Calendar")
                        .samFont(.headline)

                    Text("Select which Calendar SAM should access. Only events from this calendar will be imported.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    if authorizationStatus != .fullAccess {
                        Text("Calendar access required to load calendars.")
                            .samFont(.caption)
                            .foregroundStyle(.orange)
                    } else if isLoadingCalendars {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading calendars...")
                                .samFont(.caption)
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
                                .samFont(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("No calendars found. Create one in the Calendar app, or click 'Refresh Calendars' below.")
                            .samFont(.caption)
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
                .samFont(.caption)
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
                        .samFont(.caption)
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

// MARK: - Business Profile Settings Content

struct BusinessProfileSettingsContent: View {

    /// Syncs practice type back to the parent so Compliance can hide/show.
    @Binding var practiceTypeBinding: PracticeType

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
                .samFont(.caption)
                .foregroundStyle(.secondary)

            // Business Type
            GroupBox("Business Type") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Type", selection: $profile.practiceType) {
                        ForEach(PracticeType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: profile.practiceType) { _, _ in saveProfile() }

                    Text(profile.isFinancial
                         ? "Full financial advisor experience with production tracking, recruiting pipeline, and compliance scanning."
                         : "Generic relationship coaching, event management, and social media. Financial-specific features are hidden.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

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
                        Text(profile.isFinancial ? "Experience:" : "Experience:")
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

            // Market Focus / Focus Areas
            GroupBox(profile.isFinancial ? "Market Focus" : "Focus Areas") {
                VStack(alignment: .leading, spacing: 12) {
                    if profile.isFinancial {
                        Text("Select your primary focus areas:")
                            .samFont(.caption)
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
                    } else {
                        TextField("e.g., Social media marketing, Nonprofit governance, Community outreach",
                                  text: Binding(
                                    get: { profile.marketFocus.joined(separator: ", ") },
                                    set: { newValue in
                                        profile.marketFocus = newValue
                                            .components(separatedBy: ",")
                                            .map { $0.trimmingCharacters(in: .whitespaces) }
                                            .filter { !$0.isEmpty }
                                        saveProfile()
                                    }
                                  ))
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Geographic market:")
                        TextField("e.g., San Diego, CA", text: $profile.geographicMarket)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveProfile() }
                    }

                    HStack {
                        Text("Website:")
                        TextField("e.g., https://yoursite.com", text: $profile.website)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveProfile() }
                    }
                }
                .padding(.vertical, 4)
            }

            // Additional Context
            GroupBox("Additional Context") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Anything else SAM's AI should always know about your practice:")
                        .samFont(.caption)
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
        practiceTypeBinding = loaded.practiceType
        isLoaded = true
    }

    private func saveProfile() {
        guard isLoaded else { return }
        practiceTypeBinding = profile.practiceType
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
                    .samFont(.headline)

                Toggle("Auto-generate insights", isOn: Binding(
                    get: { insightGenerator.autoGenerateEnabled },
                    set: { insightGenerator.autoGenerateEnabled = $0 }
                ))

                Text("When enabled, SAM automatically generates insights after importing contacts, calendar events, or emails.")
                    .samFont(.caption)
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
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Security Settings

struct SecuritySettingsContent: View {

    @State private var lockService = AppLockService.shared
    @State private var selectedTimeout: Int = AppLockService.shared.lockTimeoutMinutes

    private let timeoutOptions = [1, 5, 15, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Security", systemImage: "lock.shield")
                .samFont(.headline)

            HStack {
                Text("Lock after inactive:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedTimeout) {
                    ForEach(timeoutOptions, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                .onChange(of: selectedTimeout) { _, newValue in
                    lockService.lockTimeoutMinutes = newValue
                }
            }

            Button("Lock Now") {
                lockService.lock()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if lockService.isBiometricAvailable {
                Text("Touch ID is available and will be used for authentication.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Touch ID is not available. System password will be used.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("SAM always requires authentication on launch and after the idle timeout expires. All backups are encrypted with a passphrase.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
