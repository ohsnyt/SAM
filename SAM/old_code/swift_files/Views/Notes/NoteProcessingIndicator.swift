//
//  NoteProcessingIndicator.swift
//  SAM_crm
//
//  Created by Assistant on 2/8/26.
//  Phase 1.1: Enhanced note processing feedback
//

import SwiftUI

/// A prominent, attention-grabbing indicator shown while AI analyzes a note.
///
/// Replaces the subtle gray bar with an orange-accented card that clearly
/// communicates what's happening and sets user expectations.
///
/// Design:
/// - Light orange background with orange border
/// - Animated slide-up from bottom with fade-in
/// - Progress spinner + descriptive two-line text
/// - Automatically dismisses when processing completes
struct NoteProcessingIndicator: View {
    let isProcessing: Bool
    
    var body: some View {
        if isProcessing {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Analyzing note with AI...")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    
                    Text("Looking for insights and action items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isProcessing)
        }
    }
}

// MARK: - Preview

#Preview("Processing") {
    VStack {
        Spacer()
        NoteProcessingIndicator(isProcessing: true)
    }
    .frame(height: 300)
    .background(Color(.windowBackgroundColor))
}

#Preview("Not Processing") {
    VStack {
        Spacer()
        NoteProcessingIndicator(isProcessing: false)
        Text("Indicator should be hidden")
            .foregroundStyle(.secondary)
    }
    .frame(height: 300)
    .background(Color(.windowBackgroundColor))
}

#Preview("Dark Mode") {
    VStack {
        Spacer()
        NoteProcessingIndicator(isProcessing: true)
    }
    .frame(height: 300)
    .background(Color(.windowBackgroundColor))
    .preferredColorScheme(.dark)
}
