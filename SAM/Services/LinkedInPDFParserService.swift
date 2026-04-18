//
//  LinkedInPDFParserService.swift
//  SAM
//
//  Deterministic parser for LinkedIn-generated profile PDFs.
//  Extracts structured contact, experience, education, and summary data
//  without AI — the LinkedIn PDF format is consistent enough for string parsing.
//

import Foundation
import PDFKit
import os.log

// MARK: - DTOs

struct LinkedInPDFProfileDTO: Sendable {
    let name: String
    let headline: String?
    let location: String?
    let email: String?
    let linkedInURL: String?
    let phone: String?
    let websiteURL: String?
    let summary: String?
    let topSkills: [String]
    let languages: [String]
    let honors: [String]
    let positions: [LinkedInPDFPosition]
    let education: [LinkedInPDFEducation]
}

struct LinkedInPDFPosition: Sendable {
    let title: String
    let company: String
    let dateRange: String
    let duration: String?
    let description: String?
}

struct LinkedInPDFEducation: Sendable {
    let school: String
    let degree: String?
    let dateRange: String?
}

// MARK: - Parser

enum LinkedInPDFParserService {

    private static let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LinkedInPDFParser")

    enum ParseError: LocalizedError {
        case cannotLoadPDF
        case noTextContent
        case notLinkedInProfile

        var errorDescription: String? {
            switch self {
            case .cannotLoadPDF: return "Could not load the PDF document."
            case .noTextContent: return "The PDF contains no readable text."
            case .notLinkedInProfile: return "This PDF doesn't appear to be a LinkedIn profile."
            }
        }
    }

    /// Parse a LinkedIn profile PDF from raw data.
    static func parse(data: Data) throws -> LinkedInPDFProfileDTO {
        guard let document = PDFDocument(data: data) else {
            throw ParseError.cannotLoadPDF
        }

        // Step 1: Extract name from font size on page 1.
        // LinkedIn PDFs always render the person's name in the largest font (~26pt).
        let fontExtracted = extractNameFromFont(document: document)

        // Step 2: Extract all text from all pages
        var allText = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string {
                allText += text + "\n"
            }
        }

        guard !allText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.noTextContent
        }

        // Clean up lines
        let rawLines = allText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Remove empty lines and "Page X of Y" footers
        let cleanedLines = rawLines.filter { line in
            guard !line.isEmpty else { return false }
            if line.range(of: #"^Page \d+ of \d+$"#, options: .regularExpression) != nil {
                return false
            }
            return true
        }

        // Validate this looks like a LinkedIn profile
        let fullText = cleanedLines.joined(separator: "\n").lowercased()
        guard fullText.contains("linkedin.com/in/") ||
              (fullText.contains("experience") && fullText.contains("education")) else {
            throw ParseError.notLinkedInProfile
        }

        // Skip non-English profiles — detect localized section headers
        let nonEnglishHeaders = ["kontakt", "top-kenntnisse", "ausbildung", "berufserfahrung", // German
                                  "contacto", "aptitudes", "experiencia", "educación",          // Spanish
                                  "compétences", "expérience", "formation",                     // French
                                  "contato", "competências", "experiência", "educação"]         // Portuguese
        let lowerLines = cleanedLines.map { $0.lowercased() }
        if nonEnglishHeaders.contains(where: { header in lowerLines.contains(header) }) {
            throw ParseError.notLinkedInProfile
        }

        return parseLines(cleanedLines, fontExtractedName: fontExtracted.name,
                          fontExtractedHeadline: fontExtracted.headline,
                          fontExtractedLocation: fontExtracted.location)
    }

    // MARK: - Font-Based Name Extraction

    /// Extract the person's name from PDF font attributes. LinkedIn PDFs always render
    /// the name in the largest font on page 1 (~26pt). The headline and location follow
    /// immediately after in the plain text.
    private static func extractNameFromFont(document: PDFDocument) -> (name: String?, headline: String?, location: String?) {
        guard let page = document.page(at: 0),
              let attrString = page.attributedString else { return (nil, nil, nil) }

        // Find the text rendered in the largest font — that's the name
        var maxFontSize: CGFloat = 0
        var nameText = ""
        attrString.enumerateAttributes(in: NSRange(location: 0, length: attrString.length)) { attrs, range, _ in
            let text = (attrString.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if let font = attrs[.font] as? NSFont, font.pointSize > maxFontSize {
                maxFontSize = font.pointSize
                nameText = text
            }
        }

        guard !nameText.isEmpty, maxFontSize > 20 else { return (nil, nil, nil) }

        // Find headline and location: lines immediately after the name in the plain text.
        // Headline may wrap across multiple lines. Location is typically the last line
        // before the next section header (Summary, Experience, etc.).
        let plainString = attrString.string
        guard let nameRange = plainString.range(of: nameText) else { return (nameText, nil, nil) }

        let afterName = String(plainString[nameRange.upperBound...])
        let lines = afterName.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Collect lines until we hit a section header
        let stopHeaders: Set<String> = ["Summary", "About", "Experience", "Education",
                                         "Top Skills", "Languages", "Contact", "Certifications",
                                         "Honors & Awards", "Honors-Awards", "Skills"]
        var contentLines: [String] = []
        for line in lines {
            if stopHeaders.contains(line) { break }
            contentLines.append(line)
        }

        // Last content line is location if it looks like a place (contains comma or known suffixes)
        var headline: String?
        var location: String?

        if contentLines.count >= 2 {
            let lastLine = contentLines.last!
            // Location heuristics
            if lastLine.contains(",") || lastLine.contains("Area") ||
               lastLine.hasSuffix("States") || lastLine.hasSuffix("Canada") ||
               lastLine.hasSuffix("Kingdom") || lastLine.hasSuffix("Guinea") ||
               lastLine.hasSuffix("Metroplex") || lastLine.contains("Greater") {
                location = lastLine
                let headlineLines = contentLines.dropLast()
                headline = headlineLines.joined(separator: " ")
            } else {
                // No clear location — all lines are headline
                headline = contentLines.joined(separator: " ")
            }
        } else if contentLines.count == 1 {
            headline = contentLines[0]
        }

        // Clean up placeholder headlines
        if let h = headline, h.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).isEmpty {
            headline = nil
        }

        return (nameText, headline, location)
    }

    // MARK: - Section Detection

    /// Known section headers in LinkedIn PDFs
    private enum Section: CaseIterable {
        case contact
        case topSkills
        case languages
        case summary
        case experience
        case education
        case certifications
        case honors
        case publications
        case volunteer
        case courses
        case projects
        case organizations
    }

    /// Map of all recognized header strings to their section.
    /// LinkedIn PDFs use varying header text (e.g. "Honors-Awards" vs "Honors & Awards").
    private static let headerMap: [String: Section] = [
        "Contact": .contact,
        "Top Skills": .topSkills,
        "Languages": .languages,
        "Summary": .summary,
        "About": .summary,
        "Experience": .experience,
        "Education": .education,
        "Certifications": .certifications,
        "Licenses & Certifications": .certifications,
        "Honors & Awards": .honors,
        "Honors-Awards": .honors,
        "Publications": .publications,
        "Volunteer Experience": .volunteer,
        "Courses": .courses,
        "Projects": .projects,
        "Organizations": .organizations,
        "Skills": .topSkills,
        "Recommendations": .honors,  // treat as ignorable
    ]

    private static let sectionHeaders: Set<String> = Set(headerMap.keys)

    private static func isSection(_ line: String) -> Section? {
        headerMap[line]
    }

    // MARK: - Line-by-Line Parsing

    private static func parseLines(_ lines: [String],
                                    fontExtractedName: String? = nil,
                                    fontExtractedHeadline: String? = nil,
                                    fontExtractedLocation: String? = nil) -> LinkedInPDFProfileDTO {
        // Phase 1: Split lines into sections
        var sections: [(section: Section?, lines: [String])] = []
        var currentSection: Section? = nil
        var currentLines: [String] = []

        for line in lines {
            if let section = isSection(line) {
                // Save previous section
                if !currentLines.isEmpty || currentSection != nil {
                    sections.append((section: currentSection, lines: currentLines))
                }
                currentSection = section
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        // Save final section
        if !currentLines.isEmpty {
            sections.append((section: currentSection, lines: currentLines))
        }

        // Phase 2: Extract data from each section
        var email: String?
        var linkedInURL: String?
        var phone: String?
        var websiteURL: String?
        var topSkills: [String] = []
        var languages: [String] = []
        var honors: [String] = []
        var summary: String?
        var positions: [LinkedInPDFPosition] = []
        var education: [LinkedInPDFEducation] = []
        // Font-based extraction is the primary source for name/headline/location
        var name: String? = fontExtractedName
        var headline: String? = fontExtractedHeadline
        var location: String? = fontExtractedLocation

        for (section, sectionLines) in sections {
            switch section {
            case .contact:
                let parsed = parseContactSection(sectionLines)
                email = parsed.email
                linkedInURL = parsed.linkedInURL
                phone = parsed.phone
                websiteURL = parsed.websiteURL

                // Fallback: if font-based extraction didn't find a name, try text heuristics
                if name == nil {
                    let nonContactLines = sectionLines.filter { !$0.isEmpty && !isContactDataLine($0) }
                    if !nonContactLines.isEmpty {
                        let extracted = extractNameHeadlineLocation(nonContactLines)
                        name = extracted.name
                        headline = extracted.headline
                        location = extracted.location
                    }
                }

            case .topSkills:
                topSkills = sectionLines.filter { !$0.isEmpty }

            case .languages:
                languages = sectionLines.filter { !$0.isEmpty }

            case .honors:
                honors = sectionLines.filter { !$0.isEmpty }

            case .summary:
                summary = sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if summary?.isEmpty == true { summary = nil }

            case .experience:
                positions = parseExperienceSection(sectionLines)

            case .education:
                education = parseEducationSection(sectionLines)

            case nil:
                // The unnamed section between sidebar and main content has: Name, Headline, Location.
                // But contact data (phone, email, URL) may also appear here due to text extraction order.
                if name == nil {
                    let extracted = extractNameHeadlineLocation(sectionLines)
                    name = extracted.name
                    headline = extracted.headline
                    location = extracted.location

                    // Salvage any contact data that leaked into this unnamed section
                    if phone == nil || email == nil || linkedInURL == nil {
                        let contactData = parseContactSection(sectionLines)
                        if phone == nil { phone = contactData.phone }
                        if email == nil { email = contactData.email }
                        if linkedInURL == nil { linkedInURL = contactData.linkedInURL }
                        if websiteURL == nil { websiteURL = contactData.websiteURL }
                    }
                }

            default:
                break // Ignore certifications, publications, etc.
            }
        }

        // If name wasn't found in an unnamed section, the name/headline/location
        // may be trapped at the END of a sidebar section (e.g. Certifications, Honors)
        // that immediately precedes Summary or Experience in the PDF text extraction order.
        // Strategy: find the section just before Summary/Experience and extract the last
        // 2-3 non-contact-data lines from it as name/headline/location.
        if name == nil {
            for (idx, entry) in sections.enumerated() {
                // Look for the section right before Summary or Experience
                let isBeforeMain = idx + 1 < sections.count &&
                    (sections[idx + 1].section == .summary || sections[idx + 1].section == .experience)
                guard isBeforeMain else { continue }

                // The name block is at the tail of this section's lines
                let candidateLines = entry.lines.filter { !$0.isEmpty && !isContactDataLine($0) }
                if !candidateLines.isEmpty {
                    let extracted = extractNameHeadlineLocation(candidateLines)
                    name = extracted.name
                    headline = extracted.headline
                    location = extracted.location
                }
                break
            }
        }

        // Last resort: scan all lines for a plausible name
        if name == nil {
            name = lines.first { !sectionHeaders.contains($0) && !$0.isEmpty && !isContactDataLine($0) } ?? "Unknown"
        }

        logger.debug("Parsed LinkedIn PDF: \(name ?? "unknown"), \(positions.count) positions, \(education.count) education entries")

        return LinkedInPDFProfileDTO(
            name: name ?? "Unknown",
            headline: headline,
            location: location,
            email: email,
            linkedInURL: linkedInURL,
            phone: phone,
            websiteURL: websiteURL,
            summary: summary,
            topSkills: topSkills,
            languages: languages,
            honors: honors,
            positions: positions,
            education: education
        )
    }

    // MARK: - Contact Section

    private static func parseContactSection(_ lines: [String]) -> (email: String?, linkedInURL: String?, phone: String?, websiteURL: String?) {
        var email: String?
        var linkedInURL: String?
        var phone: String?
        var websiteURL: String?

        // First pass: join lines that are continuations of a URL or email.
        // LinkedIn PDFs sometimes wrap long text across lines, e.g.:
        //   "www.linkedin.com/in/"          +  "jenniferholloran (LinkedIn)"
        //   "marion.hostetler@edwardjone"   +  "s.com"
        var joinedLines: [String] = []
        var i = 0
        while i < lines.count {
            var line = lines[i]

            if i + 1 < lines.count {
                let nextLine = lines[i + 1]

                // Join URL that ends with "/" and next line has a label
                let urlLabels = ["(LinkedIn)", "(Blog)", "(Other)", "(Portfolio)", "(Company Website)", "(Personal)"]
                if line.hasSuffix("/"), urlLabels.contains(where: { nextLine.contains($0) }) {
                    line = line + nextLine
                    i += 1
                }
                // Join partial LinkedIn URL missing its label
                else if line.lowercased().contains("linkedin.com/in/") && !line.contains("("),
                        nextLine.contains("(LinkedIn)") {
                    line = line + nextLine
                    i += 1
                }
                // Join partial LinkedIn URL where slug is on next line (no label on either)
                else if line.lowercased().hasSuffix("linkedin.com/in/") {
                    line = line + nextLine
                    i += 1
                }
                // Join wrapped email: line ends mid-domain and next line completes it
                else if line.contains("@") && !line.contains(" ") &&
                        line.range(of: #"\.[A-Za-z]{2,}$"#, options: .regularExpression) == nil,
                        !nextLine.contains(" ") && nextLine.range(of: #"^[A-Za-z]"#, options: .regularExpression) != nil {
                    line = line + nextLine
                    i += 1
                }
                // Join phone number with its label on the next line: "407.491.5861" + "(Mobile)"
                else if nextLine == "(Mobile)" || nextLine == "(Work)" || nextLine == "(Home)" {
                    line = line + " " + nextLine
                    i += 1
                }
            }
            joinedLines.append(line)
            i += 1
        }

        for line in joinedLines {
            // Skip physical address lines (contain digits + letters + common address words)
            let lowerLine = line.lowercased()
            let looksLikeAddress = (lowerLine.contains("rd ") || lowerLine.contains("ave ") ||
                                    lowerLine.contains("st ") || lowerLine.contains("blvd ") ||
                                    lowerLine.contains("dr ") || lowerLine.contains("ln ") ||
                                    lowerLine.range(of: #"^\d+\s+[A-Za-z]"#, options: .regularExpression) != nil ||
                                    lowerLine.range(of: #"^[A-Z]{2,}\s*\d{5}"#, options: .regularExpression) != nil ||
                                    lowerLine.range(of: #"\d{5}"#, options: .regularExpression) != nil && lowerLine.contains(","))

            // Email: match standard email pattern
            if email == nil,
               let match = line.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression) {
                email = String(line[match])
            }

            // LinkedIn URL
            if linkedInURL == nil, line.lowercased().contains("linkedin.com/in/") {
                var url = line
                    .replacingOccurrences(of: "(LinkedIn)", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !url.hasPrefix("http") {
                    url = "https://\(url)"
                }
                linkedInURL = url
            }

            // Website/Blog URL
            if websiteURL == nil {
                let blogLabels = ["(Blog)", "(Other)", "(Portfolio)", "(Company Website)", "(Personal)"]
                if blogLabels.contains(where: { line.contains($0) }) {
                    var url = line
                    for label in blogLabels {
                        url = url.replacingOccurrences(of: label, with: "")
                    }
                    url = url.trimmingCharacters(in: .whitespaces)
                    if !url.hasPrefix("http") {
                        url = "https://\(url)"
                    }
                    websiteURL = url
                }
            }

            // Phone: lines with (Mobile) or (Work) label, or digit sequences — skip addresses
            if phone == nil, !looksLikeAddress,
               !line.contains("@"), !line.contains(".com"), !line.contains(".org"), !line.contains(".net"), !line.contains(".at") {
                if line.contains("(Mobile)") || line.contains("(Work)") || line.contains("(Home)") {
                    // Labeled phone — extract digits
                    let cleaned = line
                        .replacingOccurrences(of: "(Mobile)", with: "")
                        .replacingOccurrences(of: "(Work)", with: "")
                        .replacingOccurrences(of: "(Home)", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    phone = cleaned
                } else if line.range(of: #"^[\+]?[\d\s\.\-\(\)]{7,}$"#, options: .regularExpression) != nil {
                    let digits = line.filter(\.isNumber)
                    if digits.count >= 7 && digits.count <= 15 {
                        phone = line.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        return (email, linkedInURL, phone, websiteURL)
    }

    // MARK: - Name / Headline / Location

    /// Check if a line looks like contact data (phone, email, URL, label) rather than name/headline/location.
    private static func isContactDataLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        // Email
        if line.contains("@") { return true }
        // URL or URL-related
        if lower.contains(".com") || lower.contains(".org") || lower.contains(".net") ||
           lower.contains(".edu") || lower.contains("linkedin.com") || lower.contains("http") { return true }
        // Parenthetical labels from LinkedIn Contact section
        let contactLabels = ["(LinkedIn)", "(Blog)", "(Other)", "(Portfolio)",
                             "(Company Website)", "(Personal)", "(Mobile)", "(Work)", "(Home)"]
        if contactLabels.contains(where: { line.contains($0) }) { return true }
        // Partial URL continuation (e.g. "husk-7895403a (LinkedIn)" or bare URL fragment ending with domain)
        if lower.hasSuffix(".com") || lower.hasSuffix(".org") || lower.hasSuffix(".com/") { return true }
        // Phone number: mostly digits/dots/dashes
        let digits = line.filter(\.isNumber)
        if digits.count >= 7 && Double(digits.count) / Double(max(line.count, 1)) > 0.5 { return true }
        // Lines that are just digits and punctuation (like "4693372467")
        if !digits.isEmpty && digits.count >= 5 && line.filter(\.isLetter).count < 3 { return true }
        return false
    }

    /// Detect whether a line looks like a person name: short, mostly letters, 2-5 words,
    /// no special characters typical of headlines (|, /, ·, @, •), and no common title/role words.
    private static func looksLikePersonName(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Too long for a name
        if trimmed.count > 40 { return false }
        // Contains headline/title indicators or punctuation unusual in names
        if trimmed.contains("|") || trimmed.contains("/") || trimmed.contains("·") ||
           trimmed.contains("•") || trimmed.contains("@") || trimmed.contains(",") ||
           trimmed.contains("(") || trimmed.contains(")") { return false }
        // Placeholder
        if trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).isEmpty { return false }
        // Word count: names are typically 2-5 words
        let words = trimmed.split(separator: " ").map(String.init)
        if words.count < 2 || words.count > 5 { return false }
        // Mostly alphabetic (allow periods, hyphens for "Jr.", "Mary-Jane")
        let letterCount = trimmed.filter(\.isLetter).count
        if Double(letterCount) / Double(trimmed.count) < 0.7 { return false }
        // Reject lines containing common title/role/organization words
        let lower = trimmed.lowercased()
        let titleWords = ["director", "manager", "president", "ceo", "cfo", "coo", "cto",
                          "officer", "pastor", "advisor", "consultant", "associate", "analyst",
                          "engineer", "specialist", "coordinator", "facilitator", "founder",
                          "professional", "certified", "church", "charities", "international",
                          "insurance", "financial", "ministry", "university", "institute",
                          "at ", "of ", "for "]
        if titleWords.contains(where: { lower.contains($0) }) { return false }
        return true
    }

    private static func extractNameHeadlineLocation(_ lines: [String]) -> (name: String?, headline: String?, location: String?) {
        // LinkedIn PDFs have: Name, Headline, Location — but these may be mixed with
        // other content (addresses, company names). Find the person name by heuristic.
        let meaningful = lines.filter { !$0.isEmpty && !isContactDataLine($0) }
        guard !meaningful.isEmpty else { return (nil, nil, nil) }

        // Find the first line that looks like a person name
        guard let nameIndex = meaningful.firstIndex(where: { looksLikePersonName($0) }) else {
            // Fallback: first line
            return (meaningful[0], meaningful.count > 1 ? meaningful[1] : nil, meaningful.count > 2 ? meaningful[2] : nil)
        }

        let name = meaningful[nameIndex]

        // Headline: lines after the name until we hit a location-looking line.
        // The location is typically the last line and contains a place name.
        // Join remaining lines as headline, with the last one as location.
        let afterName = Array(meaningful.suffix(from: meaningful.index(after: nameIndex)))

        var headline: String?
        var location: String?

        if afterName.count >= 2 {
            // Last line is location, everything between is headline
            location = afterName.last
            let headlineLines = afterName.dropLast()
            let joined = headlineLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty && joined.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).isEmpty == false {
                headline = joined
            }
        } else if afterName.count == 1 {
            // Could be headline or location — check if it looks like a location
            let candidate = afterName[0]
            if candidate.contains(",") || candidate.contains("Area") || candidate.contains("United States") ||
               candidate.contains("Canada") || candidate.contains("Kingdom") || candidate.contains("Guinea") {
                location = candidate
            } else {
                headline = candidate
            }
        }

        return (name, headline, location)
    }

    // MARK: - Experience Section

    /// Date range pattern: "Month Year - Month Year" or "Month Year - Present" or "Year - Year"
    private static let monthYearDatePattern = #"(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4}\s*-\s*(?:(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4}|Present)"#

    /// Year-only date pattern: "2008 - 2010" or "August 2018 - May 2022"
    private static let yearOnlyDatePattern = #"^\d{4}\s*-\s*(?:\d{4}|Present)"#

    /// Duration pattern: "(X years Y months)" or "(X months)" or "(X year)" etc.
    private static let durationPattern = #"\(\d+\s+(?:year|month|years|months)(?:\s+\d+\s+(?:year|month|years|months))?\)"#

    /// Check whether a line contains a date range (month-year or year-only)
    private static func isDateRangeLine(_ line: String) -> Bool {
        if line.range(of: monthYearDatePattern, options: .regularExpression) != nil { return true }
        if line.range(of: yearOnlyDatePattern, options: .regularExpression) != nil { return true }
        return false
    }

    /// A line that looks like just a duration: "X years Y months" or "X year Y months"
    private static func isDurationOnlyLine(_ line: String) -> Bool {
        line.range(of: #"^\d+\s+(?:year|month|years|months)(?:\s+\d+\s+(?:year|month|years|months))?$"#, options: .regularExpression) != nil
    }

    private static func parseExperienceSection(_ lines: [String]) -> [LinkedInPDFPosition] {
        var positions: [LinkedInPDFPosition] = []
        var currentCompany: String?
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Skip empty lines
            if line.isEmpty { i += 1; continue }

            // Check if this is a date range line — if so, the previous lines were company/title
            if isDateRangeLine(line) {
                // Extract duration if present
                var duration: String?
                if let match = line.range(of: durationPattern, options: .regularExpression) {
                    duration = String(line[match]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                }

                // Look back for title (line before date) and possibly company (line before that)
                // Pattern A (single company, single role): Company \n Duration \n Title \n DateRange
                // Pattern B (company with multiple roles): Company \n TotalDuration \n Title1 \n DateRange1

                // The title is typically the line right before the date range,
                // unless that line is a duration-only line
                var titleIndex = i - 1
                while titleIndex >= 0 && (isDurationOnlyLine(lines[titleIndex]) || lines[titleIndex].isEmpty) {
                    titleIndex -= 1
                }

                let title = titleIndex >= 0 ? lines[titleIndex] : "Unknown"

                // Check if there's a company above the title
                // A company line is followed by a duration-only line
                if titleIndex > 0 {
                    let aboveTitle = titleIndex - 1
                    if aboveTitle >= 0 && isDurationOnlyLine(lines[aboveTitle]) && aboveTitle > 0 {
                        // The line above the duration is the company
                        currentCompany = lines[aboveTitle - 1]
                    } else if aboveTitle >= 0 && !isDateRangeLine(lines[aboveTitle]) && !isDurationOnlyLine(lines[aboveTitle]) {
                        // Could be a new company name
                        currentCompany = lines[aboveTitle]
                    }
                }

                // Collect description lines after the date range
                var descLines: [String] = []
                var j = i + 1
                while j < lines.count {
                    let nextLine = lines[j]
                    if nextLine.isEmpty || isDateRangeLine(nextLine) || isDurationOnlyLine(nextLine) {
                        break
                    }
                    // Check if next line is a new section or new company/title
                    if sectionHeaders.contains(nextLine) { break }
                    // If the line after this looks like a date range, this is probably a title not description
                    if j + 1 < lines.count && isDateRangeLine(lines[j + 1]) { break }
                    descLines.append(nextLine)
                    j += 1
                }

                let description = descLines.isEmpty ? nil : descLines.joined(separator: " ")

                positions.append(LinkedInPDFPosition(
                    title: title,
                    company: currentCompany ?? "Unknown",
                    dateRange: line,
                    duration: duration,
                    description: description
                ))

                i = j
                continue
            }

            i += 1
        }

        return positions
    }

    // MARK: - Education Section

    private static func parseEducationSection(_ lines: [String]) -> [LinkedInPDFEducation] {
        var entries: [LinkedInPDFEducation] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }

            // School name is the first non-empty line
            let school = line

            // Next line(s) may be: "Degree · (DateRange)" or "Degree, Field · (DateRange)" or just a degree
            var degree: String?
            var dateRange: String?

            if i + 1 < lines.count {
                let nextLine = lines[i + 1]
                if !nextLine.isEmpty && !sectionHeaders.contains(nextLine) {
                    // Parse degree line — may contain " · " or "· " separator and date range in parens
                    // Variants seen:
                    //   "Doctor of Strategic Leadership, Strategic Leadership · (2017 - 2021)"
                    //   " · (1976 - 1978)"     — no degree, just dates
                    //   "N/A, FIELD · (dates)"  — explicit N/A
                    var degreePart = nextLine

                    // Try middle dot separator (Unicode \u{00B7})
                    let dotSeparators = [" \u{00B7} ", "\u{00B7} ", " \u{00B7}"]
                    var foundSeparator = false
                    for sep in dotSeparators {
                        if let dotRange = degreePart.range(of: sep) {
                            let afterDot = String(degreePart[dotRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                            degreePart = String(degreePart[..<dotRange.lowerBound])
                            if afterDot.hasPrefix("(") && afterDot.hasSuffix(")") {
                                dateRange = String(afterDot.dropFirst().dropLast())
                            } else if !afterDot.isEmpty {
                                dateRange = afterDot
                            }
                            foundSeparator = true
                            break
                        }
                    }

                    // Clean up degree: treat "N/A" as nil
                    degreePart = degreePart.trimmingCharacters(in: .whitespaces)
                    if degreePart.isEmpty || degreePart == "N/A" {
                        degree = nil
                    } else {
                        degree = degreePart
                    }

                    // Only consume this line if it looks like a degree/date line (has separator or is not a school name)
                    if foundSeparator || degreePart.contains(",") || nextLine.hasPrefix(" ") {
                        i += 1
                    }
                }
            }

            entries.append(LinkedInPDFEducation(
                school: school,
                degree: degree,
                dateRange: dateRange
            ))

            i += 1
        }

        return entries
    }
}
