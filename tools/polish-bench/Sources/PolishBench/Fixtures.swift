//
//  Fixtures.swift
//  polish-bench
//
//  A fixture is a speaker-attributed transcript plus optional companion
//  files that seed retention scoring:
//
//    <name>.txt              required — the transcript
//    <name>.nouns.txt        optional — one proper noun per line (names,
//                            companies, brands). The bench checks whether
//                            each survived the polish step intact.
//    <name>.jargon.txt       optional — one domain term per line (IUL,
//                            SEP-IRA, 401(k), K-1, etc.). These are the
//                            terms Qwen would be most tempted to "correct"
//                            into plausible-sounding wrong words.
//
//  The scenario files in tools/test-kit/scenarios ship with `# description:`
//  style comment lines at the top. Those are stripped before the transcript
//  is handed to the model.
//

import Foundation

struct Fixture: Sendable {
    /// File stem — e.g. "jargon-and-names". Used as the output key.
    let name: String
    /// The transcript with header comments stripped.
    let rawTranscript: String
    /// Proper nouns to check for retention. Empty if no companion file exists.
    let knownNouns: [String]
    /// Jargon terms to check for retention. Empty if no companion file exists.
    let jargon: [String]
}

enum FixtureLoader {
    static func loadAll(at dir: URL) throws -> [Fixture] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let txts = entries
            .filter { $0.pathExtension == "txt" }
            .filter { !$0.lastPathComponent.hasSuffix(".nouns.txt") }
            .filter { !$0.lastPathComponent.hasSuffix(".jargon.txt") }
            .filter { !$0.lastPathComponent.hasSuffix(".polished.txt") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try txts.map { url in
            let raw = try String(contentsOf: url, encoding: .utf8)
            let cleaned = stripHeaderComments(raw)
            let stem = url.deletingPathExtension().lastPathComponent
            let nouns = loadCompanion(dir: dir, stem: stem, suffix: "nouns")
            let jargon = loadCompanion(dir: dir, stem: stem, suffix: "jargon")
            return Fixture(name: stem, rawTranscript: cleaned, knownNouns: nouns, jargon: jargon)
        }
    }

    private static func loadCompanion(dir: URL, stem: String, suffix: String) -> [String] {
        let url = dir.appendingPathComponent("\(stem).\(suffix).txt")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Drop leading `#` comment lines (scenario metadata) before the first
    /// non-comment, non-blank line. Mirrors how the test-kit scenarios are
    /// consumed elsewhere in the codebase.
    private static func stripHeaderComments(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("#")
              || first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
            if lines.isEmpty { break }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
