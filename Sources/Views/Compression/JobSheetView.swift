import SwiftUI
import Photos
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct JobSheetView: View {
    let assets: [PHAsset]
    let settings: AppSettings
    @ObservedObject var engine: CompressionEngine
    let onStart: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void
    let onRetryFailed: (([PHAsset]) -> Void)?

    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch engine.state {
            case .idle:
                confirmationPhase
            case .running, .paused:
                progressPhase
            case .finished(let summary):
                summaryPhase(summary)
            case .failed(let message):
                failedPhase(message)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: sheetWidth)
        #endif
        .frame(minHeight: 380)
        .interactiveDismissDisabled(engine.state == .running || engine.state == .paused)
        .animation(.easeInOut(duration: 0.25), value: showingDetails)
    }

    // MARK: - Confirmation Phase

    private var confirmationPhase: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Compression Job")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Items to process:")
                        .foregroundStyle(.secondary)
                    Text("\(assets.count)")
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("iCloud downloads:")
                        .foregroundStyle(.secondary)
                    Text("\(cloudOnlyCount)")
                        .fontWeight(.medium)
                        .foregroundStyle(cloudOnlyCount > 0 ? .orange : .primary)
                }
                GridRow {
                    Text("Photo output:")
                        .foregroundStyle(.secondary)
                    Text("HEIC \u{2014} \(settings.photoQualityMode.displayName)")
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Video output:")
                        .foregroundStyle(.secondary)
                    Text("HEVC \u{2014} \(settings.videoQualityMode.displayName)")
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Resolution:")
                        .foregroundStyle(.secondary)
                    Text(settings.resolutionCap.displayName)
                        .fontWeight(.medium)
                }
            }
            .padding()
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text("Albums to create in Photos:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                AlbumBadge(name: settings.compressedAlbumName, systemImage: "checkmark.circle.fill", color: .green)
                AlbumBadge(name: settings.originalsAlbumName, systemImage: "archivebox.fill", color: .orange)
            }

            if cloudOnlyCount > 0 {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.orange)
                    Text("\(cloudOnlyCount) items are stored in iCloud and will be downloaded before compression. Make sure you\u{2019}re on Wi-Fi.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Compression", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Progress Phase

    private var progressPhase: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("Processing\u{2026}", systemImage: "bolt.fill")
                    .font(.title2.bold())
                Spacer()
                Text("\(engine.convertedCount) of \(engine.totalCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // 1. Total progress
            progressBar(
                label: "Total Progress",
                value: engine.overallProgress,
                color: .accentColor,
                detail: "\(Int(engine.overallProgress * 100))%"
            )

            Divider()

            // 2. Current conversion
            if let item = engine.currentItemProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        conversionPhaseIcon(item.phase)
                            .foregroundStyle(conversionPhaseColor(item.phase))
                            .frame(width: 16)
                        Text("Converting: \(item.filename)")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if item.fraction > 0 && item.fraction < 1 {
                        ProgressView(value: item.fraction)
                            .progressViewStyle(.linear)
                            .tint(conversionPhaseColor(item.phase))
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(conversionPhaseColor(item.phase))
                    }
                }
            }

            Divider()

            // 3. Download total progress
            let downloadProgress = engine.totalCount > 0
                ? Double(engine.downloadedCount) / Double(engine.totalCount)
                : 0.0

            progressBar(
                label: "Downloads",
                value: downloadProgress,
                color: .orange,
                detail: "\(engine.downloadedCount) of \(engine.totalCount)"
            )

            // 4. Current download
            if let downloadName = engine.currentDownloadFilename {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundStyle(.orange)
                            .frame(width: 16)
                        Text("Downloading: \(downloadName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.orange)
                }
            }

            // More Details toggle
            if !engine.pipelineItems.isEmpty {
                DisclosureGroup("More Details", isExpanded: $showingDetails) {
                    pipelineDetailsView
                }
                .font(.subheadline)
            }

            Spacer()

            // Cancel
            HStack {
                Spacer()
                Button("Cancel Job", role: .destructive, action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Progress Bar Helper

    private func progressBar(label: String, value: Double, color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressView(value: value)
                .progressViewStyle(.linear)
                .tint(color)
        }
    }

    // MARK: - Pipeline Details View

    private var pipelineDetailsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(engine.pipelineItems) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(pipelineItemColor(item.status))
                            .frame(width: 8, height: 8)

                        Text(item.filename)
                            .font(.caption)
                            .foregroundStyle(pipelineItemColor(item.status))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if item.status == .downloading || item.status == .converting {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxHeight: 200)
    }

    private func pipelineItemColor(_ status: CompressionEngine.PipelineItem.PipelineStatus) -> Color {
        switch status {
        case .pending:      return .secondary
        case .downloading:  return .secondary
        case .downloaded:   return .orange
        case .converting:   return .orange
        case .converted:    return .green
        case .skipped:      return .secondary
        case .failed:       return .red
        }
    }

    // MARK: - Summary Phase

    private func summaryPhase(_ summary: CompressionEngine.JobSummary) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .padding(.top, 8)

            Text("Compression Complete")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Compressed:")
                        .foregroundStyle(.secondary)
                    Text("\(summary.totalProcessed) items")
                        .fontWeight(.medium)
                }
                if summary.skipped > 0 {
                    GridRow {
                        Text("Skipped (already optimal):")
                            .foregroundStyle(.secondary)
                        Text("\(summary.skipped) items")
                            .fontWeight(.medium)
                    }
                }
                if summary.failed > 0 {
                    GridRow {
                        Text("Failed:")
                            .foregroundStyle(.secondary)
                        Text("\(summary.failed) items")
                            .fontWeight(.medium)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding()
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if summary.originalBytes > 0 {
                sizeSummary(summary)
            }

            Text("The compressed items have been added to your Photos library.\nTo reclaim space, delete the originals from the \u{201C}Originals \u{2014} Tidio\u{201D} album in Photos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !summary.errors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DisclosureGroup("Show Errors (\(summary.errors.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.errors, id: \.self) { error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Divider()

                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .foregroundStyle(.orange)
                        Text("Failed items were added to \u{201C}\(settings.failedAlbumName)\u{201D} in Photos. Select that album later to retry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    let failedAssets = summary.itemDetails.compactMap { $0.status == .failed ? $0.asset : nil }
                    if !failedAssets.isEmpty, let retry = onRetryFailed {
                        Button {
                            retry(failedAssets)
                        } label: {
                            Label("Retry Failed (\(failedAssets.count))", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(.red.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // More Details toggle
            if !summary.itemDetails.isEmpty {
                DisclosureGroup("More Details (\(summary.itemDetails.count) files)", isExpanded: $showingDetails) {
                    itemDetailsView(summary.itemDetails)
                }
                .padding()
                .background(.quinary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                if !summary.itemDetails.isEmpty {
                    Button {
                        exportCSV(summary.itemDetails)
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sizeSummary(_ summary: CompressionEngine.JobSummary) -> some View {
        let saved = summary.originalBytes - summary.compressedBytes
        let savingsPercent = Double(saved) / Double(summary.originalBytes) * 100

        return VStack(spacing: 10) {
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("Original")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.formatBytes(summary.originalBytes))
                        .font(.title3.monospacedDigit().weight(.medium))
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    Text("Compressed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.formatBytes(summary.compressedBytes))
                        .font(.title3.monospacedDigit().weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            if saved > 0 {
                Text("Saved \(Self.formatBytes(saved)) (\(String(format: "%.0f", savingsPercent))% smaller)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            } else if saved < 0 {
                Text("Size increased by \(Self.formatBytes(-saved))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.green.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Item Details

    private func itemDetailsView(_ items: [CompressionEngine.ItemDetail]) -> some View {
        #if os(macOS)
        Table(items) {
            TableColumn("File") { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.originalFilename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.status == .compressed && item.compressedFilename != item.originalFilename {
                        Text(item.compressedFilename)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .width(min: 120, ideal: 180)

            TableColumn("Original") { item in
                if item.status == .compressed {
                    Text(Self.formatBytes(item.originalBytes))
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.secondary)
                }
            }
            .width(70)

            TableColumn("New") { item in
                if item.status == .compressed {
                    Text(Self.formatBytes(item.compressedBytes))
                        .foregroundStyle(.green)
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.secondary)
                }
            }
            .width(70)

            TableColumn("Saved") { item in
                if item.status == .compressed {
                    Text("\(String(format: "%.0f", item.savingsPercent))%")
                        .foregroundStyle(item.savedBytes > 0 ? .green : .orange)
                } else {
                    Text(item.status.rawValue)
                        .foregroundStyle(item.status == .failed ? .red : .secondary)
                }
            }
            .width(min: 50, ideal: 60)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .font(.caption.monospacedDigit())
        .frame(height: min(CGFloat(items.count) * 28 + 32, 240))
        #else
        List(items) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.originalFilename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.status == .compressed {
                    HStack {
                        Text(Self.formatBytes(item.originalBytes))
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                        Text(Self.formatBytes(item.compressedBytes))
                            .foregroundStyle(.green)
                        Spacer()
                        Text("\(String(format: "%.0f", item.savingsPercent))%")
                            .foregroundStyle(item.savedBytes > 0 ? .green : .orange)
                    }
                    .font(.caption2.monospacedDigit())
                } else {
                    Text(item.status.rawValue)
                        .font(.caption2)
                        .foregroundStyle(item.status == .failed ? .red : .secondary)
                }
            }
        }
        .listStyle(.plain)
        .frame(height: min(CGFloat(items.count) * 48 + 16, 240))
        #endif
    }

    // MARK: - CSV Export

    private func exportCSV(_ items: [CompressionEngine.ItemDetail]) {
        var csv = "Original Filename,Compressed Filename,Original Size (bytes),Compressed Size (bytes),Saved (bytes),Savings (%),Status\n"
        for item in items {
            let origName = escapeCSV(item.originalFilename)
            let compName = escapeCSV(item.compressedFilename)
            let pct = String(format: "%.1f", item.savingsPercent)
            csv += "\(origName),\(compName),\(item.originalBytes),\(item.compressedBytes),\(item.savedBytes),\(pct),\(item.status.rawValue)\n"
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "Tidio-Report.csv"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        #else
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Tidio-Report.csv")
        try? csv.write(to: tempURL, atomically: true, encoding: .utf8)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let root = window.rootViewController else { return }
        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        activityVC.popoverPresentationController?.sourceView = window
        root.present(activityVC, animated: true)
        #endif
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    // MARK: - Failed Phase

    private func failedPhase(_ message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Compression Failed")
                .font(.title2.bold())

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Layout

    private var sheetWidth: CGFloat {
        if case .finished = engine.state, showingDetails {
            return 620
        }
        return 440
    }

    // MARK: - Helpers

    private var cloudOnlyCount: Int {
        assets.filter { asset in
            let resources = PHAssetResource.assetResources(for: asset)
            return resources.contains { ($0.value(forKey: "locallyAvailable") as? Bool) == false }
        }.count
    }

    // MARK: - Phase Styling

    private func conversionPhaseIcon(_ phase: CompressionEngine.ItemProgress.Phase) -> some View {
        switch phase {
        case .queued:      return Image(systemName: "clock")
        case .downloading: return Image(systemName: "icloud.and.arrow.down")
        case .compressing: return Image(systemName: "bolt.fill")
        case .saving:      return Image(systemName: "square.and.arrow.down")
        case .done:        return Image(systemName: "checkmark.circle.fill")
        case .skipped:     return Image(systemName: "forward.fill")
        case .failed:      return Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private func conversionPhaseColor(_ phase: CompressionEngine.ItemProgress.Phase) -> Color {
        switch phase {
        case .downloading: return .orange
        case .compressing: return .accentColor
        case .saving:      return .blue
        case .done:        return .green
        case .failed:      return .red
        default:           return .secondary
        }
    }
}

struct AlbumBadge: View {
    let name: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.caption)
            Text("\u{201C}\(name)\u{201D}")
                .font(.caption)
        }
    }
}
