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
    
    enum OnboardingStep {
        case welcome
        case contactsPermission
        case contactsGroupSelection
        case calendarPermission
        case calendarSelection
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
            await checkStatuses()
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)
            
            Text("Welcome to SAM")
                .font(.title2)
                .bold()
            
            Spacer()
            
            // Quit button - escape hatch for users who want to exit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Steps
    
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your Relationship Management Assistant")
                .font(.title)
                .bold()
            
            Text("SAM helps you maintain great relationships with your clients by:")
                .font(.body)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "person.2.fill", text: "Tracking interactions from Contacts and Calendar")
                FeatureRow(icon: "lightbulb.fill", text: "Generating insights about client needs")
                FeatureRow(icon: "bell.fill", text: "Reminding you when follow-ups are needed")
                FeatureRow(icon: "lock.shield.fill", text: "Keeping all data private and on your device")
            }
            .padding(.leading, 8)
            
            Text("Let's get started by setting up permissions.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }
    
    private var contactsPermissionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
            
            Text("Contacts Access")
                .font(.title)
                .bold()
            
            Text("SAM needs access to your Contacts to:")
                .font(.body)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Import client names and contact information")
                BulletPoint("Keep your relationship data up-to-date")
                BulletPoint("Link interactions to the right people")
            }
            .padding(.leading, 8)
            
            Text("SAM only accesses contacts you choose. You'll select a specific group in the next step.")
                .font(.callout)
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
                        .font(.caption)
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
                .font(.title)
                .bold()
            
            Text("For best results, create a dedicated 'SAM' group in Contacts containing only your work contacts.")
                .font(.body)
                .foregroundStyle(.secondary)
            
            Text("This ensures SAM only accesses relevant professional relationships, not personal contacts.")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select Group")
                        .font(.headline)
                    
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
                            }
                        }
                    } else {
                        Text("No groups found. Please create a group in the Contacts app.")
                            .font(.caption)
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
                .font(.title)
                .bold()
            
            Text("SAM needs access to your Calendar to:")
                .font(.body)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                BulletPoint("Track meetings and appointments")
                BulletPoint("Generate insights from interaction patterns")
                BulletPoint("Remind you of upcoming engagements")
            }
            .padding(.leading, 8)
            
            Text("SAM only accesses events from the calendar you choose.")
                .font(.callout)
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
                        .font(.caption)
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
                .font(.title)
                .bold()
            
            Text("For best results, create a dedicated 'SAM' calendar containing only your work events.")
                .font(.body)
                .foregroundStyle(.secondary)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select Calendar")
                        .font(.headline)
                    
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
                            .font(.caption)
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
    
    private var completeStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
            
            Text(completionTitle)
                .font(.title)
                .bold()
                .frame(maxWidth: .infinity)
            
            Text(completionMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            
            VStack(spacing: 16) {
                if !selectedGroupIdentifier.isEmpty {
                    StatusRow(icon: "person.crop.circle.fill", 
                             color: .blue,
                             title: "Contacts",
                             subtitle: "Ready to import")
                } else if skippedContacts {
                    SkippedRow(icon: "person.crop.circle.fill",
                              color: .blue,
                              title: "Contacts",
                              subtitle: "Skipped - you can enable this in Settings later")
                }
                
                if !selectedCalendarIdentifier.isEmpty {
                    StatusRow(icon: "calendar.circle.fill",
                             color: .orange,
                             title: "Calendar",
                             subtitle: "Ready to import")
                } else if skippedCalendar {
                    SkippedRow(icon: "calendar.circle.fill",
                              color: .orange,
                              title: "Calendar",
                              subtitle: "Skipped - you can enable this in Settings later")
                }
            }
            .padding(.vertical)
        }
    }
    
    private var completionTitle: String {
        if skippedContacts && skippedCalendar {
            return "Ready to Start"
        } else if skippedContacts || skippedCalendar {
            return "Partially Configured"
        } else {
            return "You're All Set!"
        }
    }
    
    private var completionMessage: String {
        if skippedContacts && skippedCalendar {
            return "You can configure permissions anytime in Settings. SAM will be ready when you are."
        } else if skippedContacts || skippedCalendar {
            return "SAM will import the enabled sources. You can configure additional permissions in Settings later."
        } else {
            return "SAM will now import your contacts and calendar events. This may take a moment."
        }
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    goBack()
                }
                .keyboardShortcut(.cancelAction)
            }
            
            Spacer()
            
            // Show skip option for permission steps
            if shouldShowSkip {
                Button("Skip for Now") {
                    skipCurrentStep()
                }
                .foregroundStyle(.secondary)
            }
            
            Button(nextButtonTitle) {
                Task {
                    await goNext()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canProceed)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
    
    private var shouldShowSkip: Bool {
        switch currentStep {
        case .contactsPermission, .contactsGroupSelection, .calendarPermission, .calendarSelection:
            return true
        default:
            return false
        }
    }
    
    private var nextButtonTitle: String {
        switch currentStep {
        case .welcome:
            return "Get Started"
        case .contactsPermission:
            return contactsStatus == .authorized ? "Next" : "Grant Access"
        case .contactsGroupSelection:
            return "Next"
        case .calendarPermission:
            return calendarStatus == .fullAccess ? "Next" : "Grant Access"
        case .calendarSelection:
            return "Next"
        case .complete:
            return "Start Using SAM"
        }
    }
    
    private var canProceed: Bool {
        switch currentStep {
        case .welcome:
            return true
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
        case .complete:
            return true
        }
    }
    
    // MARK: - Navigation
    
    private func skipCurrentStep() {
        switch currentStep {
        case .contactsPermission:
            skippedContacts = true
            currentStep = .calendarPermission
        case .contactsGroupSelection:
            skippedContacts = true
            currentStep = .calendarPermission
        case .calendarPermission:
            skippedCalendar = true
            currentStep = .complete
        case .calendarSelection:
            skippedCalendar = true
            currentStep = .complete
        default:
            break
        }
    }
    
    private func goNext() async {
        switch currentStep {
        case .welcome:
            currentStep = .contactsPermission
            
        case .contactsPermission:
            if contactsStatus != .authorized {
                await requestContactsPermission()
            } else {
                currentStep = .contactsGroupSelection
            }
            
        case .contactsGroupSelection:
            currentStep = .calendarPermission
            
        case .calendarPermission:
            if calendarStatus != .fullAccess {
                await requestCalendarPermission()
            } else {
                currentStep = .calendarSelection
            }
            
        case .calendarSelection:
            currentStep = .complete
            
        case .complete:
            // Save selections and trigger imports
            saveSelections()
            await triggerImports()
            dismiss()
        }
    }
    
    private func goBack() {
        switch currentStep {
        case .welcome:
            break
        case .contactsPermission:
            currentStep = .welcome
        case .contactsGroupSelection:
            currentStep = .contactsPermission
        case .calendarPermission:
            currentStep = .contactsGroupSelection
        case .calendarSelection:
            currentStep = .calendarPermission
        case .complete:
            currentStep = .calendarSelection
        }
    }
    
    // MARK: - Permissions
    
    private func checkStatuses() async {
        contactsStatus = await ContactsService.shared.authorizationStatus()
        calendarStatus = await CalendarService.shared.authorizationStatus()
    }
    
    private func requestContactsPermission() async {
        isRequestingContacts = true
        let granted = await ContactsService.shared.requestAuthorization()
        contactsStatus = granted ? .authorized : .denied
        isRequestingContacts = false
        
        if granted {
            currentStep = .contactsGroupSelection
        }
    }
    
    private func requestCalendarPermission() async {
        isRequestingCalendar = true
        let granted = await CalendarService.shared.requestAuthorization()
        calendarStatus = granted ? .fullAccess : .denied
        isRequestingCalendar = false
        
        if granted {
            currentStep = .calendarSelection
        }
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
        } else {
            UserDefaults.standard.set(false, forKey: "sam.contacts.enabled")
        }
        
        if !skippedCalendar && !selectedCalendarIdentifier.isEmpty {
            UserDefaults.standard.set(selectedCalendarIdentifier, forKey: "selectedCalendarIdentifier")
            UserDefaults.standard.set(true, forKey: "calendarAutoImportEnabled")
        } else {
            UserDefaults.standard.set(false, forKey: "calendarAutoImportEnabled")
        }
        
        // Always mark onboarding complete, even if permissions were skipped
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }
    
    private func triggerImports() async {
        // Only trigger imports for enabled sources
        if !skippedContacts && !selectedGroupIdentifier.isEmpty {
            await ContactsImportCoordinator.shared.importNow()
        }
        
        if !skippedCalendar && !selectedCalendarIdentifier.isEmpty {
            await CalendarImportCoordinator.shared.importNow()
        }
    }
    
    // MARK: - System Settings
    
    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Helper Views

private struct SkippedRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(color.opacity(0.5))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.gray)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.body)
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
            Text("•")
                .font(.body)
            Text(text)
                .font(.body)
        }
    }
}

private struct StatusRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(color)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

#Preview {
    OnboardingView()
}
