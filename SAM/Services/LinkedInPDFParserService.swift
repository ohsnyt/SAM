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

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LinkedInPDFParser")

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

        // Extract all text from all pages
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

        return parseLines(cleanedLines)
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

    private static func parseLines(_ lines: [String]) -> LinkedInPDFProfileDTO {
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
        var name: String?
        var headline: String?
        var location: String?

        for (section, sectionLines) in sections {
            switch section {
            case .contact:
                let parsed = parseContactSection(sectionLines)
                email = parsed.email
                linkedInURL = parsed.linkedInURL
                phone = parsed.phone
                websiteURL = parsed.websiteURL

                // The name/headline/location may be at the tail of the Contact section
                // (PDFKit sometimes extracts sidebar + main header contiguously).
                // Strip contact data lines and take the last 3 remaining as name/headline/location.
                let nonContactLines = sectionLines.filter { !$0.isEmpty && !isContactDataLine($0) }
                if nonContactLines.count >= 1 {
                    let tail = Array(nonContactLines.suffix(3))
                    let extracted = extractNameHeadlineLocation(tail)
                    name = extracted.name
                    headline = extracted.headline
                    location = extracted.location
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
                // Name is typically 2-3 lines from the end: Name, Headline, Location
                let tail = Array(candidateLines.suffix(3))
                if !tail.isEmpty {
                    let extracted = extractNameHeadlineLocation(tail)
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

    private static func extractNameHeadlineLocation(_ lines: [String]) -> (name: String?, headline: String?, location: String?) {
        // LinkedIn PDFs have: Name, Headline, Location in the unnamed section.
        // But contact data (phone, email, URL) may leak into this section due to PDF text extraction order.
        // Filter those out before extracting name/headline/location.
        let meaningful = lines.filter { !$0.isEmpty && !isContactDataLine($0) }
        guard !meaningful.isEmpty else { return (nil, nil, nil) }

        let name = meaningful[0]

        // Headline: skip placeholder values like "--"
        var headline = meaningful.count > 1 ? meaningful[1] : nil
        if let h = headline, h.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).isEmpty {
            headline = nil
        }

        let location = meaningful.count > 2 ? meaningful[2] : nil

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
