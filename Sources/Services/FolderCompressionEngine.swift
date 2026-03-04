import Foundation
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
import os.log

private let log = Logger(subsystem: "com.tidio", category: "FolderCompressionEngine")

/// Compresses media files from a local folder, saving results to a subfolder.
/// Mirrors CompressionEngine's published interface but works with file URLs
/// instead of PHAssets.
@MainActor
final class FolderCompressionEngine: ObservableObject {

    // Reuse shared types from CompressionEngine
    typealias JobState = CompressionEngine.JobState
    typealias JobSummary = CompressionEngine.JobSummary
    typealias ItemDetail = CompressionEngine.ItemDetail
    typealias ItemProgress = CompressionEngine.ItemProgress
    typealias PipelineItem = CompressionEngine.PipelineItem

    // MARK: - Published Properties

    @Published var state: JobState = .idle
    @Published var totalCount: Int = 0

    @Published var downloadedCount: Int = 0
    @Published var currentDownloadFilename: String?

    @Published var convertedCount: Int = 0
    @Published var currentItemProgress: ItemProgress?
    @Published var overallProgress: Double = 0

    @Published var pipelineItems: [PipelineItem] = []

    // MARK: - Private State

    private var readBuffer: [Int: ReadData] = [:]
    private let maxBufferAhead = 5

    private enum ReadData {
        case imageData(Data)
        case videoURL(URL)
    }

    enum MediaKind {
        case image
        case video
    }

    // MARK: - Supported File Types

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "bmp", "gif"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi"
    ]
    private static let skipExtensions: Set<String> = [
        "heic", "heif"
    ]

    static func mediaKind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// Scans a folder for supported media files (non-recursive in top level, recursive in subdirs).
    static func scanFolder(_ folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if imageExtensions.contains(ext) || videoExtensions.contains(ext) {
                files.append(fileURL)
            }
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Run Job

    func run(files: [URL], outputFolder: URL, settings: AppSettings) async {
        guard state == .idle else { return }
        state = .running
        totalCount = files.count
        convertedCount = 0
        downloadedCount = 0
        readBuffer = [:]
        currentDownloadFilename = nil
        currentItemProgress = nil
        overallProgress = 0

        // Create output folder
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        } catch {
            state = .failed("Could not create output folder: \(error.localizedDescription)")
            return
        }

        // Initialize pipeline items
        pipelineItems = files.map { url in
            PipelineItem(id: url.absoluteString, filename: url.lastPathComponent, status: .pending)
        }

        var skipped = 0
        var failed = 0
        var errors: [String] = []
        var totalOriginalBytes: Int64 = 0
        var totalCompressedBytes: Int64 = 0
        var itemDetails: [ItemDetail] = []

        // --- READ PRODUCER ---
        let readTask = Task {
            for (index, fileURL) in files.enumerated() {
                guard self.state == .running else { break }

                while self.downloadedCount - self.convertedCount >= self.maxBufferAhead && self.state == .running {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard self.state == .running else { break }

                self.pipelineItems[index].status = .downloading
                self.currentDownloadFilename = fileURL.lastPathComponent

                let kind = Self.mediaKind(for: fileURL)
                if kind == .image {
                    if let data = try? Data(contentsOf: fileURL) {
                        self.readBuffer[index] = .imageData(data)
                    }
                } else if kind == .video {
                    self.readBuffer[index] = .videoURL(fileURL)
                }

                self.pipelineItems[index].status = .downloaded
                self.downloadedCount += 1
            }
            self.currentDownloadFilename = nil
        }

        // --- COMPRESSION CONSUMER ---
        for (index, fileURL) in files.enumerated() {
            guard state == .running else { break }

            let filename = fileURL.lastPathComponent

            // Wait for read to complete
            while downloadedCount <= index && state == .running {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard state == .running else { break }

            let readData = readBuffer.removeValue(forKey: index)
            let kind = Self.mediaKind(for: fileURL)

            pipelineItems[index].status = .converting
            currentItemProgress = ItemProgress(id: fileURL.absoluteString, filename: filename, phase: .compressing, fraction: 0)

            // Skip already-HEIC files
            let ext = fileURL.pathExtension.lowercased()
            if Self.skipExtensions.contains(ext) {
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
                convertedCount = index + 1
                overallProgress = Double(convertedCount) / Double(totalCount)
                continue
            }

            do {
                let result: (originalBytes: Int64, compressedBytes: Int64, compressedFilename: String)

                if kind == .image {
                    result = try await compressImage(
                        fileURL: fileURL,
                        readData: readData,
                        outputFolder: outputFolder,
                        settings: settings
                    )
                } else if kind == .video {
                    result = try await compressVideo(
                        fileURL: fileURL,
                        outputFolder: outputFolder,
                        settings: settings
                    )
                } else {
                    skipped += 1
                    updatePhase(.skipped, fraction: 1)
                    pipelineItems[index].status = .skipped
                    itemDetails.append(ItemDetail(
                        originalFilename: filename,
                        compressedFilename: "\u{2014}",
                        originalBytes: 0,
                        compressedBytes: 0,
                        status: .skipped,
                        asset: nil
                    ))
                    convertedCount = index + 1
                    overallProgress = Double(convertedCount) / Double(totalCount)
                    continue
                }

                totalOriginalBytes += result.originalBytes
                totalCompressedBytes += result.compressedBytes
                itemDetails.append(ItemDetail(
                    originalFilename: filename,
                    compressedFilename: result.compressedFilename,
                    originalBytes: result.originalBytes,
                    compressedBytes: result.compressedBytes,
                    status: .compressed,
                    asset: nil
                ))
                pipelineItems[index].status = .converted
            } catch {
                failed += 1
                log.error("  \u{2717} FAILED: \(filename) \u{2014} \(String(describing: error))")
                errors.append("\(filename): \(error.localizedDescription)")
                updatePhase(.failed, fraction: 1)
                itemDetails.append(ItemDetail(
                    originalFilename: filename,
                    compressedFilename: "\u{2014}",
                    originalBytes: 0,
                    compressedBytes: 0,
                    status: .failed,
                    asset: nil
                ))
                pipelineItems[index].status = .failed
            }

            convertedCount = index + 1
            overallProgress = Double(convertedCount) / Double(totalCount)
        }

        readTask.cancel()
        readBuffer = [:]
        currentDownloadFilename = nil

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
        readBuffer = [:]
    }

    // MARK: - Image Compression

    private func compressImage(
        fileURL: URL,
        readData: ReadData?,
        outputFolder: URL,
        settings: AppSettings
    ) async throws -> (originalBytes: Int64, compressedBytes: Int64, compressedFilename: String) {
        let sourceData: Data
        if case .imageData(let data) = readData {
            sourceData = data
        } else {
            sourceData = try Data(contentsOf: fileURL)
        }

        updatePhase(.compressing, fraction: 0.3)

        let compressed = try ImageCompressor.compress(
            sourceData: sourceData,
            qualityMode: settings.photoQualityMode,
            customQuality: settings.photoCustomQuality,
            resolutionCap: settings.resolutionCap
        )

        updatePhase(.saving, fraction: 0.8)

        let stem = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let outFilename = stem + ".heic"
        let outURL = outputFolder.appendingPathComponent(outFilename)

        // Avoid overwriting: add suffix if file exists
        let finalURL = uniqueURL(for: outURL)
        try compressed.write(to: finalURL)

        updatePhase(.done, fraction: 1.0)
        return (Int64(sourceData.count), Int64(compressed.count), finalURL.lastPathComponent)
    }

    // MARK: - Video Compression

    private func compressVideo(
        fileURL: URL,
        outputFolder: URL,
        settings: AppSettings
    ) async throws -> (originalBytes: Int64, compressedBytes: Int64, compressedFilename: String) {
        updatePhase(.compressing, fraction: 0.1)

        let avAsset = AVURLAsset(url: fileURL)
        nonisolated(unsafe) let unsafeAsset: AVAsset = avAsset
        let originalSize = await VideoCompressor.estimateOriginalSize(for: unsafeAsset)

        let tempURL = try await VideoCompressor.compress(
            sourceAsset: unsafeAsset,
            qualityMode: settings.videoQualityMode,
            resolutionCap: settings.resolutionCap
        )

        let compressedSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0

        updatePhase(.saving, fraction: 0.8)

        let stem = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let outFilename = stem + ".mov"
        let outURL = outputFolder.appendingPathComponent(outFilename)
        let finalURL = uniqueURL(for: outURL)

        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        updatePhase(.done, fraction: 1.0)
        return (originalSize, compressedSize, finalURL.lastPathComponent)
    }

    // MARK: - Helpers

    private func updatePhase(_ phase: ItemProgress.Phase, fraction: Double) {
        guard var item = currentItemProgress else { return }
        item.phase = phase
        item.fraction = fraction
        currentItemProgress = item
    }

    /// Returns a unique URL by appending " (2)", " (3)" etc. if the file already exists.
    private func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let dir = url.deletingLastPathComponent()
        let stem = (url.deletingPathExtension().lastPathComponent)
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
