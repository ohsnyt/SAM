//
//  GuideMarkdownRenderer.swift
//  SAM
//
//  Help & Training System — Markdown to SwiftUI renderer with image, table, and link support
//

import SwiftUI

// MARK: - Markdown Segment

/// Represents a parsed segment of markdown content.
enum MarkdownSegment: Identifiable {
    case text(String)
    case heading(level: Int, text: String)
    case image(alt: String, path: String)
    case table(headers: [String], rows: [[String]])
    case divider
    case seeAlso(links: [SeeAlsoLink])

    var id: String {
        switch self {
        case .text(let s): return "text-\(s.hashValue)"
        case .heading(let l, let t): return "h\(l)-\(t.hashValue)"
        case .image(_, let p): return "img-\(p)"
        case .table(let h, _): return "table-\(h.joined())"
        case .divider: return "divider-\(UUID().uuidString)"
        case .seeAlso(let links): return "seealso-\(links.count)"
        }
    }
}

/// A parsed "See Also" link entry.
struct SeeAlsoLink: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let description: String
    let articleID: String?
}

// MARK: - Renderer View

struct GuideMarkdownRenderer: View {

    let markdown: String
    let sectionID: String

    @State private var guideService = GuideContentService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(parseSegments(from: markdown)) { segment in
                switch segment {
                case .text(let md):
                    textView(for: md)
                case .heading(let level, let text):
                    headingView(level: level, text: text)
                case .image(let alt, let path):
                    imageView(alt: alt, path: path)
                case .table(let headers, let rows):
                    tableView(headers: headers, rows: rows)
                case .divider:
                    Divider()
                        .padding(.vertical, 4)
                case .seeAlso(let links):
                    seeAlsoView(links: links)
                }
            }
        }
    }

    // MARK: - Heading Rendering

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let font: Font = switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
        Text(text)
            .font(font)
            .fontWeight(.semibold)
            .textSelection(.enabled)
            .padding(.top, level == 1 ? 4 : 2)
    }

    // MARK: - Text Rendering

    @ViewBuilder
    private func textView(for md: String) -> some View {
        let cleaned = md.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            EmptyView()
        } else if let attributed = try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .samFont(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(cleaned)
                .samFont(.body)
                .textSelection(.enabled)
        }
    }

    // MARK: - See Also Rendering

    @ViewBuilder
    private func seeAlsoView(links: [SeeAlsoLink]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(links) { (link: SeeAlsoLink) in
                if let articleID = link.articleID {
                    Button {
                        guideService.navigateTo(articleID: articleID)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                                .samFont(.caption)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title)
                                    .samFont(.callout, weight: .medium)
                                    .foregroundStyle(Color.accentColor)
                                if !link.description.isEmpty {
                                    Text(link.description)
                                        .samFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    // Unresolved link — render as plain text
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "doc.text")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.title)
                                .samFont(.callout, weight: .medium)
                            if !link.description.isEmpty {
                                Text(link.description)
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Image Rendering

    @ViewBuilder
    private func imageView(alt: String, path: String) -> some View {
        let imageName = (path as NSString).deletingPathExtension
        let resolvedPath = resolveImagePath(path)

        if let nsImage = loadImage(name: imageName, resolvedPath: resolvedPath) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 600)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
                .accessibilityLabel(Text(alt))
        } else {
            // Placeholder for missing image
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(height: 100)
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                        Text(alt)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }

    private func resolveImagePath(_ path: String) -> String {
        // Handle relative paths like "images/01-01.png"
        if path.hasPrefix("images/") {
            return "Guide/\(sectionID)/\(path)"
        }
        // Handle bare filenames like "01-01.png"
        return "Guide/\(sectionID)/images/\(path)"
    }

    private func loadImage(name: String, resolvedPath: String) -> NSImage? {
        let baseName = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension

        // Try subdirectory path first (folder references)
        if let url = Bundle.main.url(forResource: baseName, withExtension: ext, subdirectory: "Guide/\(sectionID)/images") {
            return NSImage(contentsOf: url)
        }
        // Try flat bundle (Xcode groups flatten resources)
        if let url = Bundle.main.url(forResource: baseName, withExtension: ext) {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    // MARK: - Table Rendering

    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            // Header row
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(header)
                        .samFont(.caption, weight: .bold)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
                .gridCellUnsizedAxes(.horizontal)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .samFont(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Parsing

    private func parseSegments(from markdown: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var currentText = ""
        let lines = markdown.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Check for horizontal rule: ---, ***, ___
            if isHorizontalRule(line) {
                if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                // Check if this divider precedes a "## See Also" section
                if let seeAlso = parseSeeAlsoSection(lines: lines, startingAfter: i) {
                    segments.append(.divider)
                    segments.append(.heading(level: 2, text: "See Also"))
                    segments.append(seeAlso.segment)
                    i = seeAlso.endIndex
                    continue
                }
                segments.append(.divider)
                i += 1
                continue
            }

            // Check for heading: #, ##, ###, ####
            if let (level, headingText) = parseHeadingLine(line) {
                if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                segments.append(.heading(level: level, text: headingText))
                i += 1
                continue
            }

            // Check for image: ![alt](path)
            if let imageMatch = parseImageLine(line) {
                if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                segments.append(.image(alt: imageMatch.alt, path: imageMatch.path))
                i += 1
                continue
            }

            // Check for table start (pipe-delimited)
            if line.contains("|") && i + 1 < lines.count && lines[i + 1].contains("---") {
                if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(currentText))
                    currentText = ""
                }
                let (table, consumed) = parseTable(lines: lines, startingAt: i)
                if let table {
                    segments.append(table)
                }
                i += consumed
                continue
            }

            currentText += line + "\n"
            i += 1
        }

        if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.text(currentText))
        }

        return segments
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        // Must be all dashes, asterisks, or underscores (with optional spaces)
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        return stripped.allSatisfy({ $0 == "-" }) ||
               stripped.allSatisfy({ $0 == "*" }) ||
               stripped.allSatisfy({ $0 == "_" })
    }

    // MARK: - See Also Parsing

    private struct SeeAlsoResult {
        let segment: MarkdownSegment
        let endIndex: Int
    }

    /// Looks ahead from a `---` divider to detect a `## See Also` section and parse its bullet links.
    private func parseSeeAlsoSection(lines: [String], startingAfter dividerIndex: Int) -> SeeAlsoResult? {
        var j = dividerIndex + 1
        // Skip blank lines
        while j < lines.count && lines[j].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            j += 1
        }
        guard j < lines.count else { return nil }

        // Must be a "## See Also" heading
        let headingLine = lines[j].trimmingCharacters(in: .whitespaces)
        guard headingLine.lowercased().hasPrefix("## see also") else { return nil }
        j += 1

        // Skip blank lines after heading
        while j < lines.count && lines[j].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            j += 1
        }

        // Parse bullet items: "- **Title** — description"
        var links: [SeeAlsoLink] = []
        while j < lines.count {
            let bulletLine = lines[j].trimmingCharacters(in: .whitespaces)
            guard bulletLine.hasPrefix("- ") else { break }
            if let link = parseSeeAlsoLink(bulletLine) {
                links.append(link)
            }
            j += 1
        }

        guard !links.isEmpty else { return nil }
        return SeeAlsoResult(segment: .seeAlso(links: links), endIndex: j)
    }

    /// Parses a single See Also bullet: `- **Title** — description`
    private func parseSeeAlsoLink(_ line: String) -> SeeAlsoLink? {
        // Strip leading "- "
        var content = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        // Extract bold title: **Title**
        guard content.hasPrefix("**") else { return nil }
        content = String(content.dropFirst(2))
        guard let endBold = content.range(of: "**") else { return nil }
        let title = String(content[content.startIndex..<endBold.lowerBound]).trimmingCharacters(in: .whitespaces)
        content = String(content[endBold.upperBound...]).trimmingCharacters(in: .whitespaces)

        // Strip leading em-dash or hyphen separator
        if content.hasPrefix("—") || content.hasPrefix("—") {
            content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if content.hasPrefix("-") {
            content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        let description = content

        // Resolve the title to an article ID by matching article titles
        let articleID = resolveArticleID(for: title)

        return SeeAlsoLink(title: title, description: description, articleID: articleID)
    }

    /// Resolves an article title to its ID by searching the guide manifest.
    private func resolveArticleID(for title: String) -> String? {
        let lowered = title.lowercased()
        return guideService.articles.first { $0.title.lowercased() == lowered }?.id
    }

    // MARK: - Line Parsers

    private func parseHeadingLine(_ line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 4 else { return nil }
        let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private struct ImageMatch {
        let alt: String
        let path: String
    }

    private func parseImageLine(_ line: String) -> ImageMatch? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("![") else { return nil }

        guard let altEnd = trimmed.range(of: "](") else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd.lowerBound])

        let pathStart = altEnd.upperBound
        guard let pathEnd = trimmed.range(of: ")", range: pathStart..<trimmed.endIndex) else { return nil }
        let path = String(trimmed[pathStart..<pathEnd.lowerBound])

        return ImageMatch(alt: alt, path: path)
    }

    private func parseTable(lines: [String], startingAt start: Int) -> (MarkdownSegment?, Int) {
        guard start < lines.count else { return (nil, 1) }

        let headerLine = lines[start]
        let headers = parsePipeLine(headerLine)
        guard !headers.isEmpty else { return (nil, 1) }

        // Skip separator line (e.g., |---|---|)
        var i = start + 2

        var rows: [[String]] = []
        while i < lines.count {
            let line = lines[i]
            guard line.contains("|") else { break }
            let cells = parsePipeLine(line)
            if !cells.isEmpty {
                rows.append(cells)
            }
            i += 1
        }

        return (.table(headers: headers, rows: rows), i - start)
    }

    private func parsePipeLine(_ line: String) -> [String] {
        line
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { $0 == "-" || $0 == ":" } }
    }
}
