//
//  ProcessingStatusView.swift
//  SAM
//
//  Created by Assistant on 2/15/26.
//  Phase J Part 4: Background processing status indicator
//
//  Displays a spinner + label in the sidebar footer when AI processing is active.
//

import SwiftUI

struct ProcessingStatusView: View {
    @State private var contactsCoordinator = ContactsImportCoordinator.shared
    @State private var mailCoordinator = MailImportCoordinator.shared
    @State private var insightGenerator = InsightGenerator.shared

    var body: some View {
        if let activity = currentActivity {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var currentActivity: String? {
        if contactsCoordinator.importStatus == .importing {
            return "Importing contacts..."
        }
        if mailCoordinator.importStatus == .importing {
            return "Importing emails..."
        }
        if insightGenerator.generationStatus == .generating {
            return "Generating insights..."
        }
        return nil
    }
}
