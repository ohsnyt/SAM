//
//  CopyButton.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//
//  Small reusable copy-to-clipboard button with brief "copied" feedback.
//

import SwiftUI
import AppKit

struct CopyButton: View {
    let text: String

    @State private var copied = false

    var body: some View {
        Button {
            ClipboardSecurity.copy(text, clearAfter: 60)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .samFont(.caption2)
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }
}
