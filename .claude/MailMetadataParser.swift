import Foundation

public struct EmailInteraction {
    public let messageID: String
    public let threadID: String?
    public let date: Date
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String

    public init(messageID: String, threadID: String?, date: Date, from: String, to: [String], cc: [String], bcc: [String], subject: String) {
        self.messageID = messageID
        self.threadID = threadID
        self.date = date
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
    }
}

public enum MailMetadataParser {
    // Normalize raw header fields into a canonical EmailInteraction; returns nil if required fields are missing
    public static func parse(headers: [String: String]) -> EmailInteraction? {
        // Required: Message-ID, Date, From
        guard let messageID = headers["Message-ID"],
              let dateString = headers["Date"],
              let from = headers["From"],
              !messageID.isEmpty, !dateString.isEmpty, !from.isEmpty else { return nil }

        let subject = headers["Subject"] ?? ""
        let threadID = headers["Thread-Index"] ?? headers["In-Reply-To"]

        let to = splitAddresses(headers["To"])
        let cc = splitAddresses(headers["Cc"])
        let bcc = splitAddresses(headers["Bcc"])

        let date = parseDate(dateString) ?? Date()

        return EmailInteraction(messageID: messageID, threadID: threadID, date: date, from: from, to: to, cc: cc, bcc: bcc, subject: subject)
    }

    private static func splitAddresses(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func parseDate(_ value: String) -> Date? {
        // Very lenient RFC 2822 date parsing attempt
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let d = formatter.date(from: value) { return d }
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }
}
