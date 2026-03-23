//
//  QRCodeGenerator.swift
//  SAM
//
//  Created on March 23, 2026.
//  Generates QR code images from strings using Core Image.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum QRCodeGenerator {

    /// Generate a QR code NSImage from a string (URL, text, etc.).
    /// - Parameters:
    ///   - string: The content to encode in the QR code.
    ///   - size: The desired output image size in points (width and height).
    /// - Returns: An NSImage of the QR code, or nil if generation fails.
    static func generate(from string: String, size: CGFloat = 200) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale the tiny CIImage up to the requested size
        let scaleX = size / ciImage.extent.width
        let scaleY = size / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    /// Generate QR code image data (PNG) suitable for embedding in rich text or email.
    static func generatePNGData(from string: String, size: CGFloat = 200) -> Data? {
        guard let image = generate(from: string, size: size) else { return nil }
        return image.pngData()
    }
}

// NSImage.pngData() is defined in ImagePasteUtility.swift
