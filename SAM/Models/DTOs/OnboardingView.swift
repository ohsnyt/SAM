//
//  OnboardingView.swift
//  SAM_crm
//
//  Created on February 10, 2026.
//  Phase E: Onboarding & Permissions
//
//  First-run onboarding sheet that explains permissions and helps user set up.
//

import SwiftUI
import Contacts
import EventKit
import AVFoundation
import Speech
import UserNotifications

struct OnboardingView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var currentStep: OnboardingStep = .welcome
    @State private var contactsStatus: CNAuthorizationStatus = .notDetermined
    @State private var calendarStatus: EKAuthorizationStatus = .notDetermined
    @State private var isRequestingContacts = false
    @State private var isRequestingCalendar = false
    @State private var selectedGroupIdentifier: String = ""
    @State private var selectedCalendarIdentifier: String = ""
    @State private var availableGroups: [ContactGroupDTO] = []
    @State private var availableCalendars: [CalendarDTO] = []
    @State private var isLoadingGroups = false
    @State private var isLoadingCalendars = false
    @State private var skippedContacts = false
    @State private var skippedCalendar = false
    @State private var skippedMail = false
    @State private var mailAccessError: String?
    @State private var mailAccessGranted = false
    @State private var isCheckingMail = false
    @State private var meEmailAddresses: [String] = []
    @State private var hasNoMeContact = false
    @State private var selectedMailAddresses: Set<String> = []
    @State private var onboardingLookbackDays: Int = 30
    @State private var micPermissionGranted = false
    @State private var speechPermissionGranted = false
    @State private var skippedMicrophone = false

    // Communications
    @State private var skippedCommunications = false

    // Notifications
    @State private var notificationsGranted = false
    @State private var notificationsDenied = false
    @State private var skippedNotifications = false

    // Pre-check
    @State private var preCheckComplete = false
    @State private var stepReadiness: [OnboardingStep: Bool] = [:]

    // AI Setup (MLX)
    @State private var isMlxDownloading = false
    @State private var mlxDownloadProgress: Double = 0
    @State private var mlxDownloadError: String?
    @State private var mlxModelReady = false
    @State private var skippedAISetup = false

    enum OnboardingStep {
        case welcome
        case contactsPermission
        case contactsGroupSelection
        case calendarPermission
        case calendarSelection
        case mailPermission
        case mailAddressSelection
        case communicationsPermission
        case microphonePermission
        case notificationsPermission
        case aiSetup
        case complete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 24) {
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .contactsPermission:
                        contactsPermissionStep
                    case .contactsGroupSelection:
                        contactsGroupSelectionStep
                    case .calendarPermission:
                        calendarPermissionStep
                    case .calendarSelection:
                        calendarSelectionStep
                    case .mailPermission:
                        mailPermissionStep
                    case .mailAddressSelection:
                        mailAddressSelectionStep
                    case .communicationsPermission:
                        communicationsPermissionStep
                    case .microphonePermission:
                        microphonePermissionStep
                    case .notificationsPermission:
                        notificationsPermissionStep
                    case .aiSetup:
                        aiSetupStep
                    case .complete:
                        completeStep
                    }
                }
                .padding(32)
            }

            Divider()

            // Footer with navigation buttons
            footer
        }
        .frame(width: 600, height: 500)
        .task {
            await runPreChecks()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to SAM")
                    .samFont(.title2)
                    .bold()

                if currentStep != .welcome && currentStep != .complete && currentStepNumber > 0 && totalSteps > 0 {
                    Text("Step \(currentStepNumber) of \(totalSteps)")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Quit button - escape hatch for users who want to exit
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    /// Steps the user will actually walk through (dynamically filtered by pre-check).
    private var activeSteps: [OnboardingStep] {
        let allIntermediate: [OnboardingStep] = [
            .contactsPermission, .contactsGroupSelection,
            .calendarPermission, .calendarSelection,
            .mailPermission, .mailAddressSelection,
            .communicationsPermission, .microphonePermission,
            .notificationsPermission, .aiSetup
        ]
        let pending = allIntermediate.filter { stepReadiness[$0] != true }
        return [.welcome] + pending + [.complete]
    }

    private var currentStepNumber: Int {
        let actionSteps = activeSteps.filter { $0 != .welcome && $0 != .complete }
        guard let idx = actionSteps.firstIndex(of: currentStep) else { return 0 }
        return idx + 1
    }

    private var totalSteps: Int {
        activeSteps.filter { $0 != .welcome && $0 != .complete }.count
    }

    // MARK: - Active-Step Navigation

    private static let canonicalOrder: [OnboardingStep] = [
        .welcome, .contactsPermission, .contactsGroupSelection,
        .calendarPermission, .calendarSelection,
        .mailPermission, .mailAddressSelection,
        .communicationsPermission, .microphonePermission,
        .notificationsPermission, .aiSetup, .complete
    ]

    private func advanceToNextActiveStep() {
        let steps = activeSteps
        if let idx = steps.firstIndex(of: currentStep), idx + 1 < steps.count {
            currentStep = steps[idx + 1]
        } else if !steps.contains(currentStep) {
            // Current step was marked ready and removed from activeSteps.
            // Find the first active step whose canonical position is after the current one.
            let currentOrdinal = Self.canonicalOrder.firstIndex(of: currentStep) ?? 0
            if let next = steps.first(where: {
                (Self.canonicalOrder.firstIndex(of: $0) ?? 0) > currentOrdinal
            }) {
                currentStep = next
            } else {
                currentStep = .complete
            }
        }
    }

    private func retreatToPreviousActiveStep() {
        let steps = activeSteps
        if let idx = steps.firstIndex(of: currentStep), idx > 0 {
            currentStep = steps[idx - 1]
        } else if !steps.contains(currentStep) {
            let currentOrdinal = Self.canonicalOrder.firstIndex(of: currentStep) ?? 0
            if let prev = steps.last(where: {
                (Self.canonicalOrder.firstIndex(of: $0) ?? 0) < currentOrdinal
            }) {
                currentStep = prev
            }
        }
    }

    // MARK: - Pre-Check

    private func runPreChecks() async {
        guard !preCheckComplete else { return }

        // Run permission checks in parallel with the existing state vars
        contactsStatus = await ContactsService.shared.authorizationStatus()
        calendarStatus = await CalendarService.shared.authorizationStatus()

        let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
        switch notificationSettings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationsGranted = true
        case .denied:
            notificationsDenied = true
        case .notDetermined:
            break
        @unknown default:
            break
        }

        // Mic + Speech
        micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechPermissionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized

        // Mail
        let mailError = await MailImportCoordinator.shared.checkMailAccess()
        if mailError == nil {
            mailAccessGranted = true
        }

        // Me emails (needed for mail address readiness)
        await fetchMeEmailAddresses()

        // Contacts: permission + group auto-select
        let contactsReady = contactsStatus == .authorized
        stepReadiness[.contactsPermission] = contactsReady
        if contactsReady {
            await loadGroups()
            let groupAutoSelected = !selectedGroupIdentifier.isEmpty && selectedGroupIdentifier != "__create_sam__"
            stepReadiness[.contactsGroupSelection] = groupAutoSelected
        } else {
            stepReadiness[.contactsGroupSelection] = false
        }

        // Calendar: permission + selection auto-select
        let calendarReady = calendarStatus == .fullAccess
        stepReadiness[.calendarPermission] = calendarReady
        if calendarReady {
            await loadCalendars()
            let calAutoSelected = !selectedCalendarIdentifier.isEmpty && selectedCalendarIdentifier != "__create_sam__"
            stepReadiness[.calendarSelection] = calAutoSelected
        } else {
            stepReadiness[.calendarSelection] = false
        }

        // Mail
        stepReadiness[.mailPermission] = mailAccessGranted
        // Mail address selection: ready if mail granted and (<=1 email or all selected)
        if mailAccessGranted {
            stepReadiness[.mailAddressSelection] = meEmailAddresses.count <= 1
        } else {
            stepReadiness[.mailAddressSelection] = false
        }

        // Communications
        stepReadiness[.communicationsPermission] = BookmarkManager.shared.hasMessagesAccess || BookmarkManager.shared.hasCallHistoryAccess

        // Mic + Speech
        stepReadiness[.microphonePermission] = micPermissionGranted && speechPermissionGranted

        // Notifications
        stepReadiness[.notificationsPermission] = notificationsGranted

        // AI (MLX)
        let models = await MLXModelManager.shared.availableModels
        mlxModelReady = models.contains { $0.isDownloaded }
        stepReadiness[.aiSetup] = mlxModelReady

        preCheckComplete = true
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your Relationship Management Assistant")
                .samFont(.title)
                .bold()

            Text("SAM helps you maintain great relationships with your clients by:")
                .samFont(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "person.2.fill", text: "Tracking interactions from Contacts and Calendar")
                FeatureRow(icon: "lightbulb.fill", text: "Generating insights about client needs")
                FeatureRow(icon: "bell.fill", text: "Reminding you when follow-ups are needed")
                FeatureRow(icon: "person.text.rectangle", text: "Identifying your clients, agents, and partners from your data")
                FeatureRow(icon: "brain.head.profile", text: "Coaching you on who to contact next and why")
                FeatureRow(icon: "lock.shield.fill", text: "Keeping all data private and on your device")
            }
            .padding(.leading, 8)

            if !preCheckComplete {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking current setup…")
                        .samFont(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            } else if totalSteps == 0 {
                Text("Everything is already configured!")
                    .samFont(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                Text("Let's get started by setting up permissions.")
                    .samFont(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private var contactsPermissionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)

            Text("Contacts Access")
                .samFont(.title)
                .bold()

            Text("SAM needs access to your Contacts to:")
                .samFont(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Import client names and contact information")
                BulletPoint("Keep your relationship data up-to-date")
                BulletPoint("Link interactions to the right people")
            }
            .padding(.leading, 8)

            Text("SAM reads your full Contacts list to identify matches and avoid duplicates, but only imports and updates contacts in the group you choose in the next step.")
                .samFont(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

            if contactsStatus == .authorized {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Contacts access granted")
                        .foregroundStyle(.green)
                }
            } else if contactsStatus == .denied {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("Contacts access denied")
                            .foregroundStyle(.red)
                    }

                    Text("To grant access, go to System Settings → Privacy & Security → Contacts")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open System Settings") {
                        openSystemSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            }
        }
    }

    private var contactsGroupSelectionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)

            Text("Choose a Contact Group")
                .samFont(.title)
                .bold()

            Text("For best results, create a dedicated 'SAM' group in Contacts containing only your work contacts.")
                .samFont(.body)
                .foregroundStyle(.secondary)

            Text("SAM reads all contacts to find matches and prevent duplicates, but only imports and updates contacts in this group.")
                .samFont(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select Group")
                        .samFont(.headline)

                    if isLoadingGroups {
                        ProgressView()
                    } else if !availableGroups.isEmpty {
                        Picker("Contact Group:", selection: $selectedGroupIdentifier) {
                            if !availableGroups.contains(where: { $0.name == "SAM" }) {
                                Text("Create SAM Group")
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
                            if newValue == "__create_sam__" {
                                Task {
                                    await createSAMGroup()
                                }
                            } else if !newValue.isEmpty && newValue != "__create_sam__" {
                                // Notify coordinator that group selection changed
                                ContactsImportCoordinator.shared.selectedGroupDidChange()
                            }
                        }
                    } else {
                        Text("No groups found. Please create a group in the Contacts app.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            if availableGroups.isEmpty {
                await loadGroups()
            }
        }
    }

    private var calendarPermissionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "calendar.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)

            Text("Calendar Access")
                .samFont(.title)
                .bold()

            Text("SAM needs access to your Calendar to:")
                .samFont(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Track meetings and appointments")
                BulletPoint("Generate insights from interaction patterns")
                BulletPoint("Remind you of upcoming engagements")
            }
            .padding(.leading, 8)

            Text("SAM only accesses events from the calendar you choose.")
                .samFont(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

            if calendarStatus == .fullAccess {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Calendar access granted")
                        .foregroundStyle(.green)
                }
            } else if calendarStatus == .denied {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("Calendar access denied")
                            .foregroundStyle(.red)
                    }

                    Text("To grant access, go to System Settings → Privacy & Security → Calendars")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open System Settings") {
                        openSystemSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
    }

    private var calendarSelectionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)

            Text("Choose a Calendar")
                .samFont(.title)
                .bold()

            Text("For best results, create a dedicated 'SAM' calendar containing only your work events.")
                .samFont(.body)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select Calendar")
                        .samFont(.headline)

                    if isLoadingCalendars {
                        ProgressView()
                    } else if !availableCalendars.isEmpty {
                        Picker("Calendar:", selection: $selectedCalendarIdentifier) {
                            if !availableCalendars.contains(where: { $0.title == "SAM" }) {
                                Text("Create SAM Calendar")
                                    .tag("__create_sam__")
                                Divider()
                            }

                            ForEach(availableCalendars.sorted(by: { $0.title < $1.title })) { calendar in
                                HStack {
                                    if let color = calendar.color {
                                        Circle()
                                            .fill(Color(red: color.red, green: color.green, blue: color.blue))
                                            .frame(width: 10, height: 10)
                                    }
                                    Text(calendar.title)
                                }
                                .tag(calendar.id)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedCalendarIdentifier) { _, newValue in
                            if newValue == "__create_sam__" {
                                Task {
                                    await createSAMCalendar()
                                }
                            }
                        }
                    } else {
                        Text("No calendars found. Please create a calendar in the Calendar app.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            if availableCalendars.isEmpty {
                await loadCalendars()
            }
        }
    }

    private var mailPermissionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "envelope.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)

            Text("Email Integration")
                .samFont(.title)
                .bold()

            Text("SAM can read your email to help you stay on top of relationships:")
                .samFont(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Summarize email interactions")
                BulletPoint("Track communication patterns")
                BulletPoint("Never stores raw message bodies")
            }
            .padding(.leading, 8)

            Text("SAM only reads metadata and generates summaries. You'll choose which email addresses to monitor next.")
                .samFont(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

            if isCheckingMail {
                ProgressView("Checking Mail.app access...")
            } else if mailAccessGranted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Mail.app access granted")
                        .foregroundStyle(.green)
                }
            } else if let error = mailAccessError {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Try Again") {
                        Task { await checkMailPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
            } else if hasNoMeContact {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Email integration requires a Me card in Contacts. You can set this up later in Settings.")
                        .samFont(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .task {
            await fetchMeEmailAddresses()
        }
    }

    private var mailAddressSelectionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)

            Text("Choose Email Addresses")
                .samFont(.title)
                .bold()

            Text("Select which of your email addresses SAM should monitor for client interactions.")
                .samFont(.body)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(meEmailAddresses, id: \.self) { email in
                        Toggle(isOn: mailAddressBinding(for: email)) {
                            HStack {
                                Image(systemName: "envelope")
                                    .foregroundStyle(.secondary)
                                Text(email)
                            }
                        }
                    }
                }
            }

            Text("Only emails sent to selected addresses will be imported. You can change this later in Settings.")
                .samFont(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Initial scan depth")
                    .samFont(.headline)

                Picker("Initial scan depth", selection: $onboardingLookbackDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("All").tag(0)
                }
                .pickerStyle(.segmented)

                if onboardingLookbackDays == 0 {
                    Text("First import will scan all available history. This may take several minutes for large inboxes.")
                        .samFont(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("How far back to scan for emails on first import. You can change this later in Settings.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var communicationsPermissionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "message.and.waveform.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)

            Text("iMessage & Call History")
                .samFont(.title)
                .bold()

            Text("SAM can analyze your iMessage conversations and call history to build a complete picture of your relationships:")
                .samFont(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Summarize message conversations with clients")
                BulletPoint("Track call frequency and patterns")
                BulletPoint("Never stores raw message text — only AI summaries")
            }
            .padding(.leading, 8)

            Text("SAM reads local database files on your Mac. You'll be asked to select each folder. Message text is analyzed on-device then discarded.")
                .samFont(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

            // Messages access
            HStack(spacing: 12) {
                Image(systemName: BookmarkManager.shared.hasMessagesAccess ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(BookmarkManager.shared.hasMessagesAccess ? .green : .secondary)
                    .samFont(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages Database")
                        .samFont(.body)
                    Text("~/Library/Messages/")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !BookmarkManager.shared.hasMessagesAccess {
                    Button("Grant Access") {
                        BookmarkManager.shared.requestMessagesAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
            }

            // Call history access
            HStack(spacing: 12) {
                Image(systemName: BookmarkManager.shared.hasCallHistoryAccess ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(BookmarkManager.shared.hasCallHistoryAccess ? .green : .secondary)
                    .samFont(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Call History Database")
                        .samFont(.body)
                    Text("~/Library/Application Support/CallHistoryDB/")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !BookmarkManager.shared.hasCallHistoryAccess {
                    Button("Grant Access") {
                        BookmarkManager.shared.requestCallHistoryAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
            }
        }
    }

    private var microphonePermissionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.purple)
                .frame(maxWidth: .infinity)

            Text("Microphone & Speech")
                .samFont(.title)
                .bold()

            Text("SAM can transcribe your voice notes during meetings:")
                .samFont(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Dictate notes hands-free")
                BulletPoint("AI cleans up grammar and filler words")
                BulletPoint("All processing happens on-device")
            }
            .padding(.leading, 8)

            Text("Microphone audio is only used for live transcription and is never stored or sent anywhere.")
                .samFont(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

            if micPermissionGranted && speechPermissionGranted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Microphone and speech recognition access granted")
                        .foregroundStyle(.green)
                }
            } else if micPermissionGranted && !speechPermissionGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Microphone granted, but speech recognition was denied. You can enable it in System Settings.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notificationsPermissionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "bell.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)

            Text("Notifications")
                .samFont(.title)
                .bold()

            Text("SAM uses macOS notifications to keep you informed:")
                .samFont(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Alert you when a coaching plan is ready to review")
                BulletPoint("Notify you when background analysis completes")
                BulletPoint("Remind you about time-sensitive follow-ups")
            }
            .padding(.leading, 8)

            Text("Notifications are optional — SAM works fully without them. You just won't get background alerts.")
                .samFont(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

            if notificationsGranted {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Notifications enabled")
                        .foregroundStyle(.green)
                }
            } else if notificationsDenied {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text("Notifications denied")
                            .foregroundStyle(.red)
                    }

                    Text("To enable later, go to System Settings → Notifications → SAM")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open System Settings") {
                        openSystemSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
    }

    private var aiSetupStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 64))
                .foregroundStyle(.indigo)
                .frame(maxWidth: .infinity)

            Text("Enhanced AI")
                .samFont(.title)
                .bold()

            Text("SAM includes Apple Intelligence for on-device coaching. For deeper reasoning, download the Qwen 3 8B model:")
                .samFont(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Richer meeting summaries and note analysis")
                BulletPoint("More nuanced coaching recommendations")
                BulletPoint("Better strategic business insights")
            }
            .padding(.leading, 8)

            Text("The download is approximately 4.5 GB and runs in the background — you can start using SAM immediately. All processing stays on your device.")
                .samFont(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Qwen 3 8B (4-bit)")
                                .samFont(.subheadline)
                            Text("~4.5 GB download")
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if mlxModelReady {
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .samFont(.caption)
                                .foregroundStyle(.green)
                                .fontWeight(.medium)
                        } else if isMlxDownloading {
                            Button("Cancel") {
                                cancelMlxDownload()
                            }
                            .controlSize(.small)
                        } else {
                            Button("Download") {
                                startMlxDownload()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                            .controlSize(.small)
                        }
                    }

                    if isMlxDownloading {
                        ProgressView(value: mlxDownloadProgress)
                            .progressViewStyle(.linear)
                        Text("Downloading… \(Int(mlxDownloadProgress * 100))%")
                            .samFont(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let error = mlxDownloadError {
                        Text(error)
                            .samFont(.caption)
                            .foregroundStyle(.red)
                    }

                    if mlxModelReady {
                        Text("Hybrid AI backend will be activated when you complete setup.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            let models = await MLXModelManager.shared.availableModels
            mlxModelReady = models.contains { $0.isDownloaded }
        }
    }

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .samFont(.title2)
                .bold()

            Text("SAM is now importing your data and identifying roles. You'll see coaching suggestions in the Today view within minutes.")
                .samFont(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Compact summary grid — always shows all 7 sources
            VStack(spacing: 4) {
                completionRow(icon: "person.crop.circle.fill", color: .blue, title: "Contacts",
                              enabled: !skippedContacts && !selectedGroupIdentifier.isEmpty)
                completionRow(icon: "calendar.circle.fill", color: .orange, title: "Calendar",
                              enabled: !skippedCalendar && !selectedCalendarIdentifier.isEmpty)
                completionRow(icon: "envelope.circle.fill", color: .blue, title: "Email",
                              enabled: mailAccessGranted && !skippedMail)
                completionRow(icon: "message.and.waveform.fill", color: .green, title: "iMessage & Calls",
                              enabled: BookmarkManager.shared.hasMessagesAccess || BookmarkManager.shared.hasCallHistoryAccess)
                completionRow(icon: "mic.circle.fill", color: .purple, title: "Dictation",
                              enabled: micPermissionGranted && speechPermissionGranted)
                completionRow(icon: "bell.circle.fill", color: .red, title: "Notifications",
                              enabled: notificationsGranted)
                completionRow(icon: "cpu.fill", color: .indigo, title: "Enhanced AI",
                              enabled: mlxModelReady)
            }
            .padding(.top, 4)

            Text("You can change any of these in Settings.")
                .samFont(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func completionRow(icon: String, color: Color, title: String, enabled: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(enabled ? color : color.opacity(0.3))
                .frame(width: 22)

            Text(title)
                .samFont(.callout)
                .foregroundStyle(enabled ? .primary : .secondary)

            Spacer()

            Image(systemName: enabled ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 14))
                .foregroundStyle(enabled ? .green : .gray.opacity(0.5))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if currentStep != .welcome && currentStep != .complete {
                Button("Back") {
                    goBack()
                }
                .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if currentStep == .mailPermission {
                // Mail step uses Skip / Enable Email pair
                if mailAccessGranted {
                    alreadyEnabledBadge
                } else {
                    Button("Skip") {
                        skippedMail = true
                        stepReadiness[.mailPermission] = true
                        stepReadiness[.mailAddressSelection] = true
                        advanceToNextActiveStep()
                    }
                    .foregroundStyle(.secondary)
                }

                Button(mailAccessGranted ? "Continue" : "Enable Email") {
                    if mailAccessGranted {
                        Task { await goNext() }
                    } else {
                        Task { await checkMailPermission() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(mailAccessGranted ? .green : nil)
                .disabled(!mailAccessGranted && (hasNoMeContact || isCheckingMail))
            } else if currentStep == .microphonePermission {
                let micGranted = micPermissionGranted && speechPermissionGranted
                // Mic step uses Skip / Enable Dictation pair
                if micGranted {
                    alreadyEnabledBadge
                } else {
                    Button("Skip") {
                        skippedMicrophone = true
                        stepReadiness[.microphonePermission] = true
                        advanceToNextActiveStep()
                    }
                    .foregroundStyle(.secondary)
                }

                Button(micGranted ? "Continue" : "Enable Dictation") {
                    if micGranted {
                        advanceToNextActiveStep()
                    } else {
                        Task { await requestMicrophonePermission() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(micGranted ? .green : nil)
            } else if currentStep == .notificationsPermission {
                // Notifications step uses Skip / Enable Notifications pair
                if notificationsGranted {
                    alreadyEnabledBadge
                } else {
                    Button("Skip") {
                        skippedNotifications = true
                        stepReadiness[.notificationsPermission] = true
                        advanceToNextActiveStep()
                    }
                    .foregroundStyle(.secondary)
                }

                Button(notificationsGranted ? "Continue" : "Enable Notifications") {
                    if notificationsGranted {
                        advanceToNextActiveStep()
                    } else {
                        Task { await requestNotificationsPermission() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(notificationsGranted ? .green : nil)
            } else if currentStep == .contactsPermission {
                if contactsStatus == .authorized {
                    alreadyEnabledBadge
                } else if shouldShowSkip {
                    Button("Skip for Now") { skipCurrentStep() }
                        .foregroundStyle(.secondary)
                }
                Button(nextButtonTitle) { Task { await goNext() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(contactsStatus == .authorized ? .green : nil)
            } else if currentStep == .calendarPermission {
                if calendarStatus == .fullAccess {
                    alreadyEnabledBadge
                } else if shouldShowSkip {
                    Button("Skip for Now") { skipCurrentStep() }
                        .foregroundStyle(.secondary)
                }
                Button(nextButtonTitle) { Task { await goNext() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(calendarStatus == .fullAccess ? .green : nil)
            } else if currentStep == .communicationsPermission {
                let commsGranted = BookmarkManager.shared.hasMessagesAccess || BookmarkManager.shared.hasCallHistoryAccess
                if commsGranted {
                    alreadyEnabledBadge
                } else if shouldShowSkip {
                    Button("Skip for Now") { skipCurrentStep() }
                        .foregroundStyle(.secondary)
                }
                Button(commsGranted ? "Continue" : "Next") { Task { await goNext() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(commsGranted ? .green : nil)
            } else if currentStep == .contactsGroupSelection {
                let groupReady = !selectedGroupIdentifier.isEmpty && selectedGroupIdentifier != "__create_sam__"
                if groupReady {
                    alreadyEnabledBadgeWith(text: "Already configured")
                } else if shouldShowSkip {
                    Button("Skip for Now") { skipCurrentStep() }
                        .foregroundStyle(.secondary)
                }
                Button(groupReady ? "Continue" : nextButtonTitle) { Task { await goNext() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canProceed)
                    .buttonStyle(.borderedProminent)
                    .tint(groupReady ? .green : nil)
            } else if currentStep == .calendarSelection {
                let calendarReady = !selectedCalendarIdentifier.isEmpty && selectedCalendarIdentifier != "__create_sam__"
                if calendarReady {
                    alreadyEnabledBadgeWith(text: "Already configured")
                } else if shouldShowSkip {
                    Button("Skip for Now") { skipCurrentStep() }
                        .foregroundStyle(.secondary)
                }
                Button(calendarReady ? "Continue" : nextButtonTitle) { Task { await goNext() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canProceed)
                    .buttonStyle(.borderedProminent)
                    .tint(calendarReady ? .green : nil)
            } else if currentStep == .mailAddressSelection {
                let addressReady = !selectedMailAddresses.isEmpty || meEmailAddresses.count <= 1
                if addressReady {
                    alreadyEnabledBadgeWith(text: "Already configured")
                } else if shouldShowSkip {
                    Button("Skip for Now") { skipCurrentStep() }
                        .foregroundStyle(.secondary)
                }
                Button(addressReady ? "Continue" : nextButtonTitle) { Task { await goNext() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(addressReady ? .green : nil)
            } else if currentStep == .aiSetup {
                if mlxModelReady {
                    alreadyEnabledBadgeWith(text: "Model ready")
                } else if shouldShowSkip {
                    Button("Skip for Now") { skipCurrentStep() }
                        .foregroundStyle(.secondary)
                }
                Button(mlxModelReady ? "Finish Setup" : nextButtonTitle) { Task { await goNext() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(mlxModelReady ? .green : nil)
            } else {
                // Welcome + complete steps (no skip/badge needed)
                Button(nextButtonTitle) {
                    Task { await goNext() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canProceed)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    /// Green checkmark shown in footer when a permission is already granted.
    private var alreadyEnabledBadge: some View {
        alreadyEnabledBadgeWith(text: "Permission granted")
    }

    /// Green checkmark with custom label text.
    private func alreadyEnabledBadgeWith(text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shouldShowSkip: Bool {
        switch currentStep {
        case .contactsPermission, .contactsGroupSelection, .calendarPermission, .calendarSelection, .mailAddressSelection, .communicationsPermission, .aiSetup:
            return true
        default:
            return false
        }
    }

    // Note: microphonePermission, mailPermission, and notificationsPermission have their own skip buttons in footer

    private var nextButtonTitle: String {
        switch currentStep {
        case .welcome:
            return totalSteps == 0 ? "Start Using SAM" : "Get Started"
        case .contactsPermission:
            return contactsStatus == .authorized ? "Next" : "Grant Access"
        case .contactsGroupSelection:
            return "Next"
        case .calendarPermission:
            return calendarStatus == .fullAccess ? "Next" : "Grant Access"
        case .calendarSelection:
            return "Next"
        case .mailPermission:
            return "Next" // not used; footer overrides
        case .mailAddressSelection:
            return "Next"
        case .communicationsPermission:
            return "Next"
        case .microphonePermission:
            return "Next" // not used; footer overrides
        case .notificationsPermission:
            return "Next" // not used; footer overrides
        case .aiSetup:
            return mlxModelReady ? "Finish Setup" : "Continue"
        case .complete:
            return "Start Using SAM"
        }
    }

    private var canProceed: Bool {
        switch currentStep {
        case .welcome:
            return preCheckComplete
        case .contactsPermission:
            return true // Always enabled - clicking triggers permission request or advances if already granted
        case .contactsGroupSelection:
            // Can proceed if group selected OR if user skipped contacts
            return (!selectedGroupIdentifier.isEmpty && selectedGroupIdentifier != "__create_sam__") || skippedContacts
        case .calendarPermission:
            return true // Always enabled - clicking triggers permission request or advances if already granted
        case .calendarSelection:
            // Can proceed if calendar selected OR if user skipped calendar
            return (!selectedCalendarIdentifier.isEmpty && selectedCalendarIdentifier != "__create_sam__") || skippedCalendar
        case .mailPermission:
            return true
        case .mailAddressSelection:
            return true
        case .communicationsPermission:
            return true
        case .microphonePermission:
            return true
        case .notificationsPermission:
            return true // footer handles skip/enable; this is unused
        case .aiSetup:
            return true
        case .complete:
            return true
        }
    }

    // MARK: - Navigation

    private func skipCurrentStep() {
        switch currentStep {
        case .contactsPermission:
            skippedContacts = true
            stepReadiness[.contactsPermission] = true
            stepReadiness[.contactsGroupSelection] = true
        case .contactsGroupSelection:
            skippedContacts = true
            stepReadiness[.contactsGroupSelection] = true
        case .calendarPermission:
            skippedCalendar = true
            stepReadiness[.calendarPermission] = true
            stepReadiness[.calendarSelection] = true
        case .calendarSelection:
            skippedCalendar = true
            stepReadiness[.calendarSelection] = true
        case .mailAddressSelection:
            stepReadiness[.mailAddressSelection] = true
        case .communicationsPermission:
            skippedCommunications = true
            stepReadiness[.communicationsPermission] = true
        case .aiSetup:
            skippedAISetup = true
            stepReadiness[.aiSetup] = true
        default:
            break
        }
        advanceToNextActiveStep()
    }

    private func goNext() async {
        switch currentStep {
        case .welcome:
            advanceToNextActiveStep()

        case .contactsPermission:
            if contactsStatus != .authorized {
                await requestContactsPermission()
                // requestContactsPermission handles navigation on grant
            } else {
                advanceToNextActiveStep()
            }

        case .contactsGroupSelection:
            advanceToNextActiveStep()

        case .calendarPermission:
            if calendarStatus != .fullAccess {
                await requestCalendarPermission()
                // requestCalendarPermission handles navigation on grant
            } else {
                advanceToNextActiveStep()
            }

        case .calendarSelection:
            advanceToNextActiveStep()

        case .mailPermission:
            if mailAccessGranted {
                advanceToNextActiveStep()
            }
            // If not granted, checkMailPermission handles navigation

        case .mailAddressSelection:
            applyMailFilterRules()
            advanceToNextActiveStep()

        case .communicationsPermission:
            advanceToNextActiveStep()

        case .microphonePermission:
            advanceToNextActiveStep()

        case .notificationsPermission:
            advanceToNextActiveStep()

        case .aiSetup:
            advanceToNextActiveStep()

        case .complete:
            saveSelections()
            await triggerImports()
            dismiss()
        }
    }

    private func goBack() {
        retreatToPreviousActiveStep()
    }

    // MARK: - Permissions

    private func requestContactsPermission() async {
        isRequestingContacts = true
        let granted = await ContactsService.shared.requestAuthorization()
        contactsStatus = granted ? .authorized : .denied
        isRequestingContacts = false

        if granted {
            ContactsImportCoordinator.shared.permissionGranted()
            stepReadiness[.contactsPermission] = true
            // Load groups and check if SAM auto-selected
            await loadGroups()
            if !selectedGroupIdentifier.isEmpty && selectedGroupIdentifier != "__create_sam__" {
                stepReadiness[.contactsGroupSelection] = true
            }
            advanceToNextActiveStep()
        }
    }

    private func requestCalendarPermission() async {
        isRequestingCalendar = true
        let granted = await CalendarService.shared.requestAuthorization()
        calendarStatus = granted ? .fullAccess : .denied
        isRequestingCalendar = false

        if granted {
            stepReadiness[.calendarPermission] = true
            // Load calendars and check if SAM auto-selected
            await loadCalendars()
            if !selectedCalendarIdentifier.isEmpty && selectedCalendarIdentifier != "__create_sam__" {
                stepReadiness[.calendarSelection] = true
            }
            advanceToNextActiveStep()
        }
    }

    private func checkMailPermission() async {
        isCheckingMail = true
        mailAccessError = nil
        // Prefer direct database access (folder bookmark) over AppleScript
        let error = MailImportCoordinator.shared.requestDirectMailAccess()
        isCheckingMail = false
        if let error {
            mailAccessError = error
        } else {
            mailAccessGranted = true
            stepReadiness[.mailPermission] = true
            // Mark address step ready if <=1 email
            if meEmailAddresses.count <= 1 {
                stepReadiness[.mailAddressSelection] = true
            }
            // After granting, advance to next active step
            if !meEmailAddresses.isEmpty {
                advanceToNextActiveStep()
            }
        }
    }

    // MARK: - Microphone & Speech

    private func requestMicrophonePermission() async {
        // Request speech recognition
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        speechPermissionGranted = speechGranted

        // Request microphone access
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        micPermissionGranted = micGranted

        if micGranted && speechGranted {
            stepReadiness[.microphonePermission] = true
            advanceToNextActiveStep()
        }
    }

    // MARK: - Me Contact

    private func fetchMeEmailAddresses() async {
        let meContact = await ContactsService.shared.fetchMeContact(keys: .detail)
        if let me = meContact {
            let emails = me.emailAddresses.map { $0.lowercased() }
            meEmailAddresses = emails
            selectedMailAddresses = Set(emails) // All selected by default
            hasNoMeContact = false
        } else {
            meEmailAddresses = []
            hasNoMeContact = true
        }
    }

    private func mailAddressBinding(for email: String) -> Binding<Bool> {
        Binding(
            get: { selectedMailAddresses.contains(email) },
            set: { isOn in
                if isOn {
                    selectedMailAddresses.insert(email)
                } else {
                    selectedMailAddresses.remove(email)
                }
            }
        )
    }

    private func applyMailFilterRules() {
        let rules = selectedMailAddresses.map { MailFilterRule(id: UUID(), value: $0) }
        MailImportCoordinator.shared.setFilterRules(rules)
        // Apply scan depth to all import coordinators
        MailImportCoordinator.shared.setLookbackDays(onboardingLookbackDays)
        CommunicationsImportCoordinator.shared.setLookbackDays(onboardingLookbackDays)
        CalendarImportCoordinator.shared.lookbackDays = onboardingLookbackDays
    }

    // MARK: - Groups & Calendars

    private func loadGroups() async {
        isLoadingGroups = true
        let groups = await ContactsService.shared.fetchGroups()
        await MainActor.run {
            availableGroups = groups

            // Auto-select SAM if exists
            if let samGroup = groups.first(where: { $0.name == "SAM" }) {
                selectedGroupIdentifier = samGroup.identifier
            }

            isLoadingGroups = false
        }
    }

    private func createSAMGroup() async {
        let success = await ContactsService.shared.createGroup(named: "SAM")
        if success {
            await loadGroups()
        }
    }

    private func loadCalendars() async {
        isLoadingCalendars = true
        let calendars = await CalendarService.shared.fetchCalendars()
        await MainActor.run {
            if let calendars = calendars {
                availableCalendars = calendars

                // Auto-select SAM if exists
                if let samCalendar = calendars.first(where: { $0.title == "SAM" }) {
                    selectedCalendarIdentifier = samCalendar.id
                }
            }

            isLoadingCalendars = false
        }
    }

    private func createSAMCalendar() async {
        let success = await CalendarService.shared.createCalendar(titled: "SAM")
        if success {
            await loadCalendars()
        }
    }

    // MARK: - Save & Import

    private func saveSelections() {
        // Only save if not skipped
        if !skippedContacts && !selectedGroupIdentifier.isEmpty {
            UserDefaults.standard.set(selectedGroupIdentifier, forKey: "selectedContactGroupIdentifier")
            UserDefaults.standard.set(true, forKey: "sam.contacts.enabled")
            ContactsImportCoordinator.shared.selectedGroupDidChange()
        } else {
            UserDefaults.standard.set(false, forKey: "sam.contacts.enabled")
        }

        if !skippedCalendar && !selectedCalendarIdentifier.isEmpty {
            UserDefaults.standard.set(selectedCalendarIdentifier, forKey: "selectedCalendarIdentifier")
            UserDefaults.standard.set(true, forKey: "calendarAutoImportEnabled")
        } else {
            UserDefaults.standard.set(false, forKey: "calendarAutoImportEnabled")
        }

        if !skippedMail && mailAccessGranted {
            MailImportCoordinator.shared.setMailEnabled(true)
        }

        if !skippedCommunications && (BookmarkManager.shared.hasMessagesAccess || BookmarkManager.shared.hasCallHistoryAccess) {
            UserDefaults.standard.set(true, forKey: "sam.comms.enabled")
        }

        if mlxModelReady {
            UserDefaults.standard.set("hybrid", forKey: "aiBackend")
        }

        // Always mark onboarding complete, even if permissions were skipped
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "sam.onboarding.completedAt")
    }

    private func triggerImports() async {
        // Only trigger imports for enabled sources
        if !skippedContacts && !selectedGroupIdentifier.isEmpty {
            await ContactsImportCoordinator.shared.importNow()
        }

        if !skippedCalendar && !selectedCalendarIdentifier.isEmpty {
            await CalendarImportCoordinator.shared.importNow()
        }

        if !skippedMail && mailAccessGranted {
            MailImportCoordinator.shared.startAutoImport()
        }

        // Run role deduction after imports settle
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            await RoleDeductionEngine.shared.deduceRoles()
        }
    }

    // MARK: - System Settings

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notifications

    private func requestNotificationsPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                notificationsGranted = true
                notificationsDenied = false
                stepReadiness[.notificationsPermission] = true
                advanceToNextActiveStep()
            } else {
                notificationsDenied = true
                notificationsGranted = false
            }
        } catch {
            notificationsDenied = true
        }
    }

    // MARK: - MLX Download

    private func startMlxDownload() {
        isMlxDownloading = true
        mlxDownloadError = nil

        Task {
            do {
                let modelID = "mlx-community/Qwen3-8B-4bit"

                // Start download
                try await MLXModelManager.shared.downloadModel(id: modelID)

                // Poll progress
                while await MLXModelManager.shared.isDownloading {
                    let progress = await MLXModelManager.shared.downloadProgress ?? 0
                    await MainActor.run {
                        mlxDownloadProgress = progress
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
                }

                // Check completion
                let updatedModels = await MLXModelManager.shared.availableModels
                let isReady = updatedModels.contains { $0.isDownloaded }
                await MainActor.run {
                    mlxModelReady = isReady
                    isMlxDownloading = false
                    mlxDownloadProgress = isReady ? 1.0 : mlxDownloadProgress
                }
            } catch {
                await MainActor.run {
                    mlxDownloadError = error.localizedDescription
                    isMlxDownloading = false
                }
            }
        }
    }

    private func cancelMlxDownload() {
        Task {
            await MLXModelManager.shared.cancelDownload()
            await MainActor.run {
                isMlxDownloading = false
            }
        }
    }
}

// MARK: - Helper Views

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .samFont(.body)
        }
    }
}

private struct BulletPoint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .samFont(.body)
            Text(text)
                .samFont(.body)
        }
    }
}

#Preview {
    OnboardingView()
}
