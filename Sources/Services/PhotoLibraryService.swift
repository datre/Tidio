import Foundation
import Photos
import AppKit
import os.log

private let log = Logger(subsystem: "com.tidio", category: "PhotoLibraryService")

/// Wraps all PhotoKit interactions: authorization, fetching assets/albums,
/// thumbnail loading, and album management.
actor PhotoLibraryService {

    static let shared = PhotoLibraryService()
    private init() {}

    // MARK: - Authorization

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - Fetch Albums

    func fetchAllAlbums() -> [AlbumItem] {
        var albums: [AlbumItem] = []

        // User albums
        let userAlbumResult = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        userAlbumResult.enumerateObjects { collection, _, _ in
            albums.append(AlbumItem(collection: collection))
        }

        // Smart albums (filtered to useful ones)
        let smartSubtypes: [PHAssetCollectionSubtype] = [
            .smartAlbumFavorites,
            .smartAlbumRecentlyAdded,
            .smartAlbumVideos,
            .smartAlbumSlomoVideos,
            .smartAlbumTimelapses,
            .smartAlbumBursts,
            .smartAlbumPanoramas,
            .smartAlbumScreenshots,
            .smartAlbumSelfPortraits,
            .smartAlbumLivePhotos,
        ]

        for subtype in smartSubtypes {
            let result = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            result.enumerateObjects { collection, _, _ in
                albums.append(AlbumItem(collection: collection))
            }
        }

        return albums
    }

    // MARK: - Fetch Assets in Album

    func fetchAssets(in collection: PHAssetCollection) -> [AssetItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAllBurstAssets = true
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var items: [AssetItem] = []
        result.enumerateObjects { asset, _, _ in
            items.append(AssetItem(asset: asset))
        }
        return items
    }

    func fetchAllAssets() -> [AssetItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAllBurstAssets = true
        let result = PHAsset.fetchAssets(with: options)
        var items: [AssetItem] = []
        result.enumerateObjects { asset, _, _ in
            items.append(AssetItem(asset: asset))
        }
        return items
    }

    // MARK: - Thumbnail Loading

    /// Loads a square thumbnail for display in the grid.
    func loadThumbnail(for asset: PHAsset, size: CGSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            options.deliveryMode = .opportunistic

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                // .opportunistic calls this handler twice: first with a degraded
                // low-res placeholder, then with the final image. Only resume on
                // the final delivery to avoid resuming the continuation more than once.
                let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                if isDegraded { return }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Full Resolution Data

    /// Requests the full-resolution data for an image asset.
    /// Downloads from iCloud if necessary (networkAccessAllowed = true).
    /// Falls back to PHAssetResourceManager for burst photos or other cases
    /// where requestImageDataAndOrientation fails.
    func requestImageData(for asset: PHAsset) async throws -> (Data, String?) {
        do {
            return try await requestImageDataViaManager(for: asset)
        } catch {
            // Fallback: use PHAssetResourceManager to read the raw resource data directly.
            // This handles burst photo members and other edge cases where the
            // standard PHImageManager API fails.
            return try await requestImageDataViaResource(for: asset)
        }
    }

    private func requestImageDataViaManager(for asset: PHAsset) async throws -> (Data, String?) {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.version = .current
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, uti, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: LibraryError.dataUnavailable)
                    return
                }
                continuation.resume(returning: (data, uti))
            }
        }
    }

    /// Fallback: reads raw image resource data via PHAssetResourceManager.
    private func requestImageDataViaResource(for asset: PHAsset) async throws -> (Data, String?) {
        let resources = PHAssetResource.assetResources(for: asset)
        // Look for the full-size photo, then fall back to any photo resource
        guard let photoResource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
        else {
            throw LibraryError.dataUnavailable
        }

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(
                for: photoResource,
                options: options,
                dataReceivedHandler: { chunk in
                    buffer.append(chunk)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: buffer)
                    }
                }
            )
        }
        return (data, photoResource.uniformTypeIdentifier)
    }

    /// Requests the full-resolution AVAsset for a video.
    /// Downloads from iCloud if necessary.
    /// Returns AVURLAsset for regular videos, AVComposition for slo-mo/time-lapse.
    func requestAVAsset(for asset: PHAsset) async throws -> UncheckedSendableBox<AVAsset> {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(
                forVideo: asset, options: options
            ) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let avAsset else {
                    continuation.resume(throwing: LibraryError.dataUnavailable)
                    return
                }
                continuation.resume(returning: UncheckedSendableBox(avAsset))
            }
        }
    }

    // MARK: - Album Management

    /// Finds an existing album by title, or creates it.
    func findOrCreateAlbum(named title: String) async throws -> PHAssetCollection {
        // Check if it already exists
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title == %@", title)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        if let found = existing.firstObject { return found }

        // Create it
        let box = PlaceholderBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            box.placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let id = box.placeholder?.localIdentifier,
              let created = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil
              ).firstObject
        else { throw LibraryError.albumCreationFailed }
        return created
    }

    /// Adds assets to an album (does not move — adds a reference).
    func addAssets(_ assets: [PHAsset], to collection: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            request.addAssets(assets as NSFastEnumeration)
        }
    }

    // MARK: - Live Photo Resource

    /// Downloads the paired video resource data for a Live Photo.
    /// Checks for both `.pairedVideo` (modern) and `.fullSizePairedVideo` (older Live Photos).
    func requestPairedVideoData(for asset: PHAsset) async throws -> Data {
        let resources = PHAssetResource.assetResources(for: asset)
        let allTypes = resources.map { "type=\($0.type.rawValue) file=\($0.originalFilename)" }
        log.info("  requestPairedVideoData: asset=\(asset.localIdentifier)")
        log.info("  resources: \(allTypes)")

        // Prefer .pairedVideo (standard), fall back to .fullSizePairedVideo (older Live Photos)
        guard let pairedVideo = resources.first(where: { $0.type == .pairedVideo })
                ?? resources.first(where: { $0.type == .fullSizePairedVideo })
        else {
            log.error("  requestPairedVideoData: NO paired video resource found! Available types: \(resources.map { $0.type.rawValue })")
            throw LibraryError.dataUnavailable
        }
        log.info("  requestPairedVideoData: using resource type=\(pairedVideo.type.rawValue) file=\(pairedVideo.originalFilename)")

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(
                for: pairedVideo,
                options: options,
                dataReceivedHandler: { chunk in
                    buffer.append(chunk)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: buffer)
                    }
                }
            )
        }
    }

    /// Saves a new Live Photo asset (still HEIC + paired video). Returns the new PHAsset.
    ///
    /// Both resources are written to temp files first — Photos validates the content
    /// identifier link between still and video, which works more reliably from files.
    func saveLivePhoto(
        imageData: Data,
        pairedVideoData: Data,
        creationDate: Date?,
        location: CLLocation?,
        originalFilename: String? = nil
    ) async throws -> PHAsset {
        log.info("  saveLivePhoto: still=\(imageData.count) bytes, video=\(pairedVideoData.count) bytes, filename=\(originalFilename ?? "nil")")

        // Write both resources to temp files — PHAssetCreationRequest handles
        // Live Photo content identifier validation more reliably from file URLs.
        let tempDir = FileManager.default.temporaryDirectory
        let imageURL = tempDir.appendingPathComponent(UUID().uuidString + ".heic")
        let videoURL = tempDir.appendingPathComponent(UUID().uuidString + ".mov")
        try imageData.write(to: imageURL)
        try pairedVideoData.write(to: videoURL)

        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: videoURL)
        }

        let box = PlaceholderBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            // Still image resource
            let imageOpts = PHAssetResourceCreationOptions()
            imageOpts.shouldMoveFile = true
            if let name = originalFilename {
                let stem = (name as NSString).deletingPathExtension
                imageOpts.originalFilename = stem + ".heic"
            }
            request.addResource(with: .photo, fileURL: imageURL, options: imageOpts)

            // Paired video resource
            let videoOpts = PHAssetResourceCreationOptions()
            videoOpts.shouldMoveFile = true
            if let name = originalFilename {
                let stem = (name as NSString).deletingPathExtension
                videoOpts.originalFilename = stem + ".mov"
            }
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOpts)

            if let date = creationDate { request.creationDate = date }
            if let loc = location { request.location = loc }
            box.placeholder = request.placeholderForCreatedAsset
        }
        guard let id = box.placeholder?.localIdentifier,
              let saved = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw LibraryError.saveFailed }
        return saved
    }

    /// Saves a new image asset from data, preserving creationDate. Returns the new PHAsset.
    /// - Parameter originalFilename: If provided, the resource's filename is set to this
    ///   (with extension changed to .heic).
    func saveImage(data: Data, creationDate: Date?, location: CLLocation?, originalFilename: String? = nil) async throws -> PHAsset {
        // Write to temp file first — addResource(with:fileURL:) is more reliable
        // than addResource(with:data:) for certain asset types (burst members, etc.)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".heic")
        try data.write(to: tempURL)
        log.info("  saveImage: wrote \(data.count) bytes to \(tempURL.lastPathComponent)")

        // Use a class-based box to capture the placeholder from the @Sendable closure,
        // avoiding Swift 6 issues with capturing mutable local variables.
        let box = PlaceholderBox()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let resOpts = PHAssetResourceCreationOptions()
                resOpts.shouldMoveFile = true
                if let name = originalFilename {
                    let stem = (name as NSString).deletingPathExtension
                    resOpts.originalFilename = stem + ".heic"
                }
                request.addResource(with: .photo, fileURL: tempURL, options: resOpts)
                if let date = creationDate { request.creationDate = date }
                if let loc = location { request.location = loc }
                box.placeholder = request.placeholderForCreatedAsset
            }
        } catch {
            log.error("  saveImage: performChanges threw: \(String(describing: error))")
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // Clean up temp file (may already be moved by shouldMoveFile)
        try? FileManager.default.removeItem(at: tempURL)

        guard let id = box.placeholder?.localIdentifier else {
            log.error("  saveImage: placeholder is nil after successful performChanges")
            throw LibraryError.saveFailed
        }
        log.info("  saveImage: placeholder id=\(id)")

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        log.info("  saveImage: fetch returned \(fetchResult.count) assets")

        guard let saved = fetchResult.firstObject else {
            log.error("  saveImage: fetch returned 0 assets for id=\(id)")
            throw LibraryError.saveFailed
        }
        return saved
    }

    /// Saves a new video asset from a file URL. Returns the new PHAsset.
    /// - Parameter originalFilename: If provided, the resource's filename is set to this
    ///   (with extension changed to .mov).
    func saveVideo(at url: URL, creationDate: Date?, location: CLLocation?, originalFilename: String? = nil) async throws -> PHAsset {
        let box = PlaceholderBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            if let name = originalFilename {
                let stem = (name as NSString).deletingPathExtension
                options.originalFilename = stem + ".mov"
            }
            request.addResource(with: .video, fileURL: url, options: options)
            if let date = creationDate { request.creationDate = date }
            if let loc = location { request.location = loc }
            box.placeholder = request.placeholderForCreatedAsset
        }
        guard let id = box.placeholder?.localIdentifier,
              let saved = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw LibraryError.saveFailed }
        return saved
    }
}

// MARK: - Errors

enum LibraryError: LocalizedError {
    case notAuthorized
    case dataUnavailable
    case albumCreationFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:       "Photo library access was denied."
        case .dataUnavailable:     "The asset data could not be retrieved."
        case .albumCreationFailed: "Failed to create album in Photos."
        case .saveFailed:          "Failed to save the compressed asset to Photos."
        }
    }
}

import AVFoundation
import CoreLocation

/// Thread-safe box for capturing PHObjectPlaceholder from @Sendable closures.
/// Using a class avoids the Swift 6 issue where mutable local variables
/// captured by @Sendable closures may not propagate mutations back.
final class PlaceholderBox: @unchecked Sendable {
    var placeholder: PHObjectPlaceholder?
}

/// Wraps a non-Sendable value for crossing actor boundaries where safety is ensured by design.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
