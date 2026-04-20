import Foundation

// Usage:
//   summary-bench <transcript-path>
//
// Produces a folder under ~/Downloads/sam-bench-<stem>-<ts>/ containing:
//   chunks.txt, extracts.json, scaffold.json, synthesis-prompt.txt,
//   summary.json, summary.md, eval.md, run.log

@main
struct CLI {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        guard let path = args.first else {
            FileHandle.standardError.write("usage: summary-bench <transcript.txt>\n".data(using: .utf8)!)
            exit(2)
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let stem = url.deletingPathExtension().lastPathComponent

        let logger: RunLogger
        do {
            logger = try RunLogger(transcriptName: stem)
        } catch {
            FileHandle.standardError.write("failed to create run folder: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        await logger.line("=== summary-bench run for \(stem) ===")
        await logger.line("Artifacts: \(logger.root.path)")

        let transcript: String
        do {
            transcript = try String(contentsOf: url, encoding: .utf8)
        } catch {
            await logger.line("❌ failed to read transcript: \(error.localizedDescription)")
            try? await logger.flushRunLog()
            exit(1)
        }

        do {
            let summary = try await Pipeline.run(
                transcript: transcript,
                transcriptStem: stem,
                logger: logger
            )

            let eval = Evaluator.evaluate(summary, transcriptStem: stem)
            try await logger.writeText("eval.md", eval.asMarkdown)
            await logger.line(String(format: "Evaluation: %d passed / %d failed (score %.0f%%)",
                                     eval.passes.count, eval.fails.count, eval.score * 100))
            if !eval.antiAnchorHits.isEmpty {
                await logger.line("⚠️  Anti-anchor hits: \(eval.antiAnchorHits.joined(separator: ", "))")
            }

            try await logger.flushRunLog()
            print(logger.root.path)
        } catch {
            await logger.line("❌ pipeline failed: \(error.localizedDescription)")
            try? await logger.flushRunLog()
            exit(1)
        }
    }
}
