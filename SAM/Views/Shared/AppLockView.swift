//
//  AppLockView.swift
//  SAM
//
//  Created on March 13, 2026.
//  Full-screen lock overlay requiring authentication to access the app.
//

import SwiftUI

struct AppLockView: View {

    @State private var lockService = AppLockService.shared
    @State private var iconScale: CGFloat = 0.8
    @State private var iconOpacity: Double = 0.0

    // MARK: - Body

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // App Icon
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                // Title
                Text("SAM is Locked")
                    .samFont(.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                // Unlock Button
                Button(action: { lockService.authenticate() }) {
                    Label("Unlock", systemImage: lockService.isBiometricAvailable ? "touchid" : "lock.open")
                        .samFont(.body, weight: .medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(lockService.isAuthenticating)

                // Error Text
                if let error = lockService.authError {
                    Text(error)
                        .samFont(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }

            // Attempt authentication immediately on appear
            lockService.authenticate()
        }
    }
}

// MARK: - Preview

#Preview {
    AppLockView()
        .frame(width: 600, height: 400)
}
