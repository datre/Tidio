import Foundation
import Photos

@MainActor
final class CompressionViewModel: ObservableObject {

    @Published var isShowingJobSheet: Bool = false
    @Published var assetsToProcess: [PHAsset] = []

    let engine = CompressionEngine()

    // Camera model filter captured at prepare() time
    private var cameraModelFilter: String? = nil

    func prepare(from selection: SelectionModel) {
        let result = selection.buildFetchResult()
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        assetsToProcess = assets
        cameraModelFilter = selection.filterCameraModel.isEmpty ? nil : selection.filterCameraModel
        isShowingJobSheet = true
    }

    func startJob(settings: AppSettings) {
        // Sheet stays open — progress is shown inside it
        Task {
            await engine.run(
                assets: assetsToProcess,
                settings: settings,
                cameraModelFilter: cameraModelFilter
            )
        }
    }

    func cancelJob() {
        engine.cancel()
        isShowingJobSheet = false
    }

    /// Called when the user taps "Done" after completion or failure.
    func dismissSheet() {
        engine.reset()
        assetsToProcess = []
        cameraModelFilter = nil
        isShowingJobSheet = false
    }

    func retryFailed(assets: [PHAsset], settings: AppSettings) {
        engine.reset()
        assetsToProcess = assets
        Task {
            await engine.run(
                assets: assets,
                settings: settings,
                cameraModelFilter: cameraModelFilter
            )
        }
    }

    var isRunning: Bool {
        if case .running = engine.state { return true }
        return false
    }

    var summary: CompressionEngine.JobSummary? {
        if case .finished(let s) = engine.state { return s }
        return nil
    }
}
