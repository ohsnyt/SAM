//
//  ImageResizeUtility.swift
//  SAM
//
//  Reusable image processing: center-crop to square, resize, JPEG compression.
//

import AppKit
import Foundation

enum ImageResizeUtility {

    /// Process an image for contact photo use: center-crop to square, resize to
    /// maxDimension, and compress to JPEG at the given quality.
    /// - Parameters:
    ///   - data: Raw image data in any format NSImage can decode (JPEG, PNG, TIFF, HEIC, WebP).
    ///   - maxDimension: The maximum width/height of the output square (default 600).
    ///   - quality: JPEG compression quality 0…1 (default 0.85).
    /// - Returns: JPEG data, or nil if the input could not be decoded.
    static func processContactPhoto(
        from data: Data,
        maxDimension: CGFloat = 600,
        quality: Double = 0.85
    ) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        guard let bitmapRep = bestBitmapRep(for: image) else { return nil }

        let srcW = CGFloat(bitmapRep.pixelsWide)
        let srcH = CGFloat(bitmapRep.pixelsHigh)
        guard srcW > 0, srcH > 0 else { return nil }

        // Center-crop to square
        let side = min(srcW, srcH)
        let cropRect = CGRect(
            x: (srcW - side) / 2,
            y: (srcH - side) / 2,
            width: side,
            height: side
        )

        guard let croppedCG = bitmapRep.cgImage?.cropping(to: cropRect) else { return nil }

        // Resize to target dimension
        let outputSize = min(side, maxDimension)
        let outputSizeInt = Int(outputSize)

        guard let context = CGContext(
            data: nil,
            width: outputSizeInt,
            height: outputSizeInt,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(croppedCG, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))

        guard let resizedCG = context.makeImage() else { return nil }

        let outputRep = NSBitmapImageRep(cgImage: resizedCG)
        return outputRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: quality)]
        )
    }

    // MARK: - Private

    /// Extract the best bitmap representation from an NSImage, preferring the
    /// largest pixel-backed rep available.
    private static func bestBitmapRep(for image: NSImage) -> NSBitmapImageRep? {
        // Try existing bitmap reps first (avoids re-encoding)
        if let existing = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           existing.pixelsWide > 0 {
            return existing
        }
        // Fall back: render NSImage to TIFF and create a bitmap rep
        guard let tiffData = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiffData)
    }
}
