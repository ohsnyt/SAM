//
//  SettingsView.swift
//  SAM Field
//
//  Created by Assistant on 4/18/26.
//
//  Settings sheet for SAM Field. Currently hosts the About section;
//  future preferences (notifications, mileage rate, voice polish, etc.)
//  will live here alongside it.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Version", value: Self.versionString)
                    LabeledContent("Built", value: Self.buildDateString)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?[kCFBundleVersionKey as String] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static var buildDateString: String {
        guard let execURL = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
              let date = attrs[.modificationDate] as? Date else {
            return "Unknown"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

#Preview("Settings") {
    SettingsView()
}
