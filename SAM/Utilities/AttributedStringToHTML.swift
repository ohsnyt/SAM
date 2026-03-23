//
//  AttributedStringToHTML.swift
//  SAM
//
//  Created on March 23, 2026.
//  Converts NSAttributedString to HTML for email composition.
//  Handles bold, italic, hyperlinks, and inline images (base64 data URIs).
//

import AppKit
import Foundation

enum AttributedStringToHTML {

    /// Result of HTML conversion. Images are embedded as base64 data URIs
    /// so no separate attachment handling is needed.
    struct ConversionResult: Sendable {
        let html: String
    }

    /// Convert an NSAttributedString to email-ready HTML.
    /// Images are embedded as base64 data URIs at their current display size.
    @MainActor
    static func convert(_ attrString: NSAttributedString) -> ConversionResult {
        var html = ""

        attrString.enumerateAttributes(
            in: NSRange(location: 0, length: attrString.length),
            options: []
        ) { attrs, range, _ in
            // Handle image attachments — embed as base64 data URIs
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let imageHTML = imageToDataURI(attachment) {
                    html += imageHTML
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

        // Wrap in a basic HTML document
        let fullHTML = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family: -apple-system, Helvetica Neue, sans-serif; font-size: 14px; color: #333;\">\(html)</body></html>"

        return ConversionResult(html: fullHTML)
    }

    // MARK: - Image Helpers

    /// Convert an NSTextAttachment image to an inline base64 data URI `<img>` tag,
    /// using the attachment's display bounds for width/height.
    private static func imageToDataURI(_ attachment: NSTextAttachment) -> String? {
        guard let data = RichNoteEditorHandle.imageDataFromAttachment(attachment) else { return nil }

        let base64 = data.base64EncodedString()

        // Use the attachment bounds for the display size (reflects user resizing)
        let bounds = attachment.bounds
        var style = "max-width:100%; display:block;"
        if bounds.width > 0 && bounds.height > 0 {
            style = "width:\(Int(bounds.width))px; height:\(Int(bounds.height))px; display:block;"
        }

        return "<img src=\"data:image/png;base64,\(base64)\" style=\"\(style)\" />"
    }
}
