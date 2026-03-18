//
//  BackupPassphraseSheet.swift
//  SAM
//
//  Passphrase entry sheet for encrypted backup export/import.
//

import SwiftUI

struct BackupPassphraseSheet: View {

    @Binding var passphrase: String
    let isExport: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var confirmPassphrase = ""
    @State private var mismatchError = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isExport ? "lock.doc" : "lock.open.doc")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text(isExport ? "Encrypt Backup" : "Decrypt Backup")
                .samFont(.title2)
                .fontWeight(.semibold)

            Text(isExport
                 ? "Enter a passphrase to encrypt this backup. You will need this passphrase to restore it."
                 : "This backup is encrypted. Enter the passphrase to decrypt it.")
                .samFont(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            VStack(alignment: .leading, spacing: 8) {
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)

                if isExport {
                    SecureField("Confirm passphrase", text: $confirmPassphrase)
                        .textFieldStyle(.roundedBorder)

                    if mismatchError {
                        Text("Passphrases do not match")
                            .samFont(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(width: 300)

            HStack(spacing: 12) {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                if isExport {
                    Button("Encrypt & Export") {
                        if passphrase != confirmPassphrase {
                            mismatchError = true
                            return
                        }
                        mismatchError = false
                        onConfirm()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty)
                } else {
                    Button("Decrypt") {
                        onConfirm()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(passphrase.isEmpty)
                }
            }
        }
        .padding(30)
        .frame(width: 420)
    }
}
