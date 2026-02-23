import Foundation
@preconcurrency import AVFoundation
import Photos

/// Re-encodes a video asset to HEVC using hardware acceleration via AVFoundation.
struct VideoCompressor {

    /// Compresses a video to HEVC and writes it to a temporary file.
    /// Progress during encoding is indeterminate (AVAssetExportSession.progress
    /// cannot be polled from a Sendable context in Swift 6; the caller shows a spinner).
    /// - Returns: URL to the compressed temporary file. Caller is responsible for cleanup.
    static func compress(
        sourceAsset: AVURLAsset,
        qualityMode: QualityMode,
        resolutionCap: ResolutionCap
    ) async throws -> URL {
        let preset = await resolvePreset(qualityMode: qualityMode, resolutionCap: resolutionCap, source: sourceAsset)

        guard AVAssetExportSession.allExportPresets().contains(preset) else {
            throw VideoCompressionError.presetUnavailable(preset)
        }

        guard let exportSession = AVAssetExportSession(asset: sourceAsset, presetName: preset) else {
            throw VideoCompressionError.exportSessionCreationFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false // preserve quality
        exportSession.metadata = await copyMetadata(from: sourceAsset)

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return outputURL
        case .failed:
            throw exportSession.error ?? VideoCompressionError.exportFailed
        case .cancelled:
            throw VideoCompressionError.cancelled
        default:
            throw VideoCompressionError.exportFailed
        }
    }

    // MARK: - Preset Resolution

    private static func resolvePreset(
        qualityMode: QualityMode,
        resolutionCap: ResolutionCap,
        source: AVURLAsset
    ) async -> String {
        // Resolution cap takes precedence when set
        if resolutionCap != .original {
            return resolutionCap.videoExportPreset
        }

        switch qualityMode {
        case .high:
            // Near-lossless: use HighestQuality preset (large files)
            return AVAssetExportPresetHEVCHighestQuality
        case .matchOriginal:
            // Use the standard (not HighestQuality) HEVC preset that matches
            // the source resolution. These apply sensible compression (~40-60%
            // savings) while maintaining good visual quality.
            return await resolutionMatchedPreset(for: source)
        case .balanced:
            return AVAssetExportPresetHEVC1920x1080
        case .compact:
            return AVAssetExportPresetHEVC1920x1080
        case .custom:
            return await resolutionMatchedPreset(for: source)
        }
    }

    /// Picks the standard HEVC preset that best matches the source video's resolution.
    /// Standard presets (without "HighestQuality") apply reasonable compression,
    /// producing files roughly 40–60% smaller than equivalent H.264 at similar quality.
    private static func resolutionMatchedPreset(for source: AVURLAsset) async -> String {
        guard let track = try? await source.loadTracks(withMediaType: .video).first,
              let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else {
            return AVAssetExportPresetHEVC1920x1080
        }
        let size = naturalSize.applying(transform)
        let longEdge = max(abs(size.width), abs(size.height))

        if longEdge > 1920 {
            return AVAssetExportPresetHEVC3840x2160
        } else {
            return AVAssetExportPresetHEVC1920x1080
        }
    }

    // MARK: - Metadata Copying

    private static func copyMetadata(from asset: AVAsset) async -> [AVMetadataItem] {
        (try? await asset.load(.metadata)) ?? []
    }
}

// MARK: - Errors

enum VideoCompressionError: LocalizedError {
    case presetUnavailable(String)
    case exportSessionCreationFailed
    case exportFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .presetUnavailable(let p):     "Export preset '\(p)' is not available on this device."
        case .exportSessionCreationFailed:  "Could not create the video export session."
        case .exportFailed:                 "Video export failed."
        case .cancelled:                    "Video export was cancelled."
        }
    }
}
