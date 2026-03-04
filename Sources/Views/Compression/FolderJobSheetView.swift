import SwiftUI
import UniformTypeIdentifiers

struct FolderJobSheetView: View {
    let files: [URL]
    let outputFolder: URL?
    let totalSourceBytes: Int64
    let imageCount: Int
    let videoCount: Int
    let settings: AppSettings
    @ObservedObject var engine: FolderCompressionEngine
    let onStart: () -> Void
    let onCancel: () -> Void
    let onDone: () -> Void

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
        .frame(width: sheetWidth)
        .frame(minHeight: 380)
        .interactiveDismissDisabled(engine.state == .running || engine.state == .paused)
        .animation(.easeInOut(duration: 0.25), value: showingDetails)
    }

    // MARK: - Confirmation Phase

    private var confirmationPhase: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Folder Compression")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Files to process:")
                        .foregroundStyle(.secondary)
                    Text("\(files.count)")
                        .fontWeight(.medium)
                }
                if imageCount > 0 {
                    GridRow {
                        Text("Photos:")
                            .foregroundStyle(.secondary)
                        Text("\(imageCount)")
                            .fontWeight(.medium)
                    }
                }
                if videoCount > 0 {
                    GridRow {
                        Text("Videos:")
                            .foregroundStyle(.secondary)
                        Text("\(videoCount)")
                            .fontWeight(.medium)
                    }
                }
                GridRow {
                    Text("Total size:")
                        .foregroundStyle(.secondary)
                    Text(Self.formatBytes(totalSourceBytes))
                        .fontWeight(.medium)
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

            if let output = outputFolder {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Output folder:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(output.path)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .padding()
                .background(.blue.opacity(0.06))
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
            HStack {
                Label("Processing\u{2026}", systemImage: "bolt.fill")
                    .font(.title2.bold())
                Spacer()
                Text("\(engine.convertedCount) of \(engine.totalCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Total progress
            progressBar(
                label: "Total Progress",
                value: engine.overallProgress,
                color: .accentColor,
                detail: "\(Int(engine.overallProgress * 100))%"
            )

            Divider()

            // Current conversion
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

            // Read progress
            let readProgress = engine.totalCount > 0
                ? Double(engine.downloadedCount) / Double(engine.totalCount)
                : 0.0

            progressBar(
                label: "Reading Files",
                value: readProgress,
                color: .orange,
                detail: "\(engine.downloadedCount) of \(engine.totalCount)"
            )

            // Current read
            if let readName = engine.currentDownloadFilename {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                    Text("Reading: \(readName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            // More Details
            if !engine.pipelineItems.isEmpty {
                DisclosureGroup("More Details", isExpanded: $showingDetails) {
                    pipelineDetailsView
                }
                .font(.subheadline)
            }

            Spacer()

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

    // MARK: - Pipeline Details

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
                    Text("\(summary.totalProcessed) files")
                        .fontWeight(.medium)
                }
                if summary.skipped > 0 {
                    GridRow {
                        Text("Skipped:")
                            .foregroundStyle(.secondary)
                        Text("\(summary.skipped) files")
                            .fontWeight(.medium)
                    }
                }
                if summary.failed > 0 {
                    GridRow {
                        Text("Failed:")
                            .foregroundStyle(.secondary)
                        Text("\(summary.failed) files")
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

            if let output = outputFolder {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                    Text("Compressed files saved to:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(output.path)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: output.path)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            if !summary.errors.isEmpty {
                DisclosureGroup("Show Errors (\(summary.errors.count))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.errors, id: \.self) { error in
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding()
                .background(.red.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // More Details
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

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "Tidio-Folder-Report.csv"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
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

    // MARK: - Phase Styling

    private func conversionPhaseIcon(_ phase: CompressionEngine.ItemProgress.Phase) -> some View {
        switch phase {
        case .queued:      return Image(systemName: "clock")
        case .downloading: return Image(systemName: "doc")
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
