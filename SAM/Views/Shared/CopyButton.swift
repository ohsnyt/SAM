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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }
}
