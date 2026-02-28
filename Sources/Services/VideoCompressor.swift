import Foundation
@preconcurrency import AVFoundation
import Photos
import os.log

private let log = Logger(subsystem: "com.tidio", category: "VideoCompressor")

/// Re-encodes a video asset to HEVC using hardware acceleration via AVFoundation.
/// Falls back to H.264 HighestQuality for old/incompatible source videos.
struct VideoCompressor {

    /// Compresses a video to HEVC (preferred) or H.264 (fallback).
    /// - Returns: URL to the compressed temporary file. Caller is responsible for cleanup.
    static func compress(
        sourceAsset: AVAsset,
        qualityMode: QualityMode,
        resolutionCap: ResolutionCap
    ) async throws -> URL {
        // 1. Try the preferred HEVC preset
        let hevcPreset = await resolveHEVCPreset(qualityMode: qualityMode, resolutionCap: resolutionCap, source: sourceAsset)
        log.info("  VideoCompressor: trying preset=\(hevcPreset) assetType=\(String(describing: type(of: sourceAsset)))")

        if let url = await tryExport(sourceAsset: sourceAsset, preset: hevcPreset) {
            return url
        }

        // 2. HEVC failed — try H.264 HighestQuality as fallback
        let h264Preset = AVAssetExportPresetHighestQuality
        log.info("  VideoCompressor: HEVC failed, falling back to H.264 preset=\(h264Preset)")

        if let url = await tryExport(sourceAsset: sourceAsset, preset: h264Preset) {
            return url
        }

        // 3. H.264 also failed — try passthrough (no re-encoding, just repackage)
        let passthroughPreset = AVAssetExportPresetPassthrough
        log.info("  VideoCompressor: H.264 failed, falling back to passthrough")

        if let url = await tryExport(sourceAsset: sourceAsset, preset: passthroughPreset) {
            return url
        }

        // All presets failed
        log.error("  VideoCompressor: all presets failed")
        let allCompatible = await AVAssetExportSession.exportPresets(compatibleWith: sourceAsset)
        log.error("  VideoCompressor: compatible presets were: \(allCompatible)")
        throw VideoCompressionError.exportFailed
    }

    /// Attempts to export with the given preset. Returns the output URL on success, nil on failure.
    private static func tryExport(sourceAsset: AVAsset, preset: String) async -> URL? {
        // Check compatibility first
        let compatible = await AVAssetExportSession.compatibility(
            ofExportPreset: preset,
            with: sourceAsset,
            outputFileType: .mov
        )
        guard compatible else {
            log.info("  VideoCompressor: preset '\(preset)' not compatible, skipping")
            return nil
        }

        guard let exportSession = AVAssetExportSession(asset: sourceAsset, presetName: preset) else {
            log.error("  VideoCompressor: could not create export session for '\(preset)'")
            return nil
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false
        exportSession.metadata = await copyMetadata(from: sourceAsset)

        log.info("  VideoCompressor: starting export with '\(preset)' to \(outputURL.lastPathComponent)...")
        await exportSession.export()
        log.info("  VideoCompressor: export status=\(exportSession.status.rawValue)")

        switch exportSession.status {
        case .completed:
            let outSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            log.info("  VideoCompressor: ✓ export complete with '\(preset)', output=\(outSize) bytes")
            return outputURL
        case .failed:
            let errDesc = exportSession.error.map { String(describing: $0) } ?? "unknown"
            log.warning("  VideoCompressor: export FAILED with '\(preset)' — \(errDesc)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        case .cancelled:
            log.warning("  VideoCompressor: export cancelled")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        default:
            log.warning("  VideoCompressor: unexpected status \(exportSession.status.rawValue)")
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    // MARK: - Preset Resolution

    private static func resolveHEVCPreset(
        qualityMode: QualityMode,
        resolutionCap: ResolutionCap,
        source: AVAsset
    ) async -> String {
        // Resolution cap takes precedence when set
        if resolutionCap != .original {
            return resolutionCap.videoExportPreset
        }

        switch qualityMode {
        case .high:
            return AVAssetExportPresetHEVCHighestQuality
        case .matchOriginal:
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
    private static func resolutionMatchedPreset(for source: AVAsset) async -> String {
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

    // MARK: - Size Estimation

    /// Estimates the original file size for an AVAsset.
    /// For AVURLAsset, reads from the file system. For compositions, estimates from tracks.
    static func estimateOriginalSize(for asset: AVAsset) async -> Int64 {
        if let urlAsset = asset as? AVURLAsset {
            return (try? FileManager.default.attributesOfItem(atPath: urlAsset.url.path)[.size] as? Int64) ?? 0
        }
        guard let tracks = try? await asset.load(.tracks) else { return 0 }
        var total: Int64 = 0
        for track in tracks {
            if let size = try? await track.load(.totalSampleDataLength) {
                total += size
            }
        }
        return total
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
