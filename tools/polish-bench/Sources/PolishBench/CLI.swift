//
//  CLI.swift
//  polish-bench
//

import Foundation

struct CLIArgs {
    let modelIDs: [String]
    let fixturesDir: URL
    let outputDir: URL?

    static let usage = """
    usage: polish-bench --models <id[,id...]> [--fixtures <dir>] [--output <dir>]

      --models       Comma-separated Hugging Face repo IDs, e.g.
                     "mlx-community/Qwen3-8B-4bit,mlx-community/Qwen3.5-9B-Instruct-4bit".
                     The bench does NOT download models — it assumes they are
                     already cached in ~/Library/Caches/huggingface (same dir
                     the main app uses). Run each model once from the main
                     app first so the weights are on disk.
      --fixtures     Directory of .txt transcripts to polish. Defaults to
                     ../test-kit/scenarios relative to the current directory.
                     Each fixture may be paired with <name>.nouns.txt and
                     <name>.jargon.txt to seed retention metrics.
      --output       Where to write per-model polished .txt, per-file metrics
                     JSON, a summary table, and (for exactly 2 models) unified
                     diffs of the two outputs. Defaults to
                     ~/Downloads/polish-bench-<ISO8601-ts>/.
    """

    static func parse(_ args: [String]) throws -> CLIArgs {
        var models: [String] = []
        var fixtures: URL?
        var output: URL?

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--models":
                guard i + 1 < args.count else { throw CLIError.missingValue("--models") }
                models = args[i + 1]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                i += 2
            case "--fixtures":
                guard i + 1 < args.count else { throw CLIError.missingValue("--fixtures") }
                fixtures = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
                i += 2
            case "--output":
                guard i + 1 < args.count else { throw CLIError.missingValue("--output") }
                output = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
                i += 2
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw CLIError.unknownFlag(a)
            }
        }

        guard !models.isEmpty else { throw CLIError.missingValue("--models") }

        let resolvedFixtures: URL
        if let f = fixtures {
            resolvedFixtures = f
        } else {
            // Default: ../test-kit/scenarios relative to cwd so `swift run`
            // from tools/polish-bench picks up the curated transcripts.
            let cwd = FileManager.default.currentDirectoryPath
            resolvedFixtures = URL(fileURLWithPath: cwd)
                .appendingPathComponent("../test-kit/scenarios")
                .standardized
        }

        return CLIArgs(modelIDs: models, fixturesDir: resolvedFixtures, outputDir: output)
    }
}

enum CLIError: LocalizedError {
    case missingValue(String)
    case unknownFlag(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag): return "missing value for \(flag)"
        case .unknownFlag(let flag):  return "unknown flag: \(flag)"
        }
    }
}
