#if os(macOS)
import Foundation
import AppKit

@MainActor
final class FolderCompressionViewModel: ObservableObject {

    let engine = FolderCompressionEngine()

    @Published var isShowingJobSheet: Bool = false
    @Published var filesToProcess: [URL] = []
    @Published var outputFolder: URL?
    @Published var sourceFolder: URL?
    @Published var totalSourceBytes: Int64 = 0

    func openFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Folder to Compress"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let files = FolderCompressionEngine.scanFolder(folderURL)
        guard !files.isEmpty else { return }

        filesToProcess = files
        sourceFolder = folderURL
        outputFolder = folderURL.appendingPathComponent("Compressed")

        // Calculate total source size
        totalSourceBytes = files.reduce(into: Int64(0)) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            total += size
        }

        isShowingJobSheet = true
    }

    func startJob(settings: AppSettings) {
        guard let output = outputFolder else { return }
        Task {
            await engine.run(
                files: filesToProcess,
                outputFolder: output,
                settings: settings
            )
        }
    }

    func cancelJob() {
        engine.cancel()
        isShowingJobSheet = false
    }

    func dismissSheet() {
        engine.reset()
        filesToProcess = []
        outputFolder = nil
        sourceFolder = nil
        totalSourceBytes = 0
        isShowingJobSheet = false
    }

    var isRunning: Bool {
        if case .running = engine.state { return true }
        return false
    }

    var imageCount: Int {
        filesToProcess.filter { FolderCompressionEngine.mediaKind(for: $0) == .some(.image) }.count
    }

    var videoCount: Int {
        filesToProcess.filter { FolderCompressionEngine.mediaKind(for: $0) == .some(.video) }.count
    }
}
#endif
