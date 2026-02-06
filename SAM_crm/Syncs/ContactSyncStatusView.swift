//
//  ContactSyncStatusView.swift
//  SAM_crm
//
//  Small banner/toast that appears when the ContactsSyncManager has
//  automatically unlinked contacts that were deleted from Contacts.app.
//
//  Designed to be overlaid at the top or bottom of the main content
//  area, with auto-dismiss after a few seconds.
//

import SwiftUI

struct ContactSyncStatusView: View {
    let clearedCount: Int
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Contact Links Updated")
                    .font(.subheadline)
                    .bold()
                
                Text("\(clearedCount) contact\(clearedCount == 1 ? "" : "s") removed from SAM or Contacts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#Preview {
    VStack {
        ContactSyncStatusView(clearedCount: 3) {
            print("Dismissed")
        }
        
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
}
