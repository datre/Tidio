import Foundation
import Photos
import SwiftUI

/// Wraps a PHAsset with derived display metadata and selection state.
/// @unchecked Sendable: @MainActor ensures mutable properties are only accessed on main thread.
@MainActor
final class AssetItem: Identifiable, ObservableObject, @unchecked Sendable {
    let asset: PHAsset
    let id: String              // PHAsset.localIdentifier

    // Derived at init
    let mediaType: PHAssetMediaType
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval  // 0 for photos
    let sourceFilename: String?
    let isCloudOnly: Bool       // true if full-res is not locally available
    let originalFormat: OriginalFormat

    @Published var thumbnail: PlatformImage?
    @Published var isSelected: Bool = false

    init(asset: PHAsset) {
        self.asset = asset
        self.id = asset.localIdentifier
        self.mediaType = asset.mediaType
        self.creationDate = asset.creationDate
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.duration = asset.duration

        // Read the filename from the first resource
        let resources = PHAssetResource.assetResources(for: asset)
        self.sourceFilename = resources.first?.originalFilename

        // An asset is cloud-only if it's not locally available
        self.isCloudOnly = !asset.isLocallyAvailable

        // Derive format from filename extension
        let ext = (resources.first?.originalFilename as NSString?)?.pathExtension.lowercased() ?? ""
        self.originalFormat = OriginalFormat(fileExtension: ext, mediaType: asset.mediaType)
    }

    var formattedResolution: String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    var formattedDuration: String? {
        guard mediaType == .video else { return nil }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    var needsCompression: Bool {
        let settings = AppSettings.shared
        switch originalFormat {
        case .heic, .heif:
            return !settings.skipAlreadyHEIC
        case .hevc:
            return !settings.skipAlreadyHEVC
        default:
            return true
        }
    }
}

// MARK: - PHAsset locality helper

private extension PHAsset {
    var isLocallyAvailable: Bool {
        let resources = PHAssetResource.assetResources(for: self)
        return resources.contains { resource in
            let isDataOnDisk = resource.value(forKey: "locallyAvailable") as? Bool ?? true
            return isDataOnDisk
        }
    }
}

// MARK: - Original Format

enum OriginalFormat {
    case jpeg
    case png
    case heic
    case heif
    case tiff
    case gif
    case mp4h264
    case movH264
    case hevc
    case other(String)

    init(fileExtension: String, mediaType: PHAssetMediaType) {
        if mediaType == .video {
            switch fileExtension {
            case "mp4": self = .mp4h264
            case "mov": self = .movH264
            case "hevc": self = .hevc
            default: self = .other(fileExtension)
            }
        } else {
            switch fileExtension {
            case "jpg", "jpeg": self = .jpeg
            case "png": self = .png
            case "heic": self = .heic
            case "heif": self = .heif
            case "tiff", "tif": self = .tiff
            case "gif": self = .gif
            default: self = .other(fileExtension)
            }
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .heif: "HEIF"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .mp4h264: "MP4 (H.264)"
        case .movH264: "MOV (H.264)"
        case .hevc: "HEVC"
        case .other(let ext): ext.uppercased()
        }
    }

    var isVideo: Bool {
        switch self {
        case .mp4h264, .movH264, .hevc: true
        default: false
        }
    }

    var compressionTarget: CompressionTarget {
        switch self {
        case .jpeg, .png, .tiff, .gif: .toHEIC
        case .heic, .heif: .alreadyHEIC
        case .mp4h264, .movH264: .toHEVC
        case .hevc: .alreadyHEVC
        case .other: .unsupported
        }
    }
}

enum CompressionTarget {
    case toHEIC
    case toHEVC
    case alreadyHEIC
    case alreadyHEVC
    case unsupported
}
