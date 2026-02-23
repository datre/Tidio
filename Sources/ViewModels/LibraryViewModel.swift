import Foundation
import Photos
import SwiftUI

/// Main view model — drives the sidebar, grid, and authorization state.
@MainActor
final class LibraryViewModel: ObservableObject {

    // MARK: - Auth

    enum AuthState {
        case unknown
        case authorized
        case limited
        case denied
    }

    @Published var authState: AuthState = .unknown

    // MARK: - Library Content

    @Published var sections: [LibrarySection] = []
    @Published var selectedAlbum: AlbumItem?       // album currently shown in grid
    @Published var displayedAssets: [AssetItem] = []
    @Published var isLoadingAssets: Bool = false

    // MARK: - Selection

    @Published var selection = SelectionModel()

    // MARK: - Init

    init() {
        Task { await checkAuthorization() }
    }

    // MARK: - Authorization

    func checkAuthorization() async {
        // requestAuthorization returns immediately if already determined,
        // and shows the system prompt if status is .notDetermined.
        await requestAuthorization()
    }

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        applyAuthStatus(status)
        if status == .authorized || status == .limited {
            await loadLibrary()
        }
    }

    private func applyAuthStatus(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized:           authState = .authorized
        case .limited:              authState = .limited
        case .denied, .restricted:  authState = .denied
        default:                    authState = .unknown
        }
    }

    // MARK: - Load Library

    func loadLibrary() async {
        let albums = await Task.detached(priority: .userInitiated) {
            await PhotoLibraryService.shared.fetchAllAlbums()
        }.value
        sections = LibrarySection.makeSections(from: albums)
    }

    // MARK: - Album Selection (sidebar tap)

    func selectAlbum(_ album: AlbumItem) {
        selectedAlbum = album
        Task { await loadAssets(for: album) }
    }

    func selectAllPhotos() {
        selectedAlbum = nil
        Task { await loadAllAssets() }
    }

    private func loadAssets(for album: AlbumItem) async {
        isLoadingAssets = true
        let assets = await Task.detached(priority: .userInitiated) {
            await PhotoLibraryService.shared.fetchAssets(in: album.collection)
        }.value
        displayedAssets = assets
        isLoadingAssets = false
        await loadThumbnails()
    }

    private func loadAllAssets() async {
        isLoadingAssets = true
        let assets = await Task.detached(priority: .userInitiated) {
            await PhotoLibraryService.shared.fetchAllAssets()
        }.value
        displayedAssets = assets
        isLoadingAssets = false
        await loadThumbnails()
    }

    // MARK: - Thumbnail Loading

    /// Loads thumbnails for the currently displayed assets in batches.
    private func loadThumbnails() async {
        let size = CGSize(width: 200, height: 200)
        // Process in batches of 20 to keep memory manageable
        let batches = stride(from: 0, to: displayedAssets.count, by: 20).map {
            Array(displayedAssets[$0..<min($0 + 20, displayedAssets.count)])
        }
        for batch in batches {
            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask {
                        let image = await PhotoLibraryService.shared.loadThumbnail(
                            for: item.asset, size: size
                        )
                        await MainActor.run { item.thumbnail = image }
                    }
                }
            }
        }
    }

    // MARK: - Scope Summary (for status bar)

    var scopeSummaryText: String {
        guard selection.hasSelection else { return "No selection" }
        let albumCount = selection.selectedAlbumIDs.count
        let assetCount = selection.selectedAssetIDs.count
        var parts: [String] = []
        if selection.includeAllPhotos { return "Entire library selected" }
        if albumCount > 0 { parts.append("\(albumCount) album\(albumCount == 1 ? "" : "s")") }
        if assetCount > 0 { parts.append("\(assetCount) individual item\(assetCount == 1 ? "" : "s")") }
        return parts.joined(separator: " + ") + " selected"
    }
}
