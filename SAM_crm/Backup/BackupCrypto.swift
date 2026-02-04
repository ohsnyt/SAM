//
//  BackupCrypto.swift
//  SAM_crm
//
//  AES-256-GCM encrypt/decrypt for .sam-backup files.
//  Key is derived from a user password via PBKDF2 (100 000 iterations).
//
//  Wire format (all big-endian, no framing beyond concatenation):
//    salt        – 16 bytes   (random, fed to PBKDF2)
//    nonce       – 12 bytes   (random, GCM standard)
//    ciphertext  – variable   (includes the 16-byte GCM auth tag appended by CryptoKit)
//

import Foundation
import CryptoKit

/// Stateless utility.  Never instantiate.
enum BackupCrypto {

    // MARK: - Public

    /// Encrypt `plaintext` with a key derived from `password`.
    /// Returns the full wire-format blob ready to write to disk.
    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        let salt   = generateRandom(16)
        let key    = deriveKey(password: password, salt: salt)
        let nonce  = try AES.GCM.Nonce(data: generateRandom(12))
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        // nonce is already inside sealedBox but we store it explicitly for
        // clarity and so the wire format is self-describing.
        var out = Data()
        out.append(salt)
        out.append(Data(nonce))
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Decrypt a blob produced by `encrypt`.  Throws on wrong password or
    /// tampered data (GCM auth-tag mismatch).
    static func decrypt(_ blob: Data, password: String) throws -> Data {
        // Minimum size: 16 (salt) + 12 (nonce) + 16 (tag) = 44 bytes, plus
        // at least 1 byte of ciphertext.
        guard blob.count > 44 else {
            throw BackupError.invalidFile
        }

        var offset = blob.startIndex

        let salt      = extractBytes(&offset, count: 16, from: blob)
        let nonceData = extractBytes(&offset, count: 12, from: blob)
        let remainder = Data(blob[offset...])                    // ciphertext + tag

        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw BackupError.invalidFile
        }

        // The last 16 bytes of remainder are the GCM auth tag; everything
        // before that is the raw ciphertext.  Use the three-argument
        // initialiser so nonce, ciphertext and tag are passed separately.
        guard remainder.count >= 16 else {
            throw BackupError.invalidFile
        }
        let ciphertext = remainder.dropLast(16)
        let tag        = remainder.suffix(16)

        guard let sealedBox = try? AES.GCM.SealedBox(
            nonce:      nonce,
            ciphertext: Data(ciphertext),
            tag:        Data(tag)
        ) else {
            throw BackupError.invalidFile
        }

        let key = deriveKey(password: password, salt: salt)

        do {
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw BackupError.wrongPassword
        }
    }

    // MARK: - Private helpers

    /// PBKDF2-SHA256, 100 000 iterations, 256-bit output.
    private static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let passwordData = password.data(using: .utf8)!
        let derivedKey = PBKDF2.deriveKey(
            password: passwordData,
            salt: salt,
            iterations: 100_000,
            keyLength: 32          // 256 bits
        )
        return SymmetricKey(data: derivedKey)
    }

    /// Cryptographically random bytes via the system CSPRNG.
    private static func generateRandom(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Pull `count` bytes out of `blob` starting at `offset`, advancing it.
    private static func extractBytes(_ offset: inout Data.Index, count: Int, from blob: Data) -> Data {
        let end = blob.index(offset, offsetBy: count)
        let slice = blob[offset..<end]
        offset = end
        return Data(slice)
    }
}

// MARK: - PBKDF2 helper (CommonCrypto – works on macOS)

import CommonCrypto

private enum PBKDF2 {
    static func deriveKey(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derivedKey = [UInt8](repeating: 0, count: keyLength)

        let status = password.withUnsafeBytes { passwordPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),                        // algorithm
                    passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    UInt32(2),                                          // kCCPRFHmacAlgoSHA256 == 2 (not bridged on macOS)
                    UInt32(iterations),
                    &derivedKey,
                    keyLength
                )
            }
        }
        // kCCSuccess == 0; anything else is a programmer error.
        assert(status == kCCSuccess, "CCKeyDerivationPBKDF failed: \(status)")

        return Data(derivedKey)
    }
}

// MARK: - Errors

enum BackupError: Error, LocalizedError {
    case invalidFile
    case wrongPassword
    case serializationFailed
    case deserializationFailed
    case saveToPasswordsFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:            return "The selected file is not a valid SAM backup."
        case .wrongPassword:          return "The password is incorrect or the file has been tampered with."
        case .serializationFailed:    return "Failed to serialize data for export."
        case .deserializationFailed:  return "Failed to restore data from the backup file."
        case .saveToPasswordsFailed:  return "The password could not be saved to Passwords. The backup was still exported successfully."
        }
    }
}
