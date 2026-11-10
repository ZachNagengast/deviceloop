//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads PNG sizes and writes point-sized JPEGs with ImageIO.
enum ScreenshotImage {
    static func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw DeviceLoopError(.internalError, "Could not read the screenshot at \(url.path).")
        }
        return (width, height)
    }

    /// JPEG of the image at `url` with its longest side scaled to `maxPixelSize`.
    static func jpeg(from url: URL, maxPixelSize: Int, quality: Double = 0.8) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        let encoded = NSMutableData()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw DeviceLoopError(.internalError, "Could not scale the screenshot at \(url.path).")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DeviceLoopError(.internalError, "Could not encode the screenshot at \(url.path) as JPEG.")
        }
        return encoded as Data
    }

    /// Pixels per point when `info displays` is unavailable: 2 for iPads and for iPhones up to 828 px wide
    /// (SE, XR, 11), 3 otherwise.
    static func guessedScale(pixelWidth: Int, pixelHeight: Int, deviceType: String) -> Double {
        if deviceType.lowercased() == "ipad" { return 2 }
        return min(pixelWidth, pixelHeight) <= 828 ? 2 : 3
    }
}
