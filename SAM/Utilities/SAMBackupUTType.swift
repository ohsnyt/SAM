//
//  SAMBackupUTType.swift
//  SAM
//
//  UTType extension for .sambackup files.
//

import UniformTypeIdentifiers

extension UTType {
    /// SAM backup file — JSON document with `.sambackup` extension.
    static let samBackup = UTType(exportedAs: "com.matthewsessions.SAM.backup")
}
