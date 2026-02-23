import Foundation
import Photos
import ImageIO

/// Orchestrates the full compression pipeline for a batch of assets.
/// Handles iCloud downloads, delegates to ImageCompressor / VideoCompressor,
/// saves results to Photos, and manages the output albums.
///
/// Uses a prefetch pipeline: while the current asset is compressing, the next
/// asset's data is already being downloaded from Photos/iCloud.
@MainActor
final class CompressionEngine: ObservableObject {

    // MARK: - Job State

    enum JobState: Equatable {
        case idle
        case running
        case paused
        case finished(summary: JobSummary)
        case failed(String)
    }

    struct ItemDetail: Equatable, Identifiable {
        let id = UUID()
        let originalFilename: String
        let compressedFilename: String
        let originalBytes: Int64
        let compressedBytes: Int64
        let status: Status
        /// The original PHAsset (kept for retry / error-album features)
        let asset: PHAsset?

        enum Status: String, Equatable {
            case compressed = "Compressed"
            case skipped    = "Skipped"
            case failed     = "Failed"
        }

        static func == (lhs: ItemDetail, rhs: ItemDetail) -> Bool {
            lhs.id == rhs.id
        }

        var savedBytes: Int64 { originalBytes - compressedBytes }
        var savingsPercent: Double {
            guard originalBytes > 0 else { return 0 }
            return Double(savedBytes) / Double(originalBytes) * 100
        }
    }

    struct JobSummary: Equatable {
        let totalProcessed: Int
        let skipped: Int
        let failed: Int
        let errors: [String]
        let originalBytes: Int64
        let compressedBytes: Int64
        let itemDetails: [ItemDetail]
    }

    struct ItemProgress: Identifiable {
        let id: String          // asset localIdentifier
        var filename: String
        var phase: Phase
        var fraction: Double    // 0–1 within this item

        enum Phase: String {
            case queued       = "Queued"
            case downloading  = "Downloading from iCloud"
            case compressing  = "Compressing"
            case saving       = "Saving to Photos"
            case done         = "Done"
            case skipped      = "Skipped"
            case failed       = "Failed"
        }
    }

    @Published var state: JobState = .idle
    @Published var overallProgress: Double = 0
    @Published var currentItemProgress: ItemProgress?
    @Published var completedCount: Int = 0
    @Published var totalCount: Int = 0

    private var cancellationTask: Task<Void, Never>?

    // MARK: - Prefetched Data

    /// Holds pre-downloaded data for the next asset in the queue.
    private enum PrefetchedData: Sendable {
        case imageData(Data)
        case videoAsset(AVURLAsset)
    }

    // MARK: - Run Job

    /// - Parameter cameraModelFilter: If non-nil, only process assets whose EXIF
    ///   make/model contains this string (case-insensitive). Applied to images only.
    func run(assets: [PHAsset], settings: AppSettings, cameraModelFilter: String? = nil) async {
        guard state == .idle else { return }
        state = .running
        totalCount = assets.count
        completedCount = 0

        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var totalOriginalBytes: Int64 = 0
        var totalCompressedBytes: Int64 = 0
        var itemDetails: [ItemDetail] = []
        var failedAssets: [PHAsset] = []

        // Ensure output albums exist
        let compressedAlbum: PHAssetCollection
        let originalsAlbum: PHAssetCollection
        do {
            compressedAlbum = try await PhotoLibraryService.shared.findOrCreateAlbum(named: settings.compressedAlbumName)
            originalsAlbum  = try await PhotoLibraryService.shared.findOrCreateAlbum(named: settings.originalsAlbumName)
        } catch {
            state = .failed("Could not create output albums: \(error.localizedDescription)")
            return
        }

        // Prefetch pipeline: kick off download for the first asset
        var pendingPrefetch: Task<PrefetchedData?, Never>? = nil
        if let first = assets.first {
            pendingPrefetch = prefetch(asset: first)
        }

        for (index, asset) in assets.enumerated() {
            guard state == .running else { break }

            let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
            currentItemProgress = ItemProgress(id: asset.localIdentifier, filename: filename, phase: .queued, fraction: 0)

            // Await the prefetched data for this asset
            let prefetchedData = await pendingPrefetch?.value
            pendingPrefetch = nil

            // Start prefetching the next asset while we process this one
            let nextIndex = index + 1
            if nextIndex < assets.count {
                pendingPrefetch = prefetch(asset: assets[nextIndex])
            }

            do {
                let result = try await processAsset(
                    asset,
                    originalFilename: filename,
                    settings: settings,
                    cameraModelFilter: cameraModelFilter,
                    compressedAlbum: compressedAlbum,
                    originalsAlbum: originalsAlbum,
                    prefetchedData: prefetchedData
                )
                totalOriginalBytes += result.original
                totalCompressedBytes += result.compressed
                itemDetails.append(ItemDetail(
                    originalFilename: filename,
                    compressedFilename: result.compressedFilename,
                    originalBytes: result.original,
                    compressedBytes: result.compressed,
                    status: .compressed,
                    asset: nil
                ))
            } catch CompressionSkipReason.alreadyOptimal {
                skipped += 1
                updatePhase(.skipped, fraction: 1)
                itemDetails.append(ItemDetail(
                    originalFilename: filename,
                    compressedFilename: "\u{2014}",
                    originalBytes: 0,
                    compressedBytes: 0,
                    status: .skipped,
                    asset: nil
                ))
            } catch {
                failed += 1
                errors.append("\(filename): \(error.localizedDescription)")
                updatePhase(.failed, fraction: 1)
                failedAssets.append(asset)
                itemDetails.append(ItemDetail(
                    originalFilename: filename,
                    compressedFilename: "\u{2014}",
                    originalBytes: 0,
                    compressedBytes: 0,
                    status: .failed,
                    asset: asset
                ))
            }

            completedCount = index + 1
            overallProgress = Double(completedCount) / Double(totalCount)
        }

        // Cancel any remaining prefetch
        pendingPrefetch?.cancel()

        // Add failed assets to a dedicated album so the user can retry later
        if !failedAssets.isEmpty {
            if let failedAlbum = try? await PhotoLibraryService.shared.findOrCreateAlbum(named: settings.failedAlbumName) {
                try? await PhotoLibraryService.shared.addAssets(failedAssets, to: failedAlbum)
            }
        }

        state = .finished(summary: JobSummary(
            totalProcessed: completedCount - skipped - failed,
            skipped: skipped,
            failed: failed,
            errors: errors,
            originalBytes: totalOriginalBytes,
            compressedBytes: totalCompressedBytes,
            itemDetails: itemDetails
        ))
    }

    func cancel() {
        state = .idle
    }

    /// Resets back to idle so the summary sheet can be dismissed.
    func reset() {
        state = .idle
        overallProgress = 0
        completedCount = 0
        totalCount = 0
        currentItemProgress = nil
    }

    // MARK: - Prefetch

    /// Starts downloading the asset data in the background.
    /// Returns a Task that resolves to the downloaded data, or nil on failure.
    private func prefetch(asset: PHAsset) -> Task<PrefetchedData?, Never> {
        Task.detached {
            do {
                if asset.mediaType == .image {
                    let (data, _) = try await PhotoLibraryService.shared.requestImageData(for: asset)
                    return .imageData(data)
                } else if asset.mediaType == .video {
                    let avAsset = try await PhotoLibraryService.shared.requestAVAsset(for: asset)
                    return .videoAsset(avAsset)
                }
            } catch {}
            return nil
        }
    }

    // MARK: - Single Asset Processing

    private func processAsset(
        _ asset: PHAsset,
        originalFilename: String,
        settings: AppSettings,
        cameraModelFilter: String?,
        compressedAlbum: PHAssetCollection,
        originalsAlbum: PHAssetCollection,
        prefetchedData: PrefetchedData?
    ) async throws -> (original: Int64, compressed: Int64, compressedFilename: String) {
        let assetItem = AssetItem(asset: asset)

        // Skip if already in target format and skip rule is active
        switch assetItem.originalFormat.compressionTarget {
        case .alreadyHEIC where settings.skipAlreadyHEIC:
            throw CompressionSkipReason.alreadyOptimal
        case .alreadyHEVC where settings.skipAlreadyHEVC:
            throw CompressionSkipReason.alreadyOptimal
        case .unsupported:
            throw CompressionSkipReason.alreadyOptimal
        default:
            break
        }

        let result: (newAsset: PHAsset, originalBytes: Int64, compressedBytes: Int64)

        if asset.mediaType == .image {
            result = try await compressImage(asset, originalFilename: originalFilename, settings: settings, cameraModelFilter: cameraModelFilter, prefetchedData: prefetchedData)
        } else if asset.mediaType == .video {
            result = try await compressVideo(asset, originalFilename: originalFilename, settings: settings, prefetchedData: prefetchedData)
        } else {
            throw CompressionSkipReason.alreadyOptimal
        }

        // Add to albums
        updatePhase(.saving, fraction: 0.8)
        try await PhotoLibraryService.shared.addAssets([result.newAsset], to: compressedAlbum)
        try await PhotoLibraryService.shared.addAssets([asset], to: originalsAlbum)
        updatePhase(.done, fraction: 1.0)

        // Derive the compressed filename: same stem, new extension
        let stem = (originalFilename as NSString).deletingPathExtension
        let ext = asset.mediaType == .video ? "mov" : "heic"
        let compressedFilename = stem + "." + ext

        return (result.originalBytes, result.compressedBytes, compressedFilename)
    }

    // MARK: - Image Compression

    private func compressImage(
        _ asset: PHAsset,
        originalFilename: String,
        settings: AppSettings,
        cameraModelFilter: String?,
        prefetchedData: PrefetchedData?
    ) async throws -> (newAsset: PHAsset, originalBytes: Int64, compressedBytes: Int64) {
        let sourceData: Data

        // Use prefetched data if available, otherwise download now
        if case .imageData(let data) = prefetchedData {
            updatePhase(.compressing, fraction: 0.1)
            sourceData = data
        } else {
            updatePhase(.downloading, fraction: 0)
            let (data, _) = try await PhotoLibraryService.shared.requestImageData(for: asset)
            sourceData = data
        }

        // Camera model filter: check EXIF after we have the data (no extra download needed)
        if let filter = cameraModelFilter, !filter.isEmpty {
            let model = Self.readCameraModel(from: sourceData) ?? ""
            guard model.localizedCaseInsensitiveContains(filter) else {
                throw CompressionSkipReason.alreadyOptimal
            }
        }

        // For Live Photos, download the paired video in parallel with compression
        let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
        let pairedVideoTask: Task<Data?, Never>? = isLivePhoto ? Task.detached {
            try? await PhotoLibraryService.shared.requestPairedVideoData(for: asset)
        } : nil

        updatePhase(.compressing, fraction: 0.3)

        let compressed = try ImageCompressor.compress(
            sourceData: sourceData,
            qualityMode: settings.photoQualityMode,
            customQuality: settings.photoCustomQuality,
            resolutionCap: settings.resolutionCap
        )
        updatePhase(.saving, fraction: 0.9)

        let saved: PHAsset

        if isLivePhoto, let pairedVideoData = await pairedVideoTask?.value {
            // Save as Live Photo (HEIC still + paired video)
            saved = try await PhotoLibraryService.shared.saveLivePhoto(
                imageData: compressed,
                pairedVideoData: pairedVideoData,
                creationDate: asset.creationDate,
                location: asset.location,
                originalFilename: originalFilename
            )
        } else {
            // Regular image save
            saved = try await PhotoLibraryService.shared.saveImage(
                data: compressed,
                creationDate: asset.creationDate,
                location: asset.location,
                originalFilename: originalFilename
            )
        }

        return (saved, Int64(sourceData.count), Int64(compressed.count))
    }

    // MARK: - Video Compression

    private func compressVideo(
        _ asset: PHAsset,
        originalFilename: String,
        settings: AppSettings,
        prefetchedData: PrefetchedData?
    ) async throws -> (newAsset: PHAsset, originalBytes: Int64, compressedBytes: Int64) {
        let avAsset: AVURLAsset

        // Use prefetched data if available, otherwise download now
        if case .videoAsset(let prefetched) = prefetchedData {
            updatePhase(.compressing, fraction: 0.1)
            avAsset = prefetched
        } else {
            updatePhase(.downloading, fraction: 0)
            avAsset = try await PhotoLibraryService.shared.requestAVAsset(for: asset)
        }

        // Measure original size from the source file
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: avAsset.url.path)[.size] as? Int64) ?? 0

        updatePhase(.compressing, fraction: 0.1)

        let outputURL = try await VideoCompressor.compress(
            sourceAsset: avAsset,
            qualityMode: settings.videoQualityMode,
            resolutionCap: settings.resolutionCap
        )

        let compressedSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0

        updatePhase(.saving, fraction: 0.9)
        let saved = try await PhotoLibraryService.shared.saveVideo(
            at: outputURL,
            creationDate: asset.creationDate,
            location: asset.location,
            originalFilename: originalFilename
        )

        // shouldMoveFile handles cleanup, but ensure temp file is gone
        try? FileManager.default.removeItem(at: outputURL)
        return (saved, originalSize, compressedSize)
    }

    // MARK: - EXIF Helpers

    /// Reads camera make + model from image EXIF (TIFF dictionary).
    /// Returns a combined "Make Model" string, e.g. "Apple iPhone 15 Pro".
    static func readCameraModel(from data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        else { return nil }
        let make  = tiff[kCGImagePropertyTIFFMake]  as? String ?? ""
        let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
        let combined = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? nil : combined
    }

    // MARK: - Progress Helpers

    private func updatePhase(_ phase: ItemProgress.Phase, fraction: Double) {
        guard var item = currentItemProgress else { return }
        item.phase = phase
        item.fraction = fraction
        currentItemProgress = item
    }
}

// MARK: - Skip Reason

enum CompressionSkipReason: Error {
    case alreadyOptimal
}
