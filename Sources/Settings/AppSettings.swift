import Foundation
import SwiftUI

/// All user-configurable settings, persisted via AppStorage / UserDefaults.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Quality

    @AppStorage("photoQualityMode") var photoQualityMode: QualityMode = .matchOriginal
    /// 0.0–1.0, used only when photoQualityMode == .custom
    @AppStorage("photoCustomQuality") var photoCustomQuality: Double = 0.75

    @AppStorage("videoQualityMode") var videoQualityMode: QualityMode = .matchOriginal
    /// Target Mbps, used only when videoQualityMode == .custom
    @AppStorage("videoCustomBitrateMbps") var videoCustomBitrateMbps: Double = 8.0

    // MARK: - Resolution

    @AppStorage("resolutionCap") var resolutionCap: ResolutionCap = .original

    // MARK: - Skip rules

    @AppStorage("skipAlreadyHEIC") var skipAlreadyHEIC: Bool = true
    @AppStorage("skipAlreadyHEVC") var skipAlreadyHEVC: Bool = true

    // MARK: - Album names

    @AppStorage("compressedAlbumName") var compressedAlbumName: String = "Compressed by Tidio"
    @AppStorage("originalsAlbumName") var originalsAlbumName: String = "Originals — Tidio"
    @AppStorage("duplicatesAlbumName") var duplicatesAlbumName: String = "Duplicates — Tidio"
    @AppStorage("failedAlbumName") var failedAlbumName: String = "Failed — Tidio"

    // MARK: - Singleton

    static let shared = AppSettings()
    private init() {}
}

// MARK: - Quality Mode

enum QualityMode: String, CaseIterable, Identifiable {
    case matchOriginal = "matchOriginal"
    case high          = "high"
    case balanced      = "balanced"
    case compact       = "compact"
    case custom        = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .matchOriginal: "Match Original"
        case .high:          "High"
        case .balanced:      "Balanced"
        case .compact:       "Compact"
        case .custom:        "Custom"
        }
    }

    var description: String {
        switch self {
        case .matchOriginal: "Same perceived quality, smaller file via better codec"
        case .high:          "Visually lossless (~90% quality)"
        case .balanced:      "Great quality with meaningful savings (~75%)"
        case .compact:       "Maximum savings, slight quality trade-off (~60%)"
        case .custom:        "Set your own quality value"
        }
    }

    /// Resolved HEIC quality factor (0.0–1.0).
    /// - Parameters:
    ///   - sourceBitsPerPixel: Estimated bits-per-pixel of the source image, used for .matchOriginal
    ///   - customQuality: The user-set custom quality (passed from AppSettings to avoid actor boundary crossing)
    func heicQuality(sourceBitsPerPixel: Double? = nil, customQuality: Double = 0.75) -> Double {
        switch self {
        case .matchOriginal:
            guard let bpp = sourceBitsPerPixel else { return 0.76 }
            return Self.bppToHEICQuality(bpp)
        case .high:      return 0.82
        case .balanced:  return 0.65
        case .compact:   return 0.50
        case .custom:    return customQuality
        }
    }

    /// Maps source bits-per-pixel to an HEIC quality factor that produces
    /// similar perceived visual quality at a smaller file size.
    ///
    /// Reference BPP ranges for JPEG:
    /// - Ultra-high quality (q95+): ~6–10+ bpp
    /// - High quality (q85–95):     ~3–6 bpp
    /// - Medium quality (q70–85):   ~1.5–3 bpp
    /// - Low quality (q50–70):      ~0.5–1.5 bpp
    ///
    /// HEIC achieves equivalent visual quality at roughly 40–60% of the file size,
    /// so we map these ranges to lower HEIC quality factors.
    private static func bppToHEICQuality(_ bpp: Double) -> Double {
        switch bpp {
        case 5.0...:       return 0.82   // Very high quality source → HEIC high
        case 3.0..<5.0:    return 0.76   // High quality source
        case 1.5..<3.0:    return 0.68   // Medium quality source
        case 0.8..<1.5:    return 0.58   // Lower quality source
        default:           return 0.50   // Already heavily compressed
        }
    }
}

// MARK: - Resolution Cap

enum ResolutionCap: String, CaseIterable, Identifiable {
    case original = "original"
    case uhd4k    = "4k"
    case fullHD   = "1080p"
    case hd720    = "720p"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "Original Resolution"
        case .uhd4k:    "Cap at 4K (3840px)"
        case .fullHD:   "Cap at 1080p (1920px)"
        case .hd720:    "Cap at 720p (1280px)"
        }
    }

    /// Maximum long-edge in pixels, or nil for no cap.
    var maxLongEdge: Int? {
        switch self {
        case .original: nil
        case .uhd4k:    3840
        case .fullHD:   1920
        case .hd720:    1280
        }
    }

    /// AVFoundation export preset name for videos at this cap.
    /// Note: Apple only provides HEVC presets down to 1080p; 720p cap uses 1080p HEVC
    /// (AVFoundation respects source resolution if already smaller).
    var videoExportPreset: String {
        switch self {
        case .original, .uhd4k: AVAssetExportPresetHEVCHighestQuality
        case .fullHD, .hd720:   AVAssetExportPresetHEVC1920x1080
        }
    }
}

import AVFoundation
