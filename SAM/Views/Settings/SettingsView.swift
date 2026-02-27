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
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SettingsView")

struct SettingsView: View {

    @State private var selectedTab: SettingsTab = .permissions

    enum SettingsTab: String, CaseIterable, Identifiable {
        case permissions = "Permissions"
        case dataSources = "Data Sources"
        case ai = "AI"
        case general = "General"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .permissions: return "lock.shield"
            case .dataSources: return "arrow.down.doc"
            case .ai: return "brain"
            case .general: return "gearshape"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
                .tag(SettingsTab.permissions)

            DataSourcesSettingsView()
                .tabItem {
                    Label("Data Sources", systemImage: "arrow.down.doc")
                }
                .tag(SettingsTab.dataSources)

            AISettingsView()
                .tabItem {
                    Label("AI", systemImage: "brain")
                }
                .tag(SettingsTab.ai)

            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
        }
        .frame(width: 650, height: 600)
    }
}

// MARK: - Data Sources Settings (consolidated tab)

struct DataSourcesSettingsView: View {
    var body: some View {
        Form {
            Section {
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

                DisclosureGroup {
                    EvernoteImportSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Evernote Import", systemImage: "square.and.arrow.down")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Settings (consolidated tab)

struct AISettingsView: View {
    var body: some View {
        Form {
            Section {
                DisclosureGroup {
                    BusinessProfileSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Business Profile", systemImage: "building.2")
                }

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

                DisclosureGroup {
                    ComplianceSettingsContent()
                        .padding(.top, 8)
                } label: {
                    Label("Compliance", systemImage: "checkmark.shield")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions Settings

struct PermissionsSettingsView: View {

    @State private var contactsStatus: String = "Checking..."
    @State private var calendarStatus: String = "Checking..."
    @State private var isRequestingContacts = false
    @State private var isRequestingCalendar = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Permissions", systemImage: "lock.shield")
                            .font(.title2)
                            .bold()

                        Text("SAM needs access to Contacts and Calendar to function.")
                            .foregroundStyle(.secondary)
                            .font(.body)
                    }
                    .padding(.bottom, 10)

                    Divider()

                    // Contacts Permission
                    HStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.blue)
                            .frame(width: 40)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Contacts")
                                .font(.headline)

                            Text("Import and sync people from your Contacts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(contactsStatus)
                                .font(.caption)
                                .foregroundStyle(contactsStatusColor)

                            if contactsStatus != "Authorized" {
                                Button(isRequestingContacts ? "Requesting..." : "Request Access") {
                                    requestContactsPermission()
                                }
                                .disabled(isRequestingContacts)
                            }
                        }
                    }
                    .padding(.vertical, 8)

                    Divider()

                    // Calendar Permission
                    HStack(spacing: 16) {
                        Image(systemName: "calendar.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.orange)
                            .frame(width: 40)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Calendar")
                                .font(.headline)

                            Text("Import events and create evidence items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(calendarStatus)
                                .font(.caption)
                                .foregroundStyle(calendarStatusColor)

                            if calendarStatus != "Authorized" {
                                Button(isRequestingCalendar ? "Requesting..." : "Request Access") {
                                    requestCalendarPermission()
                                }
                                .disabled(isRequestingCalendar)
                            }
                        }
                    }
                    .padding(.vertical, 8)

                    Divider()

                    // Help Text
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About Permissions")
                            .font(.headline)

                        Text("If you've previously denied access, you'll need to enable it in System Settings:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("System Settings → Privacy & Security → Contacts/Calendar → SAM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)

                        Button("Open System Settings") {
                            openSystemSettings()
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 8)
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .task {
            await checkPermissions()
        }
    }

    private var contactsStatusColor: Color {
        switch contactsStatus {
        case "Authorized": return .green
        case "Denied": return .red
        default: return .secondary
        }
    }

    private var calendarStatusColor: Color {
        switch calendarStatus {
        case "Authorized": return .green
        case "Denied": return .red
        default: return .secondary
        }
    }

    private func checkPermissions() async {
        let contactsAuth = CNContactStore.authorizationStatus(for: .contacts)
        contactsStatus = authStatusString(contactsAuth)

        let calendarAuth = await CalendarService.shared.authorizationStatus()
        calendarStatus = authStatusString(calendarAuth)
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

    private func openSystemSettings() {
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

                    Text("Select which Contacts group SAM should access. Only contacts in this group will be imported.")
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

            // Manual import button
            Button("Import Now") {
                Task {
                    await coordinator.importNow()
                }
            }
            .disabled(coordinator.importStatus == .importing || selectedGroupIdentifier.isEmpty || authorizationStatus != .authorized)
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

            // Lookback period
            Picker("Look back", selection: Binding(
                get: { coordinator.lookbackDays },
                set: { coordinator.lookbackDays = $0 }
            )) {
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("All").tag(0)
            }

            if coordinator.lookbackDays == 0 {
                Text("First import will scan all available calendar history. Subsequent imports use incremental sync.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("How far back to look for calendar events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            // Manual import button
            Button("Import Now") {
                Task {
                    await coordinator.importNow()
                }
            }
            .disabled(coordinator.importStatus == .importing || selectedCalendarIdentifier.isEmpty || authorizationStatus != .fullAccess)
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

    @State private var customNotePrompt: String = UserDefaults.standard.string(forKey: "sam.ai.notePrompt") ?? ""
    @State private var customEmailPrompt: String = UserDefaults.standard.string(forKey: "sam.ai.emailPrompt") ?? ""
    @State private var insightGenerator = InsightGenerator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Note Analysis Prompt
            VStack(alignment: .leading, spacing: 8) {
                Text("Note Analysis Prompt")
                    .font(.headline)

                Text("Customize the system prompt used when analyzing notes with on-device AI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $customNotePrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if customNotePrompt.isEmpty {
                            Text("Using default prompt...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 4)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: customNotePrompt) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "sam.ai.notePrompt")
                    }

                Button("Reset to Default") {
                    customNotePrompt = ""
                    UserDefaults.standard.removeObject(forKey: "sam.ai.notePrompt")
                }
                .disabled(customNotePrompt.isEmpty)
            }

            Divider()

            // Email Analysis Prompt
            VStack(alignment: .leading, spacing: 8) {
                Text("Email Analysis Prompt")
                    .font(.headline)

                Text("Customize the system prompt used when analyzing emails with on-device AI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $customEmailPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if customEmailPrompt.isEmpty {
                            Text("Using default prompt...")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 4)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: customEmailPrompt) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "sam.ai.emailPrompt")
                    }

                Button("Reset to Default") {
                    customEmailPrompt = ""
                    UserDefaults.standard.removeObject(forKey: "sam.ai.emailPrompt")
                }
                .disabled(customEmailPrompt.isEmpty)
            }

            Divider()

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
                    Text("Relationship alert threshold:")
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

                Text("Alert when a contact hasn't been reached within this period.")
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

    @State private var showResetConfirmation = false
    @State private var showOnboardingResetConfirmation = false
    @AppStorage("autoResetOnVersionChange") private var autoResetOnVersionChange = false
    @AppStorage("autoDetectPermissionLoss") private var autoDetectPermissionLoss = true
    @State private var silenceTimeout: Double = {
        let stored = UserDefaults.standard.double(forKey: "sam.dictation.silenceTimeout")
        return stored > 0 ? stored : 2.0
    }()

    // Backup/restore
    @State private var backupCoordinator = BackupCoordinator.shared
    @State private var showImportFilePicker = false
    @State private var showImportConfirmation = false
    @State private var pendingImportURL: URL?
    @State private var pendingImportPreview: ImportPreview?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
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
                            Text("Build:")
                                .foregroundStyle(.secondary)
                            Text(buildNumber)
                        }
                    }

                    Divider()

                    // Dictation
                    dictationSection

                    Divider()

                    // Data Backup
                    dataBackupSection

                    Divider()

                    // Auto-reset section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Automatic Reset")
                            .font(.headline)

                        Toggle("Auto-detect permission loss (recommended)", isOn: $autoDetectPermissionLoss)

                        Text("When enabled, SAM will automatically reset onboarding if permissions are lost (e.g., after rebuilding the app in Xcode). This saves you from manually resetting permissions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !autoDetectPermissionLoss {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)

                                Text("Auto-detection disabled. You'll need to manually reset if permissions are lost.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.top, 4)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        Toggle("Reset on version change", isOn: $autoResetOnVersionChange)

                        Text("When enabled, SAM will automatically reset onboarding and clear all data whenever the app version changes. Useful for development and testing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if autoResetOnVersionChange {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)

                                Text("Automatic reset is enabled. Your data will be cleared on version updates.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.top, 4)
                        }
                    }

                    Divider()

                    // Development / Reset section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Manual Reset")
                            .font(.headline)

                        Text("These actions are intended for development and testing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button("Reset Onboarding") {
                                showOnboardingResetConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .alert("Reset Onboarding?", isPresented: $showOnboardingResetConfirmation) {
                                Button("Cancel", role: .cancel) { }
                                Button("Reset", role: .destructive) {
                                    resetOnboarding()
                                }
                            } message: {
                                Text("This will mark onboarding as incomplete. The onboarding sheet will appear on next app launch.")
                            }

                            Button("Clear All Data") {
                                showResetConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .alert("Clear All Data?", isPresented: $showResetConfirmation) {
                                Button("Cancel", role: .cancel) { }
                                Button("Clear Data", role: .destructive) {
                                    clearAllData()
                                }
                            } message: {
                                Text("This will delete all people, evidence, and settings. You will need to re-import from Contacts and Calendar.")
                            }
                        }
                    }

                }
                .padding()
            }
        }
        .formStyle(.grouped)
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
    }

    private func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        logger.notice("Onboarding reset — will show on next launch")
    }

    private func clearAllData() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "selectedGroupIdentifier")
        UserDefaults.standard.removeObject(forKey: "selectedCalendarIdentifier")
        UserDefaults.standard.removeObject(forKey: "autoImportContacts")
        UserDefaults.standard.removeObject(forKey: "lastContactsImport")
        UserDefaults.standard.removeObject(forKey: "lastCalendarImport")

        logger.notice("All settings cleared. SwiftData requires app restart to fully reset.")
    }

    // MARK: - Data Backup Section

    private var dataBackupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data Backup")
                .font(.headline)

            Text("Export all your data to a .sambackup file or restore from a previous backup. Importing replaces all existing data.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Export Backup...") {
                    let panel = NSSavePanel()
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    panel.nameFieldStringValue = "SAM-Backup-\(formatter.string(from: .now)).sambackup"
                    panel.allowedContentTypes = [.samBackup]
                    panel.canCreateDirectories = true

                    if panel.runModal() == .OK, let url = panel.url {
                        Task {
                            await backupCoordinator.exportBackup(to: url)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(backupCoordinator.status == .exporting || backupCoordinator.status == .importing)

                Button("Import Backup...") {
                    showImportFilePicker = true
                }
                .buttonStyle(.bordered)
                .disabled(backupCoordinator.status == .exporting || backupCoordinator.status == .importing)
            }

            // Status display
            switch backupCoordinator.status {
            case .idle:
                EmptyView()
            case .exporting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(backupCoordinator.progress.isEmpty ? "Exporting..." : backupCoordinator.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .importing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(backupCoordinator.progress.isEmpty ? "Importing..." : backupCoordinator.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .validating:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating backup...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .success(let message):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
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
