import Foundation
import Photos
import ImageIO
import os.log

private let log = Logger(subsystem: "com.tidio", category: "CompressionEngine")

/// Orchestrates the full compression pipeline for a batch of assets.
/// Uses a producer-consumer pipeline: downloads run continuously ahead of
/// compression, feeding a buffer. Compression processes items in order.
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

    // MARK: - Pipeline Item (per-item status for details view)

    struct PipelineItem: Identifiable, Equatable {
        let id: String          // asset localIdentifier
        let filename: String
        var status: PipelineStatus

        enum PipelineStatus: Equatable {
            case pending        // grey — waiting for download
            case downloading    // grey — currently downloading
            case downloaded     // orange — downloaded, queued for conversion
            case converting     // orange — currently converting
            case converted      // green — done
            case skipped        // secondary
            case failed         // red
        }
    }

    // MARK: - Published Properties

    @Published var state: JobState = .idle
    @Published var totalCount: Int = 0

    // Download tracking
    @Published var downloadedCount: Int = 0
    @Published var currentDownloadFilename: String?

    // Conversion tracking
    @Published var convertedCount: Int = 0
    @Published var currentItemProgress: ItemProgress?
    @Published var overallProgress: Double = 0

    // Per-item status for details view
    @Published var pipelineItems: [PipelineItem] = []

    // MARK: - Private Pipeline State

    /// Buffer holding downloaded data keyed by asset index.
    private var downloadBuffer: [Int: PrefetchedData] = [:]

    /// Max items downloaded ahead of compression to limit memory usage.
    private let maxBufferAhead = 5

    private enum PrefetchedData: @unchecked Sendable {
        case imageData(Data)
        case videoAsset(AVAsset)
    }

    // MARK: - Run Job

    func run(assets: [PHAsset], settings: AppSettings, cameraModelFilter: String? = nil) async {
        guard state == .idle else { return }
        state = .running
        totalCount = assets.count
        convertedCount = 0
        downloadedCount = 0
        downloadBuffer = [:]
        currentDownloadFilename = nil
        currentItemProgress = nil
        overallProgress = 0

        // Initialize pipeline items
        pipelineItems = assets.map { asset in
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
            return PipelineItem(id: asset.localIdentifier, filename: name, status: .pending)
        }

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

        // --- DOWNLOAD PRODUCER ---
        // Runs on main actor, yields at await points so compression can interleave.
        // Downloads one at a time but stays ahead of compression.
        let downloadTask = Task {
            for (index, asset) in assets.enumerated() {
                guard self.state == .running else { break }

                // Backpressure: wait if buffer is too far ahead of compression
                while self.downloadedCount - self.convertedCount >= self.maxBufferAhead && self.state == .running {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard self.state == .running else { break }

                self.pipelineItems[index].status = .downloading
                self.currentDownloadFilename = self.pipelineItems[index].filename

                do {
                    if asset.mediaType == .image {
                        let (data, _) = try await PhotoLibraryService.shared.requestImageData(for: asset)
                        self.downloadBuffer[index] = .imageData(data)
                    } else if asset.mediaType == .video {
                        let box = try await PhotoLibraryService.shared.requestAVAsset(for: asset)
                        self.downloadBuffer[index] = .videoAsset(box.value)
                    }
                    self.pipelineItems[index].status = .downloaded
                } catch {
                    log.error("  download[\(index)] failed: \(error.localizedDescription)")
                    // Mark as downloaded so compression can try its own fallback
                    self.pipelineItems[index].status = .downloaded
                }
                self.downloadedCount += 1
            }
            self.currentDownloadFilename = nil
        }

        // --- COMPRESSION CONSUMER ---
        // Processes items in order, waiting for downloads to become available.
        for (index, asset) in assets.enumerated() {
            guard state == .running else { break }

            let filename = pipelineItems[index].filename

            // Wait for this item's download to complete
            while downloadedCount <= index && state == .running {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard state == .running else { break }

            let prefetchedData = downloadBuffer.removeValue(forKey: index)

            pipelineItems[index].status = .converting
            currentItemProgress = ItemProgress(id: asset.localIdentifier, filename: filename, phase: .compressing, fraction: 0)

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
                pipelineItems[index].status = .converted
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
                pipelineItems[index].status = .skipped
            } catch {
                failed += 1
                let fullError = String(describing: error)
                log.error("  \u{2717} FAILED: \(filename) \u{2014} \(fullError)")
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
                pipelineItems[index].status = .failed
            }

            convertedCount = index + 1
            overallProgress = Double(convertedCount) / Double(totalCount)
        }

        // Clean up download task
        downloadTask.cancel()
        downloadBuffer = [:]
        currentDownloadFilename = nil

        // Add failed assets to a dedicated album so the user can retry later
        if !failedAssets.isEmpty {
            if let failedAlbum = try? await PhotoLibraryService.shared.findOrCreateAlbum(named: settings.failedAlbumName) {
                try? await PhotoLibraryService.shared.addAssets(failedAssets, to: failedAlbum)
            }
        }

        state = .finished(summary: JobSummary(
            totalProcessed: convertedCount - skipped - failed,
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

    func reset() {
        state = .idle
        overallProgress = 0
        convertedCount = 0
        downloadedCount = 0
        totalCount = 0
        currentItemProgress = nil
        currentDownloadFilename = nil
        pipelineItems = []
        downloadBuffer = [:]
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
        log.info("\u{2501}\u{2501}\u{2501} processAsset: \(originalFilename) \u{2501}\u{2501}\u{2501}")
        log.info("  mediaType=\(asset.mediaType.rawValue) subtypes=\(subtypes.rawValue) burstID=\(asset.burstIdentifier ?? "none") representsBurst=\(asset.representsBurst)")
        log.info("  isLivePhoto=\(subtypes.contains(.photoLive)) resources=\(resourceTypes)")
        log.info("  prefetched=\(prefetchedData != nil ? "yes" : "no")")

        let assetItem = AssetItem(asset: asset)
        log.info("  format=\(assetItem.originalFormat.displayName) target=\(String(describing: assetItem.originalFormat.compressionTarget))")

        // Skip if already in target format and skip rule is active
        switch assetItem.originalFormat.compressionTarget {
        case .alreadyHEIC where settings.skipAlreadyHEIC:
            log.info("  \u{2192} SKIP: already HEIC")
            throw CompressionSkipReason.alreadyOptimal
        case .alreadyHEVC where settings.skipAlreadyHEVC:
            log.info("  \u{2192} SKIP: already HEVC")
            throw CompressionSkipReason.alreadyOptimal
        case .unsupported:
            log.info("  \u{2192} SKIP: unsupported format")
            throw CompressionSkipReason.alreadyOptimal
        default:
            break
        }

        let result: (newAsset: PHAsset, originalBytes: Int64, compressedBytes: Int64)

        if asset.mediaType == .image {
            log.info("  \u{2192} compressImage path")
            result = try await compressImage(asset, originalFilename: originalFilename, settings: settings, cameraModelFilter: cameraModelFilter, prefetchedData: prefetchedData)
        } else if asset.mediaType == .video {
            log.info("  \u{2192} compressVideo path")
            result = try await compressVideo(asset, originalFilename: originalFilename, settings: settings, prefetchedData: prefetchedData)
        } else {
            log.info("  \u{2192} SKIP: unknown mediaType \(asset.mediaType.rawValue)")
            throw CompressionSkipReason.alreadyOptimal
        }

        // Add to Tidio albums
        updatePhase(.saving, fraction: 0.8)
        try await PhotoLibraryService.shared.addAssets([result.newAsset], to: compressedAlbum)
        try await PhotoLibraryService.shared.addAssets([asset], to: originalsAlbum)

        // Copy original album memberships to the new asset, excluding Tidio's own albums
        let tidioAlbumIDs: Set<String> = [compressedAlbum.localIdentifier, originalsAlbum.localIdentifier]
        let originalAlbums = await PhotoLibraryService.shared.fetchContainingAlbums(for: asset)
        for album in originalAlbums where !tidioAlbumIDs.contains(album.localIdentifier) {
            try? await PhotoLibraryService.shared.addAssets([result.newAsset], to: album)
        }

        updatePhase(.done, fraction: 1.0)

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

        if case .imageData(let data) = prefetchedData {
            updatePhase(.compressing, fraction: 0.1)
            sourceData = data
        } else {
            updatePhase(.downloading, fraction: 0)
            let (data, _) = try await PhotoLibraryService.shared.requestImageData(for: asset)
            sourceData = data
        }

        if let filter = cameraModelFilter, !filter.isEmpty {
            let model = Self.readCameraModel(from: sourceData) ?? ""
            guard model.localizedCaseInsensitiveContains(filter) else {
                throw CompressionSkipReason.alreadyOptimal
            }
        }

        let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
        log.info("  imageData: \(sourceData.count) bytes, isLivePhoto=\(isLivePhoto)")

        let pairedVideoTask: Task<Result<Data, Error>?, Never>? = isLivePhoto ? Task.detached {
            do {
                let data = try await PhotoLibraryService.shared.requestPairedVideoData(for: asset)
                log.info("  pairedVideo: downloaded \(data.count) bytes")
                return .success(data)
            } catch {
                log.error("  pairedVideo: FAILED \u{2014} \(error.localizedDescription)")
                return .failure(error)
            }
        } : nil

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
        log.info("  compressed: \(sourceData.count) \u{2192} \(compressed.count) bytes")

        if isLivePhoto, let identifier = contentIdentifier {
            compressed = Self.ensureContentIdentifier(in: compressed, identifier: identifier)
        }

        updatePhase(.saving, fraction: 0.9)

        let saved: PHAsset

        if isLivePhoto, let pairedResult = await pairedVideoTask?.value {
            switch pairedResult {
            case .success(let pairedVideoData):
                log.info("  saving as Live Photo (still=\(compressed.count), video=\(pairedVideoData.count))")
                saved = try await PhotoLibraryService.shared.saveLivePhoto(
                    imageData: compressed,
                    pairedVideoData: pairedVideoData,
                    creationDate: asset.creationDate,
                    location: asset.location,
                    originalFilename: originalFilename
                )
                log.info("  \u{2713} saved Live Photo: \(saved.localIdentifier)")
            case .failure(let pairError):
                log.warning("  pairedVideo failed (\(pairError.localizedDescription)), saving as regular image")
                saved = try await PhotoLibraryService.shared.saveImage(
                    data: compressed,
                    creationDate: asset.creationDate,
                    location: asset.location,
                    originalFilename: originalFilename
                )
                log.info("  \u{2713} saved regular image (Live Photo degraded): \(saved.localIdentifier)")
            }
        } else {
            log.info("  saving as regular image")
            saved = try await PhotoLibraryService.shared.saveImage(
                data: compressed,
                creationDate: asset.creationDate,
                location: asset.location,
                originalFilename: originalFilename
            )
            log.info("  \u{2713} saved: \(saved.localIdentifier)")
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
        log.info("  video compressed: \(originalSize) \u{2192} \(compressedSize) bytes")

        updatePhase(.saving, fraction: 0.9)
        log.info("  saving video to Photos...")
        let saved = try await PhotoLibraryService.shared.saveVideo(
            at: outputURL,
            creationDate: asset.creationDate,
            location: asset.location,
            originalFilename: originalFilename
        )
        log.info("  \u{2713} saved video: \(saved.localIdentifier)")

        try? FileManager.default.removeItem(at: outputURL)
        return (saved, originalSize, compressedSize)
    }

    // MARK: - EXIF Helpers

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

    static func ensureContentIdentifier(in heicData: Data, identifier: String) -> Data {
        guard let source = CGImageSourceCreateWithData(heicData as CFData, nil) else {
            log.warning("  ensureContentIdentifier: could not create source from HEIC")
            return heicData
        }

        var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        if let makerApple = props[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any],
           let existing = makerApple["17" as CFString] as? String, !existing.isEmpty {
            log.info("  ensureContentIdentifier: already present (\(existing))")
            return heicData
        }

        var makerApple = (props[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any]) ?? [:]
        makerApple["17" as CFString] = identifier
        props[kCGImagePropertyMakerAppleDictionary] = makerApple
        log.info("  ensureContentIdentifier: injected '\(identifier)' into MakerApple")

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

        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            log.warning("  ensureContentIdentifier: finalize failed")
            return heicData
        }

        let result = output as Data
        log.info("  ensureContentIdentifier: re-encoded HEIC \(heicData.count) \u{2192} \(result.count) bytes")
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
