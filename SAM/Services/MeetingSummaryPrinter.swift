//
//  MeetingSummaryPrinter.swift
//  SAM
//
//  Renders a `MeetingSummary` into a printable attributed document with
//  multi-page pagination and a footer (date on left, page X of Y on right).
//  The NSPrintOperation preview also allows Save as PDF, so users can print,
//  export, or email the summary from the same entry point.
//

import AppKit
import CoreText
import Foundation

enum MeetingSummaryPrinter {

    /// Present the print panel for the given session's summary.
    @MainActor
    static func presentPrintPanel(for session: TranscriptSession) {
        guard let json = session.meetingSummaryJSON,
              let summary = MeetingSummary.from(jsonString: json),
              summary.hasContent else {
            return
        }

        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 72     // room for title header
        printInfo.bottomMargin = 72  // room for date + page count footer
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54

        let textWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textHeight = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin
        let pageSize = NSSize(width: textWidth, height: textHeight)

        // The NSTextView-based renderer struggles to paginate reliably on
        // macOS 26 (NSTextView now defaults to TextKit 2, and `usedRect` /
        // pagination over multiple pages becomes brittle). Use a CoreText
        // framesetter instead — it gives us deterministic per-page ranges.
        let attrString = buildAttributedString(session: session, summary: summary)
        let view = PaginatedSummaryView(frame: NSRect(origin: .zero, size: pageSize))
        view.printDate = .now
        view.headerTitle = headerTitle(for: session)
        view.setAttributedString(attrString, pageSize: pageSize)

        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = printJobTitle(for: session)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    // MARK: - Job title

    private static func printJobTitle(for session: TranscriptSession) -> String {
        let prefix: String
        switch session.recordingContext {
        case .trainingLecture:     prefix = "Lecture Summary"
        case .boardMeeting:        prefix = "Board Minutes"
        case .prospectingCall:     prefix = "Prospecting Call"
        case .recruitingInterview: prefix = "Recruiting Interview"
        case .annualReview:        prefix = "Annual Review"
        case .clientMeeting:       prefix = "Meeting Summary"
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        return "\(prefix) — \(dateFormatter.string(from: session.recordedAt))"
    }

    /// Short title that appears in the top-left of every printed page.
    /// Prefers the user-editable session title; falls back to the context-based
    /// job title so legacy sessions still get a meaningful header.
    private static func headerTitle(for session: TranscriptSession) -> String {
        if let t = session.title, !t.isEmpty {
            return t
        }
        return printJobTitle(for: session)
    }

    // MARK: - Attributed string builder

    private static func buildAttributedString(
        session: TranscriptSession,
        summary: MeetingSummary
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()

        // Title
        output.append(paragraph(printJobTitle(for: session), style: .title))

        // Subtitle with duration and speakers
        var subtitleParts: [String] = []
        let minutes = Int(session.durationSeconds) / 60
        let seconds = Int(session.durationSeconds) % 60
        if session.durationSeconds > 0 {
            subtitleParts.append("Duration: \(minutes)m \(seconds)s")
        }
        if session.speakerCount > 0 {
            subtitleParts.append("\(session.speakerCount) speaker\(session.speakerCount == 1 ? "" : "s")")
        }
        if !subtitleParts.isEmpty {
            output.append(paragraph(subtitleParts.joined(separator: " · "), style: .subtitle))
        }

        // Review notes (training/lecture — now the opening section)
        if let notes = summary.reviewNotes, !notes.isEmpty {
            output.append(sectionHeader("Review Notes"))
            // Chunk merges join per-chunk review notes with "\n\n", which leaves
            // a visible blank line between paragraphs. Collapse runs of blank
            // lines to a single `\n` so paragraphSpacing alone creates the gap.
            let normalized = notes.replacingOccurrences(
                of: "\n{2,}",
                with: "\n",
                options: .regularExpression
            )
            output.append(paragraph(normalized, style: .body))
        }

        // TLDR (non-lecture contexts)
        if !summary.tldr.isEmpty {
            output.append(sectionHeader("Summary"))
            output.append(paragraph(summary.tldr, style: .body))
        }

        // Topics
        if !summary.topics.isEmpty {
            output.append(sectionHeader("Topics"))
            output.append(paragraph(summary.topics.joined(separator: " · "), style: .body))
        }

        // Compliance flags
        if !summary.complianceFlags.isEmpty {
            output.append(sectionHeader("Compliance Review"))
            for flag in summary.complianceFlags {
                output.append(bullet(flag))
            }
        }

        // Compliance strengths (counterweight to flags)
        if !summary.complianceStrengths.isEmpty {
            output.append(sectionHeader("Compliance Strengths"))
            for item in summary.complianceStrengths {
                output.append(bullet(item))
            }
        }

        // Retention signals (client retention risk)
        if !summary.retentionSignals.isEmpty {
            output.append(sectionHeader("Retention Signals"))
            for signal in summary.retentionSignals {
                output.append(bullet(signal))
            }
        }

        // Numerical reframing (auditable original → revised figure pairs)
        if !summary.numericalReframing.isEmpty {
            output.append(sectionHeader("Numerical Reframing"))
            for reframe in summary.numericalReframing {
                output.append(bullet(reframe))
            }
        }

        // Learning Objectives
        if !summary.learningObjectives.isEmpty {
            output.append(sectionHeader("Learning Objectives"))
            for obj in summary.learningObjectives {
                output.append(bullet(obj))
            }
        }

        // Key Points
        if !summary.keyPoints.isEmpty {
            output.append(sectionHeader("Key Points"))
            for point in summary.keyPoints {
                output.append(bullet(point))
            }
        }

        // Open Questions
        if !summary.openQuestions.isEmpty {
            output.append(sectionHeader("Open Questions"))
            for question in summary.openQuestions {
                output.append(bullet(question))
            }
        }

        // Action Items
        if !summary.actionItems.isEmpty {
            output.append(sectionHeader("Action Items"))
            for item in summary.actionItems {
                var line = item.task
                var meta: [String] = []
                if let owner = item.owner, !owner.isEmpty { meta.append(owner) }
                if let due = item.dueDate, !due.isEmpty { meta.append("due \(due)") }
                if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
                output.append(bullet(line))
            }
        }

        // Decisions
        if !summary.decisions.isEmpty {
            output.append(sectionHeader("Decisions"))
            for decision in summary.decisions {
                output.append(bullet(decision))
            }
        }

        // Follow-ups
        if !summary.followUps.isEmpty {
            output.append(sectionHeader("Follow-ups"))
            for followUp in summary.followUps {
                output.append(bullet("\(followUp.person): \(followUp.reason)"))
            }
        }

        // Life Events
        if !summary.lifeEvents.isEmpty {
            output.append(sectionHeader("Life Events"))
            for event in summary.lifeEvents {
                output.append(bullet(event))
            }
        }

        // Attendees (board)
        if !summary.attendees.isEmpty {
            output.append(sectionHeader("Attendees"))
            output.append(paragraph(summary.attendees.joined(separator: ", "), style: .body))
        }

        // Agenda items (board)
        if !summary.agendaItems.isEmpty {
            output.append(sectionHeader("Agenda Items"))
            for item in summary.agendaItems {
                output.append(bullet(item.title, bold: true))
                if let sum = item.summary, !sum.isEmpty {
                    output.append(indented(sum))
                }
                if let outcome = item.outcome, !outcome.isEmpty {
                    output.append(indented("Outcome: \(outcome)"))
                }
                if let notes = item.notes, !notes.isEmpty {
                    output.append(indented(notes))
                }
            }
        }

        // Votes (board)
        if !summary.votes.isEmpty {
            output.append(sectionHeader("Votes"))
            for vote in summary.votes {
                output.append(bullet(vote.motion, bold: true))
                output.append(indented("Result: \(vote.result)"))
                if let moved = vote.movedBy, !moved.isEmpty {
                    output.append(indented("Moved by: \(moved)"))
                }
                if let seconded = vote.secondedBy, !seconded.isEmpty {
                    output.append(indented("Seconded by: \(seconded)"))
                }
                if let notes = vote.notes, !notes.isEmpty {
                    output.append(indented(notes))
                }
            }
        }

        return output
    }

    // MARK: - Attributed-string helpers

    private enum TextStyle { case title, subtitle, header, body }

    private static func paragraph(_ text: String, style: TextStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 8

        let font: NSFont
        let color: NSColor
        switch style {
        case .title:
            font = .systemFont(ofSize: 22, weight: .bold)
            color = .labelColor
            paragraph.paragraphSpacing = 4
        case .subtitle:
            font = .systemFont(ofSize: 11, weight: .regular)
            color = .secondaryLabelColor
            paragraph.paragraphSpacing = 16
        case .header:
            font = .systemFont(ofSize: 14, weight: .semibold)
            color = .labelColor
            paragraph.paragraphSpacingBefore = 12
            paragraph.paragraphSpacing = 4
        case .body:
            font = .systemFont(ofSize: 11, weight: .regular)
            color = .labelColor
        }

        return NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func sectionHeader(_ title: String) -> NSAttributedString {
        paragraph(title, style: .header)
    }

    private static func bullet(_ text: String, bold: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        paragraph.paragraphSpacing = 4
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 14
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 14)]

        let font: NSFont = bold
            ? .systemFont(ofSize: 11, weight: .semibold)
            : .systemFont(ofSize: 11, weight: .regular)

        return NSAttributedString(
            string: "•\t\(text)\n",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func indented(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 14
        paragraph.headIndent = 14
        paragraph.paragraphSpacing = 4

        return NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
    }
}

// MARK: - Paginated summary view (CoreText-based)

/// NSView subclass that paginates a long attributed string using CoreText and
/// draws a title header + date/page footer on every printed page.
///
/// CoreText is used instead of an NSTextView subclass because NSTextView on
/// macOS 26 defaults to TextKit 2, whose multi-page pagination during
/// `NSPrintOperation` is brittle — content beyond the first page fails to
/// render even with an oversize view frame. CoreText gives us deterministic
/// per-page glyph ranges and makes pagination independent of NSTextView's
/// layout lifecycle.
final class PaginatedSummaryView: NSView {

    var printDate: Date = .now
    var headerTitle: String = ""

    private var attrString: NSAttributedString = NSAttributedString()
    private var pageRanges: [CFRange] = []

    /// Install the attributed text and precompute page break positions for
    /// a text rectangle of `pageSize`. Must be called before printing.
    func setAttributedString(_ string: NSAttributedString, pageSize: NSSize) {
        self.attrString = string
        computePageRanges(pageSize: pageSize)
    }

    private func computePageRanges(pageSize: NSSize) {
        pageRanges.removeAll()
        guard attrString.length > 0 else { return }

        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)
        let path = CGPath(
            rect: CGRect(origin: .zero, size: pageSize),
            transform: nil
        )
        var index: CFIndex = 0
        let total = attrString.length

        while index < total {
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: index, length: 0),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }
            pageRanges.append(visible)
            index += visible.length
        }

        if pageRanges.isEmpty {
            pageRanges.append(CFRange(location: 0, length: total))
        }
    }

    // CoreText assumes bottom-left origin. We flip the view to top-down so
    // `drawPageBorder` coordinates match AppKit convention, and flip the CG
    // context manually inside `draw(_:)` when handing off to CoreText.
    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, pageRanges.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let currentPage = NSPrintOperation.current?.currentPage ?? 1
        let pageIndex = currentPage - 1
        guard pageIndex >= 0, pageIndex < pageRanges.count else { return }

        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)

        context.saveGState()
        // View is flipped (top-left origin); CoreText expects bottom-left.
        // Flip the CTM locally so the first line of the frame lands at the
        // top of the page rect.
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let path = CGPath(
            rect: CGRect(origin: .zero, size: bounds.size),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, pageRanges[pageIndex], path, nil)
        CTFrameDraw(frame, context)

        context.restoreGState()
    }

    override func drawPageBorder(with borderSize: NSSize) {
        guard let operation = NSPrintOperation.current else { return }

        let printInfo = operation.printInfo
        let paperSize = printInfo.paperSize
        let leftMargin = printInfo.leftMargin
        let rightMargin = printInfo.rightMargin
        let topMargin = printInfo.topMargin
        let bottomMargin = printInfo.bottomMargin

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateString = dateFormatter.string(from: printDate)

        let pageString = "Page \(operation.currentPage) of \(max(1, pageRanges.count))"

        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        // `drawPageBorder` runs in paper-coordinate space (bottom-left origin,
        // unflipped), so Y increases upward.
        if !headerTitle.isEmpty {
            let headerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let headerAttr = NSAttributedString(string: headerTitle, attributes: headerAttrs)
            let headerY = paperSize.height - (topMargin - 30) - headerAttr.size().height
            headerAttr.draw(at: NSPoint(x: leftMargin, y: headerY))
        }

        let footerY = bottomMargin - 30
        let dateAttr = NSAttributedString(string: dateString, attributes: footerAttrs)
        let pageAttr = NSAttributedString(string: pageString, attributes: footerAttrs)

        dateAttr.draw(at: NSPoint(x: leftMargin, y: footerY))
        let pageTextSize = pageAttr.size()
        let rightX = paperSize.width - rightMargin - pageTextSize.width
        pageAttr.draw(at: NSPoint(x: rightX, y: footerY))
    }
}
