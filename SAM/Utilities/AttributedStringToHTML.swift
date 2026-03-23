//
//  AttributedStringToHTML.swift
//  SAM
//
//  Created on March 23, 2026.
//  Converts NSAttributedString to HTML for email composition.
//  Handles bold, italic, hyperlinks, and inline images.
//

import AppKit
import Foundation

enum AttributedStringToHTML {

    /// Result of HTML conversion, including inline image attachments.
    struct ConversionResult: Sendable {
        let html: String
        /// Inline images: (imageData, contentID, filename)
        let inlineImages: [(Data, String, String)]
    }

    /// Convert an NSAttributedString to email-ready HTML.
    @MainActor
    static func convert(_ attrString: NSAttributedString) -> ConversionResult {
        var html = ""
        var images: [(Data, String, String)] = []
        var imageIndex = 0

        attrString.enumerateAttributes(
            in: NSRange(location: 0, length: attrString.length),
            options: []
        ) { attrs, range, _ in
            // Handle image attachments
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let data = RichNoteEditorHandle.imageDataFromAttachment(attachment) {
                    let cid = "image\(imageIndex)@sam.local"
                    let filename = "image\(imageIndex).png"
                    images.append((data, cid, filename))
                    html += "<img src=\"cid:\(cid)\" style=\"max-width:100%;\" />"
                    imageIndex += 1
                }
                return
            }

            let substring = (attrString.string as NSString).substring(with: range)
                .replacingOccurrences(of: "\u{FFFC}", with: "")

            guard !substring.isEmpty else { return }

            // Escape HTML entities
            var text = substring
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")

            // Check for formatting
            var isBold = false
            var isItalic = false

            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                isBold = traits.contains(.boldFontMask)
                isItalic = traits.contains(.italicFontMask)
            }

            // Apply formatting tags
            if isBold { text = "<b>\(text)</b>" }
            if isItalic { text = "<i>\(text)</i>" }

            // Wrap in link if present
            if let link = attrs[.link] {
                let urlString: String
                if let url = link as? URL {
                    urlString = url.absoluteString
                } else if let str = link as? String {
                    urlString = str
                } else {
                    urlString = ""
                }
                if !urlString.isEmpty {
                    text = "<a href=\"\(urlString.replacingOccurrences(of: "\"", with: "&quot;"))\">\(text)</a>"
                }
            }

            html += text
        }

        // Wrap in a basic HTML document (no leading whitespace — Mail.app is sensitive to it)
        let fullHTML = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family: -apple-system, Helvetica Neue, sans-serif; font-size: 14px; color: #333;\">\(html)</body></html>"

        return ConversionResult(html: fullHTML, inlineImages: images)
    }
}
