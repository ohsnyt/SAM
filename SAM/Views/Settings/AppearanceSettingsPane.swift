//
//  AppearanceSettingsPane.swift
//  SAM
//
//  Settings pane for text size, emoji, and guidance/tips.
//

import SwiftUI
import UserNotifications

struct AppearanceSettingsPane: View {

    @AppStorage("sam.display.textSize") private var textSizeRawValue = SAMTextSize.standard.rawValue

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    // Text Size
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Text Size")
                            .samFont(.headline)

                        Picker("Text Size", selection: $textSizeRawValue) {
                            ForEach(SAMTextSize.allCases) { size in
                                Text(size.label).tag(size.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 400)

                        Text("Adjusts text size throughout SAM. Useful when your display resolution makes default text feel too small.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)

                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(.sam(.body, scale: SAMTextSize(rawValue: textSizeRawValue)?.scale ?? 1.0))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }

                    Divider()

                    // Guidance & Tips
                    GuidanceSettingsContent()

                    Divider()

                    // Notifications permission
                    notificationsSection
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notifications

    @State private var notificationsStatus: String = "Checking..."
    @State private var isRequestingNotifications = false

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .samFont(.headline)

            permissionBadge(
                icon: "bell.circle.fill", color: .red,
                name: "Notifications", status: notificationsStatus
            )

            if notificationsStatus == "Not Requested" {
                Button("Request Permission") {
                    isRequestingNotifications = true
                    Task {
                        do {
                            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                            notificationsStatus = granted ? "Authorized" : "Denied"
                        } catch {
                            notificationsStatus = "Denied"
                        }
                        isRequestingNotifications = false
                    }
                }
                .controlSize(.small)
                .disabled(isRequestingNotifications)
            }

            Text("SAM uses notifications for meeting prep reminders and briefing alerts.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: notificationsStatus = "Authorized"
            case .denied: notificationsStatus = "Denied"
            case .notDetermined: notificationsStatus = "Not Requested"
            @unknown default: notificationsStatus = "Unknown"
            }
        }
    }
}
