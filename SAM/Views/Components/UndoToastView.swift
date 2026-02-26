//
//  UndoToastView.swift
//  SAM
//
//  Created by Assistant on 2/25/26.
//  Phase P: Universal Undo System
//
//  Dark rounded banner at the bottom of the window showing undo actions.
//

import SwiftUI

struct UndoToastView: View {

    @State private var coordinator = UndoCoordinator.shared

    var body: some View {
        if let entry = coordinator.currentEntry {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.white.opacity(0.8))

                Text(toastLabel(for: entry))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Button("Undo") {
                    coordinator.performUndo()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .controlSize(.small)

                Button {
                    coordinator.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: entry.id)
        }
    }

    private func toastLabel(for entry: SamUndoEntry) -> String {
        let name = entry.entityDisplayName

        switch (entry.operation, entry.entityType) {
        case (.deleted, .note):
            return "Note deleted: \(name) (without images)"
        case (.deleted, .context):
            return "Context deleted: \(name)"
        case (.deleted, .participation):
            return "Removed: \(name)"
        case (.statusChanged, .outcome):
            return "Outcome updated: \(name)"
        case (.statusChanged, .insight):
            return "Insight dismissed: \(name)"
        default:
            return "\(name)"
        }
    }
}
