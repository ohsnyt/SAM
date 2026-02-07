import Foundation

public struct MailMessageMetadata {
    public let messageID: String
    public let threadID: String?
    public let date: Date
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
}

public final class MailIntegrationCoordinator {
    public static let shared = MailIntegrationCoordinator()
    private init() {}

    private let processingQueue = DispatchQueue(label: "com.sam.mail.processing")
    private var isObserving = false
    private var processedMessageIDs = Set<String>()
    public var lastSyncDate: Date?

    // Start/stop observing entry points
    public func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        // Placeholder: hook into Mail metadata source; schedule a debounce tick
        scheduleDebouncedScan()
    }

    public func stopObserving() {
        isObserving = false
    }

    // Manual sync trigger (e.g., from Settings)
    public func syncNow() {
        scheduleDebouncedScan()
    }

    // Debounced scan stub
    private func scheduleDebouncedScan() {
        processingQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.performScan()
        }
    }

    // Perform scan stub: in a real implementation, pull metadata, parse via MailMetadataParser, map to evidence
    private func performScan() {
        guard isObserving else { return }
        // TODO: Integrate real Mail metadata source. For now, mark lastSyncDate.
        lastSyncDate = Date()
    }
}
