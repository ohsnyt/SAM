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

    /// The tab index that the Settings window should open to.
    /// Backed by UserDefaults directly (not @AppStorage) so that the static
    /// helper `openToPermissions()` can write it without needing a View instance.
    static var selectedTab: Int {
        get { UserDefaults.standard.integer(forKey: "sam.settings.selectedTab") }
        set { UserDefaults.standard.set(newValue, forKey: "sam.settings.selectedTab") }
    }

    @State private var calendars: [EKCalendar] = []
    @State private var calendarAuthStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var contactsAuthStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()

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
        TabView(selection: Binding(
            get: { SamSettingsView.selectedTab },
            set: { SamSettingsView.selectedTab = $0 }
        )) {
            PermissionsTab(
                calendars: $calendars,
                calendarAuthStatus: calendarAuthStatus,
                contactsAuthStatus: contactsAuthStatus,
                selectedCalendarID: $selectedCalendarID,
                requestCalendarAccessAndReload: requestCalendarAccessAndReload,
                requestContactsAccess: requestContactsAccess,
                reloadCalendars: reloadCalendars,
                createAndSelectSAMCalendar: createAndSelectSAMCalendar
            )
            .tabItem {
                Label("Permissions", systemImage: "hand.raised")
            }
            .tag(0)

            ImportTab(
                calendarImportEnabled: $calendarImportEnabled,
                selectedCalendarID: $selectedCalendarID,
                calendarAuthStatus: calendarAuthStatus,
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
                contactsAuthStatus: contactsAuthStatus
            )
            .tabItem {
                Label("Contacts", systemImage: "person.crop.circle")
            }
            .tag(2)
        }
        .padding(20)
        .frame(width: 680, height: 460)
        .onAppear {
            Task { @MainActor in
                refreshAuthStatuses()
                await Task.yield()
                if calendarAuthStatus == .fullAccess || calendarAuthStatus == .writeOnly {
                    reloadCalendars()
                }
            }
        }
    }

    private func importCalendarEvidenceNow() async {
        await CalendarImportCoordinator.shared.importNow()
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

    private func refreshAuthStatuses() {
        calendarAuthStatus = EKEventStore.authorizationStatus(for: .event)
        contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    // MARK: - Permissions

    @MainActor
    private func requestCalendarAccessAndReload() async {
        do {
            // Requesting permissions should occur on the main actor for consistent UI/status updates.
            _ = try await eventStore.requestFullAccessToEvents()
        } catch {
            // optional: show a gentle message later
        }

        // Give the system a moment to commit the new authorization state.
        // (This avoids cases where authorizationStatus still reads as .notDetermined immediately after the prompt.)
        await Task.yield()

        refreshAuthStatuses()
        if calendarAuthStatus == .fullAccess || calendarAuthStatus == .writeOnly {
            reloadCalendars()
        }
    }
    
    
    private func requestContactsAccess() async {
        do {
            _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                contactStore.requestAccess(for: .contacts) { granted, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: granted)
                    }
                }
            }
        } catch {
            // Gentle alert later
        }
        refreshAuthStatuses()
    }

    // MARK: - Calendars

    private func reloadCalendars() {
        calendars = eventStore.calendars(for: .event)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // If the selected calendar no longer exists, clear selection.
        if !selectedCalendarID.isEmpty,
           calendars.first(where: { $0.calendarIdentifier == selectedCalendarID }) == nil {
            selectedCalendarID = ""
        }
    }

    private func createAndSelectSAMCalendar() async {
        guard calendarAuthStatus == .fullAccess || calendarAuthStatus == .writeOnly else { return }

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
}

// MARK: - Tabs

private struct PermissionsTab: View {
    @Binding var calendars: [EKCalendar]

    let calendarAuthStatus: EKAuthorizationStatus
    let contactsAuthStatus: CNAuthorizationStatus

    @Binding var selectedCalendarID: String

    let requestCalendarAccessAndReload: () async -> Void
    let requestContactsAccess: () async -> Void
    let reloadCalendars: () -> Void
    let createAndSelectSAMCalendar: () async -> Void

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

                        Button(contactsAuthStatus == .authorized ? "Granted" : "Request Contacts Access") {
                            Task { await requestContactsAccess() }
                        }
                        .disabled(contactsAuthStatus == .authorized)

                        Text("SAM uses Contacts as the source of identity. SAM will not modify Contacts without your action.")
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
