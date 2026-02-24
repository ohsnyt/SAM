//
//  RichNoteEditor.swift
//  SAM
//
//  NSViewRepresentable wrapping NSTextView for inline text + image editing.
//  Supports native Cmd+V image paste with images displayed inline at cursor.
//

import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RichNoteEditor")

// MARK: - Handle

/// Shared handle allowing parent views to extract content and insert images.
@MainActor
final class RichNoteEditorHandle {

    weak var textView: NSTextView?

    /// Extract plain text and embedded images from the editor.
    /// Returns (plainText, [(imageData, mimeType, textInsertionPoint)]).
    func extractContent() -> (String, [(Data, String, Int)]) {
        guard let textView else { return ("", []) }
        let attrString = textView.attributedString()
        var plainText = ""
        var images: [(Data, String, Int)] = []

        attrString.enumerateAttributes(
            in: NSRange(location: 0, length: attrString.length),
            options: []
        ) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let data = Self.imageDataFromAttachment(attachment) {
                    images.append((data, Self.mimeTypeFromAttachment(attachment), plainText.count))
                }
            } else {
                let substring = (attrString.string as NSString).substring(with: range)
                plainText += substring.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }

        return (plainText, images)
    }

    /// Insert an image inline at the current cursor position.
    func insertImage(data: Data, mimeType: String) {
        guard let textView else { return }
        guard let nsImage = NSImage(data: data) else { return }

        let containerWidth = textView.textContainer?.containerSize.width ?? 400
        let attachment = RichNoteEditor.makeImageAttachment(
            data: data, nsImage: nsImage, containerWidth: containerWidth
        )

        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        let combined = NSMutableAttributedString()
        // Leading newline if not at start of document
        if textView.selectedRange().location > 0 {
            combined.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        combined.append(NSAttributedString(attachment: attachment))
        combined.append(NSAttributedString(string: "\n", attributes: attrs))

        textView.insertText(combined, replacementRange: textView.selectedRange())
    }

    /// Clear all content (text + images).
    func clear() {
        guard let textView else { return }
        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: "", attributes: [.font: font, .foregroundColor: NSColor.textColor])
        )
    }

    // MARK: - Helpers

    static func imageDataFromAttachment(_ attachment: NSTextAttachment) -> Data? {
        if let data = attachment.contents { return data }
        if let fw = attachment.fileWrapper, let data = fw.regularFileContents { return data }
        if let image = attachment.image { return image.pngData() }
        return nil
    }

    static func mimeTypeFromAttachment(_ attachment: NSTextAttachment) -> String {
        if let uti = attachment.fileType {
            if uti.contains("jpeg") || uti.contains("jpg") { return "image/jpeg" }
            if uti.contains("gif") { return "image/gif" }
            if uti.contains("tiff") { return "image/tiff" }
        }
        return "image/png"
    }
}

// MARK: - Custom NSTextView

/// NSTextView subclass that strips formatting from text paste while allowing image paste,
/// and supports Cmd+S (save) and Escape (cancel) keyboard shortcuts.
private class NoteTextView: NSTextView {
    weak var editorCoordinator: RichNoteEditor.Coordinator?

    override func cancelOperation(_ sender: Any?) {
        editorCoordinator?.handleCancel()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers {
        case "s":
            // Cmd+S: explicit save via coordinator callback
            editorCoordinator?.handleSave()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        if ImagePasteUtility.pasteboardHasImageOnly() {
            // Image-only paste: use default behavior (inserts inline attachment)
            super.paste(sender)
        } else {
            // Text paste: strip formatting
            pasteAsPlainText(sender)
        }
    }
}

// MARK: - NSViewRepresentable

/// Rich text editor that displays images inline within text.
/// Uses NSTextView with `importsGraphics` for native Cmd+V image paste.
struct RichNoteEditor: NSViewRepresentable {

    /// Plain text content — synced on every edit for UI state (e.g., enabling Save button).
    @Binding var plainText: String

    /// Existing images to load when editing a saved note.
    var existingImages: [(Data, String, Int)]

    /// Shared handle for content extraction and image insertion.
    var handle: RichNoteEditorHandle

    /// Called when the user explicitly saves (Cmd+S).
    var onSave: (() -> Void)? = nil

    /// Called when the user presses Escape.
    var onCancel: (() -> Void)? = nil

    // MARK: - Coordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichNoteEditor
        var isUpdating = false
        var hasLoaded = false
        /// Tracks the last plainText value pushed by this coordinator,
        /// so updateNSView can distinguish external changes from our own syncs.
        var lastSyncedText = ""

        init(parent: RichNoteEditor) {
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

        func handleSave() {
            parent.onSave?()
        }

        func handleCancel() {
            parent.onCancel?()
        }

        func extractPlainText(from textView: NSTextView) -> String {
            let attrString = textView.attributedString()
            var result = ""
            attrString.enumerateAttributes(
                in: NSRange(location: 0, length: attrString.length),
                options: []
            ) { attrs, range, _ in
                if attrs[.attachment] is NSTextAttachment {
                    // skip image attachments
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

        let textView = NoteTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .textColor
        textView.backgroundColor = .controlBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
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
        let containerWidth = max(scrollView.frame.width, 300)
        let attrStr = buildAttributedString(
            text: plainText,
            images: existingImages,
            font: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize),
            containerWidth: containerWidth
        )
        context.coordinator.isUpdating = true
        textView.textStorage?.setAttributedString(attrStr)
        context.coordinator.lastSyncedText = plainText
        context.coordinator.isUpdating = false
        context.coordinator.hasLoaded = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              !context.coordinator.isUpdating,
              context.coordinator.hasLoaded else { return }

        handle.textView = textView

        // Only react if plainText was changed externally (not by our own textDidChange).
        // This prevents the newlines around images from triggering spurious rebuilds.
        guard plainText != context.coordinator.lastSyncedText else { return }

        if plainText.isEmpty {
            // Full reset (after save)
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            context.coordinator.isUpdating = true
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: "", attributes: [.font: font, .foregroundColor: NSColor.textColor])
            )
            context.coordinator.lastSyncedText = plainText
            context.coordinator.isUpdating = false
        } else {
            // External text change (dictation, polish) — rebuild preserving images
            let (_, currentImages) = handle.extractContent()
            let containerWidth = max(scrollView.frame.width, 300)
            let attrStr = buildAttributedString(
                text: plainText,
                images: currentImages,
                font: textView.font ?? .systemFont(ofSize: NSFont.systemFontSize),
                containerWidth: containerWidth
            )
            context.coordinator.isUpdating = true
            textView.textStorage?.setAttributedString(attrStr)
            context.coordinator.lastSyncedText = plainText
            context.coordinator.isUpdating = false
        }
    }

    // MARK: - Attributed String Builder

    func buildAttributedString(
        text: String,
        images: [(Data, String, Int)],
        font: NSFont,
        containerWidth: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let sorted = images.sorted(by: { $0.2 < $1.2 })
        var lastOffset = 0
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]

        for (data, _, position) in sorted {
            let insertAt = min(position, text.count)

            // Text before this image
            if insertAt > lastOffset {
                let startIdx = text.index(text.startIndex, offsetBy: lastOffset)
                let endIdx = text.index(text.startIndex, offsetBy: insertAt)
                result.append(NSAttributedString(
                    string: String(text[startIdx..<endIdx]),
                    attributes: textAttrs
                ))
            }

            // Image attachment
            if let nsImage = NSImage(data: data) {
                let attachment = Self.makeImageAttachment(
                    data: data, nsImage: nsImage, containerWidth: containerWidth
                )

                // Leading newline if not at start
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: textAttrs))
                }
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "\n", attributes: textAttrs))
            }

            lastOffset = insertAt
        }

        // Remaining text after last image
        if lastOffset < text.count {
            let startIdx = text.index(text.startIndex, offsetBy: lastOffset)
            result.append(NSAttributedString(
                string: String(text[startIdx...]),
                attributes: textAttrs
            ))
        }

        // Ensure we always have font attributes even if empty
        if result.length == 0 {
            result.append(NSAttributedString(string: "", attributes: textAttrs))
        }

        return result
    }

    // MARK: - Image Attachment Factory

    /// Create an NSTextAttachment with proper macOS attachmentCell for rendering.
    static func makeImageAttachment(data: Data, nsImage: NSImage, containerWidth: CGFloat) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.contents = data
        attachment.fileType = "public.png"

        let maxWidth = max(containerWidth - 20, 100)
        let scale = min(1.0, maxWidth / nsImage.size.width)
        let displaySize = NSSize(
            width: nsImage.size.width * scale,
            height: nsImage.size.height * scale
        )

        // Set bounds for TextKit 2 layout
        attachment.bounds = CGRect(origin: .zero, size: displaySize)

        // macOS requires an explicit attachmentCell for NSTextView (TextKit 1) rendering.
        // Without this, images render as empty placeholders.
        let displayImage = NSImage(size: displaySize)
        displayImage.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: displaySize),
                     from: .zero, operation: .copy, fraction: 1.0)
        displayImage.unlockFocus()
        let cell = NSTextAttachmentCell(imageCell: displayImage)
        attachment.attachmentCell = cell

        return attachment
    }
}
