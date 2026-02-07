//
//  SamSettingsView.swift
//  SAM_crm
//
//  Created by David Snyder on 2/2/26.
//

import SwiftUI
import AppKit
import EventKit
import Contacts

struct SamSettingsView: View {
    // Calendar settings
    @AppStorage("sam.calendar.import.enabled") private var calendarImportEnabled: Bool = true
    @AppStorage("sam.calendar.selectedCalendarID") private var selectedCalendarID: String = ""
    @AppStorage("sam.calendar.import.windowPastDays") private var pastDays: Int = 60
    @AppStorage("sam.calendar.import.windowFutureDays") private var futureDays: Int = 30

    // Contacts settings (for later)
    @AppStorage("sam.contacts.enabled") private var contactsEnabled: Bool = true
    @AppStorage("sam.contacts.selectedGroupIdentifier") private var selectedGroupIdentifier: String = ""

    /// The tab index that the Settings window should open to.
    /// The static helper writes directly to UserDefaults so that the nudge
    /// sheet (or any other call-site) can set the target tab *before* the
    /// Settings window is created.  The `@AppStorage` property below reads
    /// the same key, so SwiftUI will observe the value and keep the TabView
    /// selection in sync.
    static var selectedTab: Int {
        get { UserDefaults.standard.integer(forKey: "sam.settings.selectedTab") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.settings.selectedTab") }
    }

    /// Instance-level, SwiftUI-observable mirror of the static key.
    /// This is what the TabView binds to; @AppStorage publishes changes
    /// whenever the underlying UserDefaults value is written.
    @AppStorage("sam.settings.selectedTab")
    private var _selectedTab: Int = 0

    @State private var calendars: [EKCalendar] = []
    @State private var contactGroups: [CNGroup] = []

    // Use the centralized permissions manager
    // With @Observable, no property wrapper is needed
    private let permissions = PermissionsManager.shared

    // MARK: - Static helpers

    /// Opens the macOS Settings window and lands on the Permissions tab.
    /// Safe to call from anywhere; it's a no-op if Settings is already visible.
    static func openToPermissions() {
        SamSettingsView.selectedTab = 0   // Permissions is tab 0

        // `showPreferencesWindow:` is the standard action that SwiftUI's
        // Settings scene registers.  We use a string-based Selector here
        // because it's a static helper with no access to an @Environment
        // openSettings action.  The action is dispatched up the responder
        // chain; SwiftUI's Settings scene handler picks it up.
        let action = Selector(("showPreferencesWindow:"))
        NSApplication.shared.sendAction(action, to: nil, from: nil)
    }

    var body: some View {
        TabView(selection: $_selectedTab) {
            PermissionsTab(
                calendars: $calendars,
                calendarAuthStatus: permissions.calendarStatus,
                contactsAuthStatus: permissions.contactsStatus,
                selectedCalendarID: $selectedCalendarID,
                selectedGroupIdentifier: $selectedGroupIdentifier,
                contactGroups: $contactGroups,
                requestCalendarAccessAndReload: requestCalendarAccessAndReload,
                requestContactsAccess: requestContactsAccess,
                reloadCalendars: reloadCalendars,
                reloadContactGroups: reloadContactGroups,
                createAndSelectSAMCalendar: createAndSelectSAMCalendar,
                createAndSelectSAMGroup: createAndSelectSAMGroup
            )
            .tabItem {
                Label("Permissions", systemImage: "hand.raised")
            }
            .tag(0)

            ImportTab(
                calendarImportEnabled: $calendarImportEnabled,
                selectedCalendarID: $selectedCalendarID,
                calendarAuthStatus: permissions.calendarStatus,
                pastDays: $pastDays,
                futureDays: $futureDays,
                importNow: importCalendarEvidenceNow
            )
            .tabItem {
                Label("Import", systemImage: "arrow.down.circle")
            }
            .tag(1)

            ContactsTab(
                contactsEnabled: $contactsEnabled,
                contactsAuthStatus: permissions.contactsStatus
            )
            .tabItem {
                Label("Contacts", systemImage: "person.crop.circle")
            }
            .tag(2)

            BackupTab()
            .tabItem {
                Label("Backup", systemImage: "lock.shield")
            }
            .tag(3)

            #if DEBUG
            DevelopmentTab()
            .tabItem {
                Label("Development", systemImage: "hammer")
            }
            .tag(4)
            #endif
        }
        .padding(20)
        .frame(width: 680, height: 460)
        .onAppear {
            Task { @MainActor in
                permissions.refreshStatus()
                await Task.yield()
                if permissions.hasCalendarAccess {
                    reloadCalendars()
                }
                if permissions.hasContactsAccess {
                    reloadContactGroups()
                }
            }
        }
    }

    private func importCalendarEvidenceNow() async {
        await CalendarImportCoordinator.shared.importNow()
    }

    // MARK: - Permissions

    @MainActor
    private func requestCalendarAccessAndReload() async {
        // Request calendar access via the centralized manager
        let granted = await permissions.requestCalendarAccess()

        if granted {
            reloadCalendars()
            // Permission just became available — tell the import coordinator
            // to try again.
            CalendarImportCoordinator.shared.kick(reason: "calendar permission granted")
        }
    }
    
    
    private func requestContactsAccess() async {
        // Request contacts access via the centralized manager
        let granted = await permissions.requestContactsAccess()
        
        if granted {
            reloadContactGroups()
            ContactsImportCoordinator.shared.kick(reason: "contacts permission granted")
        }
    }

    // MARK: - Calendars

    private func reloadCalendars() {
        calendars = permissions.eventStore.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // If the selected calendar no longer exists, clear selection.
        if !selectedCalendarID.isEmpty,
           calendars.first(where: { $0.calendarIdentifier == selectedCalendarID }) == nil {
            selectedCalendarID = ""
        }
    }

    private func createAndSelectSAMCalendar() async {
        guard permissions.hasCalendarAccess else { return }

        let eventStore = permissions.eventStore
        let cal = EKCalendar(for: .event, eventStore: eventStore)
        cal.title = "SAM"

        // Best default: same source as the default calendar for new events.
        if let source = eventStore.defaultCalendarForNewEvents?.source {
            cal.source = source
        } else if let firstSource = eventStore.sources.first {
            cal.source = firstSource
        }

        do {
            try eventStore.saveCalendar(cal, commit: true)
            reloadCalendars()
            selectedCalendarID = cal.calendarIdentifier
        } catch {
            // Gentle alert later
        }
    }

    // MARK: - Contacts Groups

    private func reloadContactGroups() {
        do {
            contactGroups = try permissions.contactStore.groups(matching: nil)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !selectedGroupIdentifier.isEmpty,
               !contactGroups.contains(where: { $0.identifier == selectedGroupIdentifier }) {
                selectedGroupIdentifier = ""
            }
        } catch {
            contactGroups = []
        }
    }

    private func createAndSelectSAMGroup() async {
        guard permissions.hasContactsAccess else { return }
        do {
            let store = permissions.contactStore
            let newGroup = CNMutableGroup()
            newGroup.name = "SAM"

            let request = CNSaveRequest()
            request.add(newGroup, toContainerWithIdentifier: nil)
            try store.execute(request)

            reloadContactGroups()
            if let created = contactGroups.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "SAM" }) {
                selectedGroupIdentifier = created.identifier
            }
        } catch {
            // Gentle alert later
        }
    }
}

// MARK: - Tabs

private struct PermissionsTab: View {
    @Binding var calendars: [EKCalendar]

    let calendarAuthStatus: EKAuthorizationStatus
    let contactsAuthStatus: CNAuthorizationStatus

    @Binding var selectedCalendarID: String
    @Binding var selectedGroupIdentifier: String
    @Binding var contactGroups: [CNGroup]

    let requestCalendarAccessAndReload: () async -> Void
    let requestContactsAccess: () async -> Void
    let reloadCalendars: () -> Void
    let reloadContactGroups: () -> Void
    let createAndSelectSAMCalendar: () async -> Void
    let createAndSelectSAMGroup: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox {
                    Text("SAM asks for access so it can observe only the calendar you choose and use Contacts as the source of identity. SAM does not modify data without your action.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Calendar") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Status", systemImage: "calendar")
                            Spacer()
                            Text(statusText(calendarAuthStatus))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button((calendarAuthStatus == .fullAccess || calendarAuthStatus == .writeOnly) ? "Refresh Calendars" : "Request Calendar Access") {
                                Task { await requestCalendarAccessAndReload() }
                            }

                            if calendarAuthStatus == .fullAccess || calendarAuthStatus == .writeOnly {
                                Button("Reload") { reloadCalendars() }
                            }
                        }

                        HStack {
                            Text("Observed calendar")
                            Spacer()
                            Picker("", selection: Binding(
                                get: {
                                    calendars.contains(where: { $0.calendarIdentifier == selectedCalendarID })
                                    ? selectedCalendarID
                                    : ""
                                },
                                set: { selectedCalendarID = $0 }
                            )) {
                                Text("Not selected").tag("")
                                ForEach(calendars, id: \.calendarIdentifier) { cal in
                                    Text(cal.title).tag(cal.calendarIdentifier)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 320)
                            .disabled(!(calendarAuthStatus == .fullAccess || calendarAuthStatus == .writeOnly))
                            .onChange(of: calendars) { _, newValue in
                                if !selectedCalendarID.isEmpty,
                                   !newValue.contains(where: { $0.calendarIdentifier == selectedCalendarID }) {
                                    selectedCalendarID = ""
                                }
                            }
                            .onChange(of: selectedCalendarID) { _, newValue in
                                // A calendar was just picked (or cleared).
                                // Kick the coordinator so it imports
                                // immediately rather than waiting for the
                                // next throttle window.
                                if !newValue.isEmpty {
                                    CalendarImportCoordinator.shared.kick(reason: "calendar selection changed")
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            if !samCalendarExists {
                                Button("Create \"SAM\" Calendar") {
                                    Task { await createAndSelectSAMCalendar() }
                                }
                                .disabled(!(calendarAuthStatus == .fullAccess || calendarAuthStatus == .writeOnly))
                            }

                            Button("Open Calendar") {
                                // Open Calendar.app directly (more reliable than calshow:// on macOS)
                                let appURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
                                let config = NSWorkspace.OpenConfiguration()
                                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                                    if error != nil {
                                        // Fallback for unusual system setups: try opening by bundle identifier via runningApplications list
                                        // or simply open the URL again without expecting an app instance.
                                        NSWorkspace.shared.open(appURL)
                                    }
                                }
                            }
                        }
                        if calendarAuthStatus == .writeOnly {
                            Text("Calendar permission is Add Only. SAM can create calendars/events, but cannot read events for import until Full Access is granted in System Settings → Privacy & Security → Calendars.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("SAM will only read events from the selected calendar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Contacts") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Status", systemImage: "person.crop.circle")
                            Spacer()
                            Text(statusText(contactsAuthStatus))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button(contactsAuthStatus == .authorized ? "Reload Groups" : "Request Contacts Access") {
                                Task {
                                    if contactsAuthStatus == .authorized {
                                        reloadContactGroups()
                                    } else {
                                        await requestContactsAccess()
                                    }
                                }
                            }

                            if contactsAuthStatus == .authorized {
                                Button("Sync Now") {
                                    Task {
                                        await ContactsImportCoordinator.shared.importNow()
                                    }
                                }
                            }
                        }

                        HStack {
                            Text("Observed group")
                            Spacer()
                            Picker("", selection: Binding(
                                get: {
                                    contactGroups.contains(where: { $0.identifier == selectedGroupIdentifier })
                                    ? selectedGroupIdentifier
                                    : ""
                                },
                                set: { selectedGroupIdentifier = $0 }
                            )) {
                                Text("Not selected").tag("")
                                ForEach(contactGroups, id: \.identifier) { group in
                                    Text(group.name).tag(group.identifier)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 320)
                            .disabled(contactsAuthStatus != .authorized)
                            .onChange(of: contactGroups) { _, newValue in
                                if !selectedGroupIdentifier.isEmpty,
                                   !newValue.contains(where: { $0.identifier == selectedGroupIdentifier }) {
                                    selectedGroupIdentifier = ""
                                }
                            }
                            .onChange(of: selectedGroupIdentifier) { _, newValue in
                                if !newValue.isEmpty {
                                    ContactsImportCoordinator.shared.kick(reason: "contacts group selection changed")
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            if !samGroupExists {
                                Button("Create \"SAM\" Group") {
                                    Task { await createAndSelectSAMGroup() }
                                }
                                .disabled(contactsAuthStatus != .authorized)
                            }

                            Button("Open Contacts") {
                                let appURL = URL(fileURLWithPath: "/System/Applications/Contacts.app")
                                NSWorkspace.shared.open(appURL)
                            }
                        }

                        Text("SAM will only read contacts from the selected group.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private var samCalendarExists: Bool {
        calendars.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == "SAM" }
    }

    private var samGroupExists: Bool {
        contactGroups.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "SAM" }
    }

    private func statusText(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not requested"
        case .restricted:    return "Restricted"
        case .denied:        return "Denied"
        case .fullAccess:    return "Granted (Full Access)"
        case .writeOnly:     return "Granted (Add Only)"
        @unknown default:    return "Unknown"
        }
    }

    private func statusText(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not requested"
        case .restricted:    return "Restricted"
        case .denied:        return "Denied"
        case .authorized:    return "Granted"
        case .limited:       return "Limited"
        @unknown default:    return "Unknown"
        }
    }
}

private struct ImportTab: View {
    @Binding var calendarImportEnabled: Bool
    @Binding var selectedCalendarID: String
    let calendarAuthStatus: EKAuthorizationStatus

    @Binding var pastDays: Int
    @Binding var futureDays: Int

    let importNow: () async -> Void
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox("Calendar Import") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Calendar Import", isOn: $calendarImportEnabled)
                            .disabled(calendarAuthStatus != .fullAccess || selectedCalendarID.isEmpty)
                        if calendarAuthStatus == .writeOnly {
                            Text("Import requires Full Access to Calendars. Please grant Full Access in System Settings → Privacy & Security → Calendars.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button("Import Now") {
                                Task { await importNow() }
                            }
                            .disabled(calendarAuthStatus != .fullAccess || selectedCalendarID.isEmpty || !calendarImportEnabled)

                            Text("Imports events into Inbox → Needs Review")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Stepper(value: $pastDays, in: 7...365, step: 7) {
                            Text("Look back: \(pastDays) days")
                        }

                        Stepper(value: $futureDays, in: 7...365, step: 7) {
                            Text("Look ahead: \(futureDays) days")
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("SAM imports events incrementally from the selected calendar within this window.")
                            Text("Tip: Start with 60 days back and 30 days ahead.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                GroupBox("Safety") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("SAM observes only the calendar you choose.", systemImage: "checkmark.shield")
                        Label("SAM does not create or edit events without your action.", systemImage: "hand.raised")
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct ContactsTab: View {
    @Binding var contactsEnabled: Bool
    let contactsAuthStatus: CNAuthorizationStatus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox("Contacts Integration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Contacts Integration", isOn: $contactsEnabled)
                            .disabled(contactsAuthStatus != .authorized)

                        HStack(spacing: 12) {
                            Button("Sync Now") {
                                Task {
                                    await ContactsImportCoordinator.shared.importNow()
                                }
                            }
                            .disabled(contactsAuthStatus != .authorized)
                        }

                        Text("Contacts integration will let SAM link people to contexts and avoid duplicates. You can keep this off until you are ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }
}


