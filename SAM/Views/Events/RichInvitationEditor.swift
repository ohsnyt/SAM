//
//  RichInvitationEditor.swift
//  SAM
//
//  Created on March 23, 2026.
//  NSViewRepresentable wrapping NSTextView for rich invitation editing.
//  Supports Cmd+B (bold), Cmd+I (italic), Cmd+K (insert link),
//  inline images, and QR code embedding.
//

import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RichInvitationEditor")

// MARK: - Handle

/// Shared handle for parent views to extract content, insert links/images, and toggle formatting.
@MainActor
final class RichInvitationEditorHandle {

    weak var textView: NSTextView?

    /// Callback when the user presses Cmd+K to insert a link.
    var onInsertLink: (() -> Void)?

    /// Callback when selection changes — reports (hasImage, currentScale 0–1).
    var onSelectionChanged: ((Bool, CGFloat) -> Void)?

    // MARK: - Content Extraction

    /// Extract the full attributed string for HTML conversion (email sends).
    func extractAttributedString() -> NSAttributedString {
        textView?.attributedString() ?? NSAttributedString()
    }

    /// Extract plain text only, stripping images (for iMessage sends).
    func extractPlainText() -> String {
        guard let textView else { return "" }
        let attrString = textView.attributedString()
        var result = ""
        attrString.enumerateAttributes(
            in: NSRange(location: 0, length: attrString.length),
            options: []
        ) { attrs, range, _ in
            if attrs[.attachment] is NSTextAttachment {
                // Skip image attachments for plain text
            } else {
                let sub = (attrString.string as NSString).substring(with: range)
                result += sub.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return result
    }

    /// Whether any text is selected (for formatting operations).
    var hasSelection: Bool {
        guard let textView else { return false }
        return textView.selectedRange().length > 0
    }

    // MARK: - Formatting

    /// Toggle bold on the current selection.
    func toggleBold() {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0, let storage = textView.textStorage else { return }

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
            guard let font = value as? NSFont else { return }
            let manager = NSFontManager.shared
            let newFont: NSFont
            if manager.traits(of: font).contains(.boldFontMask) {
                newFont = manager.convert(font, toNotHaveTrait: .boldFontMask)
            } else {
                newFont = manager.convert(font, toHaveTrait: .boldFontMask)
            }
            storage.addAttribute(.font, value: newFont, range: attrRange)
        }
        storage.endEditing()
    }

    /// Toggle italic on the current selection.
    func toggleItalic() {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard range.length > 0, let storage = textView.textStorage else { return }

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
            guard let font = value as? NSFont else { return }
            let manager = NSFontManager.shared
            let newFont: NSFont
            if manager.traits(of: font).contains(.italicFontMask) {
                newFont = manager.convert(font, toNotHaveTrait: .italicFontMask)
            } else {
                newFont = manager.convert(font, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: newFont, range: attrRange)
        }
        storage.endEditing()
    }

    /// Insert a hyperlink at the current selection or cursor position.
    func insertLink(url: URL, displayText: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)

        let linkAttrs: [NSAttributedString.Key: Any] = [
            .link: url,
            .font: font,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let linkStr = NSAttributedString(string: displayText, attributes: linkAttrs)

        textView.insertText(linkStr, replacementRange: range)
    }

    /// Insert an inline image at the current cursor position.
    func insertImage(data: Data) {
        guard let textView, let nsImage = NSImage(data: data) else { return }

        let containerWidth = textView.textContainer?.containerSize.width ?? 400
        let attachment = RichNoteEditor.makeImageAttachment(
            data: data, nsImage: nsImage, containerWidth: containerWidth
        )

        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        let combined = NSMutableAttributedString()
        if textView.selectedRange().location > 0 {
            combined.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        combined.append(NSAttributedString(attachment: attachment))
        combined.append(NSAttributedString(string: "\n", attributes: attrs))

        textView.insertText(combined, replacementRange: textView.selectedRange())
    }

    /// Insert a QR code generated from a URL string.
    func insertQRCode(from urlString: String) {
        guard let pngData = QRCodeGenerator.generatePNGData(from: urlString, size: 200) else {
            logger.warning("Failed to generate QR code for \(urlString)")
            return
        }
        insertImage(data: pngData)
    }

    /// Whether the cursor/selection is on an image attachment.
    var selectedImageAttachment: NSTextAttachment? {
        guard let textView, let storage = textView.textStorage else { return nil }
        let range = textView.selectedRange()
        // Check the character at or just before the cursor
        let checkIndex = range.length > 0 ? range.location : max(0, range.location - 1)
        guard checkIndex < storage.length else { return nil }
        return storage.attribute(.attachment, at: checkIndex, effectiveRange: nil) as? NSTextAttachment
    }

    /// Current scale (0–1) of the selected image relative to container width.
    var selectedImageScale: CGFloat {
        guard let textView, let attachment = selectedImageAttachment else { return 1.0 }
        let containerWidth = textView.textContainer?.containerSize.width ?? 400
        let bounds = attachment.bounds
        guard bounds.width > 0, containerWidth > 0 else { return 1.0 }
        return min(1.0, bounds.width / containerWidth)
    }

    /// Resize the selected image to a percentage of the container width.
    func resizeSelectedImage(scale: CGFloat) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let checkIndex = range.length > 0 ? range.location : max(0, range.location - 1)
        guard checkIndex < storage.length else { return }
        guard let attachment = storage.attribute(.attachment, at: checkIndex, effectiveRange: nil) as? NSTextAttachment else { return }
        guard let data = attachment.contents ?? attachment.fileWrapper?.regularFileContents,
              let nsImage = NSImage(data: data) else { return }

        let containerWidth = textView.textContainer?.containerSize.width ?? 400
        let targetWidth = containerWidth * scale
        // Scale relative to container width — allow scaling up small images (e.g., QR codes)
        let aspectRatio = nsImage.size.height / max(1, nsImage.size.width)
        let newSize = NSSize(
            width: targetWidth,
            height: targetWidth * aspectRatio
        )

        // Update bounds
        attachment.bounds = CGRect(origin: .zero, size: newSize)

        // Rebuild the attachment cell with the new size
        let displayImage = NSImage(size: newSize)
        displayImage.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: newSize),
                     from: .zero, operation: .copy, fraction: 1.0)
        displayImage.unlockFocus()
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: displayImage)

        // Force layout update
        let charRange = NSRange(location: checkIndex, length: 1)
        storage.edited(.editedAttributes, range: charRange, changeInLength: 0)
        textView.needsDisplay = true
    }

    /// Move focus into the editor.
    func focus() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }

    /// Load initial content from plain text (AI-generated draft).
    func loadText(_ text: String) {
        guard let textView else { return }
        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: attrs)
        )
    }
}

// MARK: - Custom NSTextView

/// NSTextView subclass with Cmd+B, Cmd+I, Cmd+K, and Cmd+S keyboard handling.
private class InvitationTextView: NSTextView {
    weak var editorCoordinator: RichInvitationEditor.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers {
        case "b":
            editorCoordinator?.handleBold()
            return true
        case "i":
            editorCoordinator?.handleItalic()
            return true
        case "k":
            editorCoordinator?.handleInsertLink()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        if ImagePasteUtility.pasteboardHasImageOnly() {
            super.paste(sender)
        } else {
            // Allow rich paste in the invitation editor (unlike notes which strip formatting)
            super.paste(sender)
        }
    }
}

// MARK: - NSViewRepresentable

/// Rich text editor for event invitations with bold, italic, links, and inline images.
struct RichInvitationEditor: NSViewRepresentable {

    /// Plain text content — synced on every edit for UI state.
    @Binding var plainText: String

    /// Shared handle for content extraction and formatting operations.
    var handle: RichInvitationEditorHandle

    // MARK: - Coordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichInvitationEditor
        var isUpdating = false
        var hasLoaded = false
        var lastSyncedText = ""

        init(parent: RichInvitationEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            isUpdating = true
            let text = extractPlainText(from: textView)
            lastSyncedText = text
            parent.plainText = text
            isUpdating = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            let hasImage = parent.handle.selectedImageAttachment != nil
            let scale = parent.handle.selectedImageScale
            parent.handle.onSelectionChanged?(hasImage, scale)
        }

        func handleBold() {
            parent.handle.toggleBold()
        }

        func handleItalic() {
            parent.handle.toggleItalic()
        }

        func handleInsertLink() {
            parent.handle.onInsertLink?()
        }

        func extractPlainText(from textView: NSTextView) -> String {
            let attrString = textView.attributedString()
            var result = ""
            attrString.enumerateAttributes(
                in: NSRange(location: 0, length: attrString.length),
                options: []
            ) { attrs, range, _ in
                if attrs[.attachment] is NSTextAttachment {
                    // Skip attachments
                } else {
                    let sub = (attrString.string as NSString).substring(with: range)
                    result += sub.replacingOccurrences(of: "\u{FFFC}", with: "")
                }
            }
            return result
        }
    }

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = InvitationTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .textColor
        textView.backgroundColor = .controlBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )

        textView.editorCoordinator = context.coordinator
        scrollView.documentView = textView
        handle.textView = textView

        // Load initial content
        if !plainText.isEmpty {
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            context.coordinator.isUpdating = true
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: plainText, attributes: attrs)
            )
            context.coordinator.lastSyncedText = plainText
            context.coordinator.isUpdating = false
        }
        context.coordinator.hasLoaded = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              !context.coordinator.isUpdating,
              context.coordinator.hasLoaded else { return }

        handle.textView = textView

        // Only react to external text changes (e.g., AI regeneration)
        guard plainText != context.coordinator.lastSyncedText else { return }

        if plainText.isEmpty {
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            context.coordinator.isUpdating = true
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: "", attributes: [.font: font, .foregroundColor: NSColor.textColor])
            )
            context.coordinator.lastSyncedText = plainText
            context.coordinator.isUpdating = false
        } else {
            // External text change — reload as plain text (preserving nothing)
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            context.coordinator.isUpdating = true
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: plainText, attributes: attrs)
            )
            context.coordinator.lastSyncedText = plainText
            context.coordinator.isUpdating = false
        }
    }
}
