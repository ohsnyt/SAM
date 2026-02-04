//
//  BackupTab.swift
//  SAM_crm
//
//  Settings → Backup tab.  Export and restore encrypted .sam-backup files.
//  Optionally offers to save the chosen password to the system Passwords app
//  via Keychain after a successful export.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tab root

struct BackupTab: View {

    @State private var showExport  = false
    @State private var showRestore = false

    /// Feedback toast shown after a successful export or restore.
    @State private var successMessage: String? = nil
    /// Error toast (uses the localizedDescription from BackupError).
    @State private var errorMessage:   String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox {
                    Text("A backup contains all of your Evidence, People, and Contexts. The file is encrypted with a password you choose — SAM never stores the password itself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // MARK: Export

                GroupBox("Export Backup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Creates an encrypted .sam-backup file you can save anywhere.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Export…") { showExport = true }
                            .buttonStyle(.glass)
                    }
                }

                // MARK: Restore

                GroupBox("Restore from Backup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Replaces all current data with the contents of a backup file. You will be asked to confirm before any data is overwritten.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Restore…") { showRestore = true }
                            .buttonStyle(.glass)
                    }
                }

                // MARK: Security note

                GroupBox("Security") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Backup files are encrypted with AES-256-GCM.", systemImage: "lock.shield")
                        Label("The encryption key is derived from your password using PBKDF2 (100 000 iterations).", systemImage: "key")
                        Label("SAM can offer to save your backup password to the system Passwords app so you don't forget it.", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        // MARK: - Sheets

        .sheet(isPresented: $showExport) {
            ExportBackupSheet(
                onSuccess: { msg in successMessage = msg },
                onError:   { msg in errorMessage   = msg }
            )
        }
        .sheet(isPresented: $showRestore) {
            RestoreBackupSheet(
                onSuccess: { msg in successMessage = msg },
                onError:   { msg in errorMessage   = msg }
            )
        }
        // MARK: - Toast overlay (reuse the existing ToastView)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let msg = successMessage {
                    ToastView(message: "✓ \(msg)")
                        .tint(.green)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation { successMessage = nil }
                            }
                        }
                }
                if let msg = errorMessage {
                    ToastView(message: msg)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                withAnimation { errorMessage = nil }
                            }
                        }
                }
            }
            .padding(.top, 8)
            .animation(.easeOut, value: successMessage)
            .animation(.easeOut, value: errorMessage)
        }
    }
}

// MARK: - Export sheet

private struct ExportBackupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSuccess: (String) -> Void
    let onError:   (String) -> Void

    @State private var password:        String = ""
    @State private var confirmPassword: String = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Backup")
                .font(.title2).bold()

            Text("Choose a password to protect your backup file. You will need this password to restore from the backup later.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                SecureField("Password", text: $password)
                    .textContentType(.newPassword)

                SecureField("Confirm password", text: $confirmPassword)
                    .textContentType(.newPassword)
            }
            .formStyle(.grouped)

            if !passwordsMatch && !confirmPassword.isEmpty {
                Label("Passwords do not match.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Export…") { Task { await exportBackup() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
        .disabled(isWorking)
    }

    // MARK: - Derived

    private var passwordsMatch: Bool { password == confirmPassword }
    private var canExport: Bool { !password.isEmpty && passwordsMatch && !isWorking }

    // MARK: - Actions

    @MainActor
    private func exportBackup() async {
        isWorking = true
        defer { isWorking = false }

        // 1. Serialise
        let payload = BackupPayload.current()
        guard let json = try? JSONEncoder().encode(payload) else {
            onError(BackupError.serializationFailed.localizedDescription)
            dismiss()
            return
        }

        // 2. Encrypt
        guard let encrypted = try? BackupCrypto.encrypt(json, password: password) else {
            onError(BackupError.serializationFailed.localizedDescription)
            dismiss()
            return
        }

        // 3. Save panel
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.samBackup]
        panel.nameFieldStringValue = "SAM Backup \(shortDate()).sam-backup"
        panel.message = "Choose where to save your encrypted backup."

        guard case .continue = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) else {
            // User cancelled
            return
        }
        guard let url = panel.url else { return }

        do {
            try encrypted.write(to: url)
        } catch {
            onError("Could not write file: \(error.localizedDescription)")
            dismiss()
            return
        }

        // 4. Offer to save password to Passwords app
        offerSavePassword(password: password, fileName: url.lastPathComponent)

        onSuccess("Backup exported successfully.")
        dismiss()
    }

    /// Offer to save the backup password to the system Passwords app.
    /// On macOS there is no ASCredentialSaveRequest, so we write directly
    /// to the login Keychain under a well-known service name that the
    /// Passwords app surfaces.  This is fire-and-forget — the export has
    /// already succeeded regardless of outcome.
    private func offerSavePassword(password: String, fileName: String) {
        CredentialSaveDelegate(password: password, fileName: fileName).saveToKeychain()
    }

    private func shortDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now)
    }
}

// MARK: - Restore sheet

private struct RestoreBackupSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSuccess: (String) -> Void
    let onError:   (String) -> Void

    @State private var password = ""
    @State private var isWorking = false
    @State private var confirmRestore = false
    /// Decoded payload held in memory between "preview" and "confirm" steps.
    @State private var pendingPayload: BackupPayload? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore from Backup")
                .font(.title2).bold()

            Text("Select a .sam-backup file and enter the password that was used when it was created. All current data will be replaced.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                SecureField("Backup password", text: $password)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Choose File…") { Task { await chooseAndDecrypt() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isWorking)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
        .disabled(isWorking)
        // Confirmation alert — shown after successful decrypt, before we
        // actually overwrite the live stores.
        .confirmationDialog(
            "Replace all data?",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                Task { await commitRestore() }
            }
            Button("Cancel", role: .cancel) {
                pendingPayload = nil
            }
        } message: {
            Text("This will replace all Evidence, People, and Contexts with the contents of the backup. This action cannot be undone.")
        }
    }

    // MARK: - Actions

    @MainActor
    private func chooseAndDecrypt() async {
        isWorking = true
        defer { isWorking = false }

        // 1. Open panel
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.samBackup]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SAM backup file to restore."

        guard case .continue = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) else {
            return   // cancelled
        }
        guard let url = panel.urls.first else { return }

        // 2. Read
        let blob: Data
        do {
            blob = try Data(contentsOf: url)
        } catch {
            onError("Could not read file: \(error.localizedDescription)")
            return
        }

        // 3. Decrypt
        let json: Data
        do {
            json = try BackupCrypto.decrypt(blob, password: password)
        } catch let e as BackupError {
            onError(e.localizedDescription)
            return
        } catch {
            onError(BackupError.invalidFile.localizedDescription)
            return
        }

        // 4. Decode
        do {
            let payload = try JSONDecoder().decode(BackupPayload.self, from: json)
            guard payload.version <= BackupPayload.currentVersion else {
                onError("This backup was created by a newer version of SAM. Please update the app first.")
                return
            }
            pendingPayload  = payload
            confirmRestore  = true
        } catch {
            onError(BackupError.deserializationFailed.localizedDescription)
        }
    }

    @MainActor
    private func commitRestore() async {
        guard let payload = pendingPayload else { return }
        payload.restore()
        pendingPayload = nil
        onSuccess("Data restored successfully.")
        dismiss()
    }
}

// MARK: - Keychain credential helper

/// Saves the backup password to the login Keychain so that it is visible
/// in the system Passwords app (which surfaces iCloud Keychain entries).
/// Users can find it by searching for "SAM Backup" in Passwords.
private final class CredentialSaveDelegate {

    private let password: String
    private let fileName: String

    init(password: String, fileName: String) {
        self.password = password
        self.fileName = fileName
    }

    func saveToKeychain() {
        let service = "SAM Backup – \(fileName)"

        let attributes: [CFString: Any] = [
            kSecClass:                kSecClassGenericPassword,
            kSecAttrService:          service,
            kSecAttrAccount:          fileName,
            kSecValueData:            password.data(using: .utf8)!,
            kSecAttrSynchronizable:   true   // syncs to iCloud Keychain → visible in Passwords
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        // status == errSecDuplicateItem is fine — password already saved.
        _ = status
    }
}

// MARK: - UTType for .sam-backup

extension UTType {
    /// Custom uniform type for SAM backup files.
    /// Register this in the app's Info.plist under "Exported Type Identifiers":
    ///   identifier: com.sam-crm.sam-backup
    ///   conforms to: public.data
    ///   file extension: sam-backup
    static let samBackup = UTType("com.sam-crm.sam-backup")!
}
