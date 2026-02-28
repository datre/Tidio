import Foundation
import Photos
import ImageIO
import os.log

private let log = Logger(subsystem: "com.tidio", category: "CompressionEngine")

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
    private enum PrefetchedData: @unchecked Sendable {
        case imageData(Data)
        case videoAsset(AVAsset)
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
                let fullError = String(describing: error)
                log.error("  ✗ FAILED: \(filename) — \(fullError)")
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
                    let box = try await PhotoLibraryService.shared.requestAVAsset(for: asset)
                    return .videoAsset(box.value)
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
        let resources = PHAssetResource.assetResources(for: asset)
        let resourceTypes = resources.map { "\($0.type.rawValue):\($0.originalFilename)" }
        let subtypes = asset.mediaSubtypes
        log.info("━━━ processAsset: \(originalFilename) ━━━")
        log.info("  mediaType=\(asset.mediaType.rawValue) subtypes=\(subtypes.rawValue) burstID=\(asset.burstIdentifier ?? "none") representsBurst=\(asset.representsBurst)")
        log.info("  isLivePhoto=\(subtypes.contains(.photoLive)) resources=\(resourceTypes)")
        log.info("  prefetched=\(prefetchedData != nil ? "yes" : "no")")

        let assetItem = AssetItem(asset: asset)
        log.info("  format=\(assetItem.originalFormat.displayName) target=\(String(describing: assetItem.originalFormat.compressionTarget))")

        // Skip if already in target format and skip rule is active
        switch assetItem.originalFormat.compressionTarget {
        case .alreadyHEIC where settings.skipAlreadyHEIC:
            log.info("  → SKIP: already HEIC")
            throw CompressionSkipReason.alreadyOptimal
        case .alreadyHEVC where settings.skipAlreadyHEVC:
            log.info("  → SKIP: already HEVC")
            throw CompressionSkipReason.alreadyOptimal
        case .unsupported:
            log.info("  → SKIP: unsupported format")
            throw CompressionSkipReason.alreadyOptimal
        default:
            break
        }

        let result: (newAsset: PHAsset, originalBytes: Int64, compressedBytes: Int64)

        if asset.mediaType == .image {
            log.info("  → compressImage path")
            result = try await compressImage(asset, originalFilename: originalFilename, settings: settings, cameraModelFilter: cameraModelFilter, prefetchedData: prefetchedData)
        } else if asset.mediaType == .video {
            log.info("  → compressVideo path")
            result = try await compressVideo(asset, originalFilename: originalFilename, settings: settings, prefetchedData: prefetchedData)
        } else {
            log.info("  → SKIP: unknown mediaType \(asset.mediaType.rawValue)")
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
        log.info("  imageData: \(sourceData.count) bytes, isLivePhoto=\(isLivePhoto)")

        let pairedVideoTask: Task<Result<Data, Error>?, Never>? = isLivePhoto ? Task.detached {
            do {
                let data = try await PhotoLibraryService.shared.requestPairedVideoData(for: asset)
                log.info("  pairedVideo: downloaded \(data.count) bytes")
                return .success(data)
            } catch {
                log.error("  pairedVideo: FAILED — \(error.localizedDescription)")
                return .failure(error)
            }
        } : nil

        // For Live Photos, extract the content identifier BEFORE compression
        // (HEIC encoding may strip the MakerApple dictionary where it's stored)
        let contentIdentifier: String? = isLivePhoto
            ? ImageCompressor.extractContentIdentifier(from: sourceData)
            : nil
        if isLivePhoto {
            log.info("  Live Photo contentIdentifier=\(contentIdentifier ?? "NOT FOUND")")
        }

        updatePhase(.compressing, fraction: 0.3)

        log.info("  compressing image: quality=\(settings.photoQualityMode.rawValue) cap=\(settings.resolutionCap.rawValue)")
        var compressed = try ImageCompressor.compress(
            sourceData: sourceData,
            qualityMode: settings.photoQualityMode,
            customQuality: settings.photoCustomQuality,
            resolutionCap: settings.resolutionCap
        )
        log.info("  compressed: \(sourceData.count) → \(compressed.count) bytes")

        // For Live Photos, ensure the content identifier is in the HEIC output.
        // CGImageDestination may drop the MakerApple dictionary during HEIC encoding.
        if isLivePhoto, let identifier = contentIdentifier {
            compressed = Self.ensureContentIdentifier(in: compressed, identifier: identifier)
        }

        updatePhase(.saving, fraction: 0.9)

        let saved: PHAsset

        if isLivePhoto, let pairedResult = await pairedVideoTask?.value {
            switch pairedResult {
            case .success(let pairedVideoData):
                // Save as Live Photo (HEIC still + paired video)
                log.info("  saving as Live Photo (still=\(compressed.count), video=\(pairedVideoData.count))")
                saved = try await PhotoLibraryService.shared.saveLivePhoto(
                    imageData: compressed,
                    pairedVideoData: pairedVideoData,
                    creationDate: asset.creationDate,
                    location: asset.location,
                    originalFilename: originalFilename
                )
                log.info("  ✓ saved Live Photo: \(saved.localIdentifier)")
            case .failure(let pairError):
                // Paired video failed — save as regular image and log the issue
                log.warning("  pairedVideo failed (\(pairError.localizedDescription)), saving as regular image")
                saved = try await PhotoLibraryService.shared.saveImage(
                    data: compressed,
                    creationDate: asset.creationDate,
                    location: asset.location,
                    originalFilename: originalFilename
                )
                log.info("  ✓ saved regular image (Live Photo degraded): \(saved.localIdentifier)")
            }
        } else {
            // Regular image save
            log.info("  saving as regular image")
            saved = try await PhotoLibraryService.shared.saveImage(
                data: compressed,
                creationDate: asset.creationDate,
                location: asset.location,
                originalFilename: originalFilename
            )
            log.info("  ✓ saved: \(saved.localIdentifier)")
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
        let avAsset: AVAsset

        // Use prefetched data if available, otherwise download now
        if case .videoAsset(let prefetched) = prefetchedData {
            updatePhase(.compressing, fraction: 0.1)
            avAsset = prefetched
        } else {
            updatePhase(.downloading, fraction: 0)
            log.info("  downloading video via requestAVAsset...")
            avAsset = try await PhotoLibraryService.shared.requestAVAsset(for: asset).value
        }

        let avType = String(describing: type(of: avAsset))
        let urlInfo: String
        if let urlAsset = avAsset as? AVURLAsset {
            urlInfo = urlAsset.url.lastPathComponent
        } else {
            urlInfo = "N/A (composition)"
        }
        log.info("  avAsset type=\(avType) url=\(urlInfo)")

        // Measure original size (works for both AVURLAsset and AVComposition)
        nonisolated(unsafe) let unsafeAsset = avAsset
        let originalSize = await VideoCompressor.estimateOriginalSize(for: unsafeAsset)
        log.info("  originalSize=\(originalSize) bytes")

        updatePhase(.compressing, fraction: 0.1)

        log.info("  compressing video: quality=\(settings.videoQualityMode.rawValue) cap=\(settings.resolutionCap.rawValue)")
        let outputURL = try await VideoCompressor.compress(
            sourceAsset: unsafeAsset,
            qualityMode: settings.videoQualityMode,
            resolutionCap: settings.resolutionCap
        )

        let compressedSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        log.info("  video compressed: \(originalSize) → \(compressedSize) bytes")

        updatePhase(.saving, fraction: 0.9)
        log.info("  saving video to Photos...")
        let saved = try await PhotoLibraryService.shared.saveVideo(
            at: outputURL,
            creationDate: asset.creationDate,
            location: asset.location,
            originalFilename: originalFilename
        )
        log.info("  ✓ saved video: \(saved.localIdentifier)")

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

    // MARK: - Live Photo Content Identifier

    /// Ensures the HEIC data contains the MakerApple content identifier required
    /// for Photos to link the still and video of a Live Photo.
    /// CGImageDestination may strip the MakerApple dictionary during HEIC encoding,
    /// so we re-read and re-write with the identifier explicitly set.
    static func ensureContentIdentifier(in heicData: Data, identifier: String) -> Data {
        guard let source = CGImageSourceCreateWithData(heicData as CFData, nil) else {
            log.warning("  ensureContentIdentifier: could not create source from HEIC")
            return heicData
        }

        var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        // Check if MakerApple with key 17 already exists
        if let makerApple = props[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any],
           let existing = makerApple["17" as CFString] as? String, !existing.isEmpty {
            log.info("  ensureContentIdentifier: already present (\(existing))")
            return heicData
        }

        // Inject the content identifier into MakerApple dictionary
        var makerApple = (props[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any]) ?? [:]
        makerApple["17" as CFString] = identifier
        props[kCGImagePropertyMakerAppleDictionary] = makerApple
        log.info("  ensureContentIdentifier: injected '\(identifier)' into MakerApple")

        // Re-encode the HEIC with the patched metadata
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            log.warning("  ensureContentIdentifier: could not decode HEIC image")
            return heicData
        }

        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            output, "public.heic" as CFString, 1, nil
        ) else {
            log.warning("  ensureContentIdentifier: could not create destination")
            return heicData
        }

        // Preserve the original compression quality by not re-specifying it
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            log.warning("  ensureContentIdentifier: finalize failed")
            return heicData
        }

        let result = output as Data
        log.info("  ensureContentIdentifier: re-encoded HEIC \(heicData.count) → \(result.count) bytes")
        return result
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
