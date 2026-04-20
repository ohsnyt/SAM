import Foundation

/// Writes every artifact of a single bench run to a dedicated folder
/// under ~/Downloads/sam-bench-<file>-<timestamp>/. Each call is cheap —
/// the whole point of the bench is verbose reproducible traces.
actor RunLogger {
    let root: URL
    private var log: String = ""
    private let startedAt = Date()

    init(transcriptName: String) throws {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let ts = fmt.string(from: Date())
        let folder = "sam-bench-\(transcriptName)-\(ts)"
        self.root = downloads.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func line(_ s: String) {
        let t = Self.elapsed(since: startedAt)
        let entry = "[\(t)] \(s)\n"
        log.append(entry)
        FileHandle.standardError.write(entry.data(using: .utf8) ?? Data())
    }

    func writeText(_ name: String, _ content: String) throws {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeJSON<T: Encodable>(_ name: String, _ value: T) throws {
        let url = root.appendingPathComponent(name)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(value)
        try data.write(to: url)
    }

    func flushRunLog() throws {
        try writeText("run.log", log)
    }

    private static func elapsed(since start: Date) -> String {
        let s = Date().timeIntervalSince(start)
        return String(format: "%6.2fs", s)
    }
}
