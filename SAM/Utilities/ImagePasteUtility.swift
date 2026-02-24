//
//  ImagePasteUtility.swift
//  SAM
//
//  Shared utility for reading images from the macOS clipboard.
//

import AppKit
import Foundation
import SwiftUI

enum ImagePasteUtility {

    /// Returns true if the pasteboard contains image data without accompanying text.
    /// This distinguishes a copied image (screenshot, Preview copy) from copied rich
    /// text that happens to include a TIFF representation.
    static func pasteboardHasImageOnly() -> Bool {
        let pb = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff,
            NSPasteboard.PasteboardType(rawValue: "public.jpeg")]
        guard pb.availableType(from: imageTypes) != nil else { return false }
        // If there's plain text on the pasteboard, the user likely copied text
        return pb.string(forType: .string) == nil
    }

    /// Returns the cursor position (character offset) from the currently focused NSTextView,
    /// or `nil` if the first responder is not a text view.
    static func currentTextViewCursorPosition() -> Int? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        return textView.selectedRange().location
    }

    /// Read all images from the system pasteboard.
    /// Returns an array of (data, mimeType) tuples, or empty if no images found.
    static func readImagesFromPasteboard() -> [(Data, String)] {
        let pasteboard = NSPasteboard.general
        var results: [(Data, String)] = []

        // Try reading NSImage representations from the pasteboard
        guard let items = pasteboard.pasteboardItems else { return results }

        for item in items {
            // Try PNG first (screenshots, most apps)
            if let pngData = item.data(forType: .png) {
                results.append((pngData, "image/png"))
                continue
            }
            // Try TIFF (macOS native image type, common for copy from Preview/Photos)
            if let tiffData = item.data(forType: .tiff) {
                // Convert TIFF to PNG for consistent storage
                if let nsImage = NSImage(data: tiffData),
                   let pngData = nsImage.pngData() {
                    results.append((pngData, "image/png"))
                } else {
                    results.append((tiffData, "image/tiff"))
                }
                continue
            }
            // Try JPEG
            let jpegType = NSPasteboard.PasteboardType(rawValue: "public.jpeg")
            if let jpegData = item.data(forType: jpegType) {
                results.append((jpegData, "image/jpeg"))
                continue
            }
            // Try file URLs that point to images
            if let urlString = item.string(forType: .fileURL),
               let url = URL(string: urlString),
               let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "gif", "tiff", "tif"].contains(ext) else { continue }
                let mime: String
                switch ext {
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "tiff", "tif": mime = "image/tiff"
                default: mime = "image/png"
                }
                results.append((data, mime))
            }
        }

        return results
    }
}

// MARK: - Image Paste ViewModifier

/// Installs an NSEvent local monitor to intercept Cmd+V when the pasteboard
/// contains image data (without text). This works even when a TextEditor has
/// focus, because the monitor fires before the responder chain.
///
/// The callback receives the cursor position (character offset) from the
/// active NSTextView at the moment of paste, or `nil` if unavailable.
private struct ImagePasteMonitor: ViewModifier {
    let onImagePaste: (Int?) -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.modifierFlags.contains(.command),
                       event.charactersIgnoringModifiers == "v",
                       ImagePasteUtility.pasteboardHasImageOnly() {
                        // Capture cursor position synchronously while NSTextView is still first responder
                        let cursorPosition = ImagePasteUtility.currentTextViewCursorPosition()
                        DispatchQueue.main.async {
                            onImagePaste(cursorPosition)
                        }
                        return nil  // consume the event
                    }
                    return event  // pass through
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
            }
    }
}

extension View {
    /// Intercepts Cmd+V to paste images from the clipboard.
    /// Only fires when the pasteboard has image data without accompanying text,
    /// so normal text paste in TextEditor is unaffected.
    /// The callback receives the cursor position from the active text view.
    func onImagePaste(perform action: @escaping (Int?) -> Void) -> some View {
        modifier(ImagePasteMonitor(onImagePaste: action))
    }
}

// MARK: - NSImage PNG conversion

extension NSImage {
    /// Convert NSImage to PNG data
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }
}
