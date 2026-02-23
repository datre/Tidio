import Foundation
import Photos
import AppKit

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
    func requestImageData(for asset: PHAsset) async throws -> (Data, String?) {
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

    /// Requests the full-resolution AVAsset for a video.
    /// Downloads from iCloud if necessary.
    func requestAVAsset(for asset: PHAsset) async throws -> AVURLAsset {
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
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(throwing: LibraryError.dataUnavailable)
                    return
                }
                continuation.resume(returning: urlAsset)
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
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let id = placeholder?.localIdentifier,
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
    /// Returns nil if the asset is not a Live Photo or the resource can't be fetched.
    func requestPairedVideoData(for asset: PHAsset) async throws -> Data {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let pairedVideo = resources.first(where: { $0.type == .pairedVideo }) else {
            throw LibraryError.dataUnavailable
        }

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
    func saveLivePhoto(
        imageData: Data,
        pairedVideoData: Data,
        creationDate: Date?,
        location: CLLocation?,
        originalFilename: String? = nil
    ) async throws -> PHAsset {
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            // Still image resource
            let imageOpts = PHAssetResourceCreationOptions()
            if let name = originalFilename {
                let stem = (name as NSString).deletingPathExtension
                imageOpts.originalFilename = stem + ".heic"
            }
            request.addResource(with: .photo, data: imageData, options: imageOpts)

            // Paired video resource
            let videoOpts = PHAssetResourceCreationOptions()
            if let name = originalFilename {
                let stem = (name as NSString).deletingPathExtension
                videoOpts.originalFilename = stem + ".mov"
            }
            request.addResource(with: .pairedVideo, data: pairedVideoData, options: videoOpts)

            if let date = creationDate { request.creationDate = date }
            if let loc = location { request.location = loc }
            placeholder = request.placeholderForCreatedAsset
        }
        guard let id = placeholder?.localIdentifier,
              let saved = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw LibraryError.saveFailed }
        return saved
    }

    /// Saves a new image asset from data, preserving creationDate. Returns the new PHAsset.
    /// - Parameter originalFilename: If provided, the resource's filename is set to this
    ///   (with extension changed to .heic).
    func saveImage(data: Data, creationDate: Date?, location: CLLocation?, originalFilename: String? = nil) async throws -> PHAsset {
        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let resOpts = PHAssetResourceCreationOptions()
            if let name = originalFilename {
                let stem = (name as NSString).deletingPathExtension
                resOpts.originalFilename = stem + ".heic"
            }
            request.addResource(with: .photo, data: data, options: resOpts)
            if let date = creationDate { request.creationDate = date }
            if let loc = location { request.location = loc }
            placeholder = request.placeholderForCreatedAsset
        }
        guard let id = placeholder?.localIdentifier,
              let saved = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw LibraryError.saveFailed }
        return saved
    }

    /// Saves a new video asset from a file URL. Returns the new PHAsset.
    /// - Parameter originalFilename: If provided, the resource's filename is set to this
    ///   (with extension changed to .mov).
    func saveVideo(at url: URL, creationDate: Date?, location: CLLocation?, originalFilename: String? = nil) async throws -> PHAsset {
        var placeholder: PHObjectPlaceholder?
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
            placeholder = request.placeholderForCreatedAsset
        }
        guard let id = placeholder?.localIdentifier,
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
