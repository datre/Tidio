import Foundation
import Photos

@MainActor
final class DuplicateViewModel: ObservableObject {

    enum ScanState {
        case idle
        case scanning(progress: Double)
        case done(groups: [DuplicateDetector.DuplicateGroup])
        case failed(String)
    }

    @Published var scanState: ScanState = .idle
    @Published var currentGroupIndex: Int = 0
    @Published var resolvedGroups: [DuplicateDetector.DuplicateGroup] = []

    private let detector = DuplicateDetector()
    private var scanTask: Task<Void, Never>?

    // MARK: - Scanning

    func startScan(assets: [PHAsset]) {
        scanTask?.cancel()
        scanTask = Task {
            do {
                let groups = try await detector.findDuplicates(in: assets) { progress in
                    let frac = progress.fraction
                    Task { @MainActor in
                        self.scanState = .scanning(progress: frac)
                    }
                }
                resolvedGroups = groups
                scanState = .done(groups: groups)
            } catch is CancellationError {
                scanState = .idle
            } catch {
                scanState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanState = .idle
    }

    // MARK: - Duplicate Review

    var currentGroup: DuplicateDetector.DuplicateGroup? {
        guard case .done(let groups) = scanState,
              currentGroupIndex < groups.count else { return nil }
        return groups[currentGroupIndex]
    }

    var totalGroupCount: Int {
        guard case .done(let groups) = scanState else { return 0 }
        return groups.count
    }

    func setKeep(index: Int) {
        guard case .done(var groups) = scanState,
              currentGroupIndex < groups.count else { return }
        groups[currentGroupIndex].keepIndex = index
        resolvedGroups = groups
        scanState = .done(groups: groups)
    }

    func nextGroup() {
        guard currentGroupIndex + 1 < totalGroupCount else { return }
        currentGroupIndex += 1
    }

    func previousGroup() {
        guard currentGroupIndex > 0 else { return }
        currentGroupIndex -= 1
    }

    // MARK: - Album Action

    /// Adds all non-kept duplicates to the duplicates album.
    func sendDuplicatesToAlbum(albumName: String) async throws {
        guard case .done(let groups) = scanState else { return }

        let album = try await PhotoLibraryService.shared.findOrCreateAlbum(named: albumName)

        var duplicateAssets: [PHAsset] = []
        for group in groups {
            for (index, asset) in group.assets.enumerated() {
                if index != group.keepIndex {
                    duplicateAssets.append(asset)
                }
            }
        }

        try await PhotoLibraryService.shared.addAssets(duplicateAssets, to: album)
    }
}
