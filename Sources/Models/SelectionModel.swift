import Foundation
import Photos

/// Tracks what the user has selected: albums (checked in sidebar) and
/// individual asset IDs (checked in the grid). The effective scope is
/// the union of both.
@MainActor
final class SelectionModel: ObservableObject {
    @Published var selectedAlbumIDs: Set<String> = []
    @Published var selectedAssetIDs: Set<String> = []

    // MARK: - Smart Filters

    @Published var filterMediaType: FilterMediaType = .all
    @Published var filterFormat: FilterFormat = .all
    @Published var filterMinSizeMB: Double? = nil
    @Published var filterMinPixelWidth: Int? = nil
    @Published var filterDateRange: ClosedRange<Date>? = nil
    /// Substring match against EXIF camera make + model (case-insensitive). Empty = no filter.
    @Published var filterCameraModel: String = ""

    // MARK: - All Photos mode

    @Published var includeAllPhotos: Bool = false

    var hasSelection: Bool {
        includeAllPhotos || !selectedAlbumIDs.isEmpty || !selectedAssetIDs.isEmpty
    }

    func toggleAlbum(_ album: AlbumItem) {
        if selectedAlbumIDs.contains(album.id) {
            selectedAlbumIDs.remove(album.id)
        } else {
            selectedAlbumIDs.insert(album.id)
        }
    }

    func toggleAsset(_ asset: AssetItem) {
        if selectedAssetIDs.contains(asset.id) {
            selectedAssetIDs.remove(asset.id)
        } else {
            selectedAssetIDs.insert(asset.id)
        }
    }

    func clearAll() {
        selectedAlbumIDs.removeAll()
        selectedAssetIDs.removeAll()
        filterCameraModel = ""
        includeAllPhotos = false
    }

    /// Returns a PHFetchResult that covers the current selection scope,
    /// applying smart filters. Called just before starting a job.
    func buildFetchResult() -> PHFetchResult<PHAsset> {
        let fetchOptions = makeFetchOptions()

        if includeAllPhotos {
            return PHAsset.fetchAssets(with: fetchOptions)
        }

        // Union: collect all asset IDs from selected albums + individually selected assets
        var allAssets: [PHAsset] = []

        // Assets from selected albums
        for albumID in selectedAlbumIDs {
            let collectionResult = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil
            )
            if let collection = collectionResult.firstObject {
                let albumAssets = PHAsset.fetchAssets(in: collection, options: fetchOptions)
                albumAssets.enumerateObjects { asset, _, _ in allAssets.append(asset) }
            }
        }

        // Individually selected assets
        if !selectedAssetIDs.isEmpty {
            let individualResult = PHAsset.fetchAssets(
                withLocalIdentifiers: Array(selectedAssetIDs), options: fetchOptions
            )
            individualResult.enumerateObjects { asset, _, _ in allAssets.append(asset) }
        }

        // De-duplicate by localIdentifier
        var seen = Set<String>()
        let unique = allAssets.filter { seen.insert($0.localIdentifier).inserted }

        // Build a compound fetch from the unique identifiers
        return PHAsset.fetchAssets(withLocalIdentifiers: unique.map(\.localIdentifier), options: nil)
    }

    private func makeFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []

        // Media type filter
        switch filterMediaType {
        case .photosOnly:
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        case .videosOnly:
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        case .all:
            break
        }

        // Date range filter
        if let range = filterDateRange {
            predicates.append(NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                          range.lowerBound as NSDate, range.upperBound as NSDate))
        }

        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }
}

// MARK: - Filter Types

enum FilterMediaType: String, CaseIterable, Identifiable {
    case all        = "all"
    case photosOnly = "photos"
    case videosOnly = "videos"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all:        "Photos & Videos"
        case .photosOnly: "Photos Only"
        case .videosOnly: "Videos Only"
        }
    }
}

enum FilterFormat: String, CaseIterable, Identifiable {
    case all           = "all"
    case jpegOnly      = "jpeg"
    case h264Only      = "h264"
    case excludeHEIC   = "excludeHEIC"
    case excludeHEVC   = "excludeHEVC"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all:          "All Formats"
        case .jpegOnly:     "JPEG Only"
        case .h264Only:     "H.264 Video Only"
        case .excludeHEIC:  "Exclude Already-HEIC"
        case .excludeHEVC:  "Exclude Already-HEVC"
        }
    }
}
