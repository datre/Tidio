import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// Compresses a single image asset to HEIC, preserving all metadata.
struct ImageCompressor {

    /// Compresses raw image data to HEIC.
    /// - Parameters:
    ///   - sourceData: Original image file data (JPEG, PNG, TIFF, etc.)
    ///   - qualityMode: Target quality mode
    ///   - resolutionCap: Optional maximum long-edge
    /// - Returns: HEIC-encoded Data with all source metadata preserved.
    static func compress(
        sourceData: Data,
        qualityMode: QualityMode,
        customQuality: Double = 0.75,
        resolutionCap: ResolutionCap
    ) throws -> Data {
        guard let source = CGImageSource.create(data: sourceData) else {
            throw ImageCompressionError.invalidSource
        }

        // Read source quality for Match Original — estimate from bits-per-pixel
        let sourceBPP = estimateBitsPerPixel(source: source, dataSize: sourceData.count)
        let heicQuality = qualityMode.heicQuality(sourceBitsPerPixel: sourceBPP, customQuality: customQuality)

        // Read all source properties (EXIF, TIFF, GPS, IPTC, etc.)
        var sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        // Decode at full resolution with orientation transform applied.
        // CGImageSourceCreateThumbnailAtIndex + kCGImageSourceCreateThumbnailWithTransform
        // actually rotates the pixels to upright, unlike CGImageSourceCreateImageAtIndex
        // which returns raw storage-order pixels. After this, orientation tag = 1 is correct.
        let maxDim = max(
            sourceProps[kCGImagePropertyPixelWidth] as? Int ?? 99999,
            sourceProps[kCGImagePropertyPixelHeight] as? Int ?? 99999
        )
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceShouldCache: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            throw ImageCompressionError.decodeFailed
        }
        // Pixels are now upright — set orientation to normal everywhere
        sourceProps[kCGImagePropertyOrientation] = 1

        if var tiffDict = sourceProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiffDict[kCGImagePropertyTIFFOrientation] = 1
            sourceProps[kCGImagePropertyTIFFDictionary] = tiffDict
        }

        // Apply resolution cap if needed
        let finalImage = try applyResolutionCap(to: cgImage, cap: resolutionCap)

        // Encode as HEIC
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData, UTType.heic.identifier as CFString, 1, nil
        ) else {
            throw ImageCompressionError.destinationCreationFailed
        }

        // Merge source properties (preserves all metadata) with our quality setting
        var destProperties = sourceProps
        destProperties[kCGImageDestinationLossyCompressionQuality] = heicQuality

        CGImageDestinationAddImage(destination, finalImage, destProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageCompressionError.encodeFailed
        }

        return outputData as Data
    }

    // MARK: - Resolution Cap

    private static func applyResolutionCap(to image: CGImage, cap: ResolutionCap) throws -> CGImage {
        guard let maxEdge = cap.maxLongEdge else { return image }
        let width = image.width
        let height = image.height
        let longEdge = max(width, height)
        guard longEdge > maxEdge else { return image }

        let scale = Double(maxEdge) / Double(longEdge)
        let newWidth = Int(Double(width) * scale)
        let newHeight = Int(Double(height) * scale)

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: image.bitmapInfo.rawValue
        ) else { throw ImageCompressionError.resizeFailed }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resized = context.makeImage() else {
            throw ImageCompressionError.resizeFailed
        }
        return resized
    }

    // MARK: - Source Quality Estimation

    /// Estimates the source image's bits-per-pixel from file size and pixel dimensions.
    /// This is a reliable proxy for quality level that works with any image format
    /// (JPEG, PNG, HEIC, etc.), unlike the JFIF quality tag which rarely exists.
    private static func estimateBitsPerPixel(source: CGImageSource, dataSize: Int) -> Double? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let totalPixels = Double(width * height)
        let totalBits = Double(dataSize) * 8.0
        return totalBits / totalPixels
    }
}

// MARK: - CGImageSource helper

private extension CGImageSource {
    static func create(data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, nil)
    }
}

// MARK: - Errors

enum ImageCompressionError: LocalizedError {
    case invalidSource
    case decodeFailed
    case destinationCreationFailed
    case encodeFailed
    case resizeFailed

    var errorDescription: String? {
        switch self {
        case .invalidSource:            "Could not read source image data."
        case .decodeFailed:             "Could not decode the source image."
        case .destinationCreationFailed: "Could not create HEIC encoder."
        case .encodeFailed:             "HEIC encoding failed."
        case .resizeFailed:             "Could not resize the image."
        }
    }
}
