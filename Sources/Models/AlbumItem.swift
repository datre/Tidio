import Foundation
import Photos

/// Wraps a PHAssetCollection (album or smart album) for display in the sidebar.
/// @unchecked Sendable: mutable state (isSelected) is only accessed from @MainActor.
final class AlbumItem: Identifiable, ObservableObject, @unchecked Sendable {
    let collection: PHAssetCollection
    let id: String
    let title: String
    let assetCount: Int
    let collectionType: PHAssetCollectionType
    let collectionSubtype: PHAssetCollectionSubtype

    @Published var isSelected: Bool = false

    init(collection: PHAssetCollection) {
        self.collection = collection
        self.id = collection.localIdentifier
        self.title = collection.localizedTitle ?? "Untitled"
        self.assetCount = collection.estimatedAssetCount == NSNotFound
            ? 0
            : collection.estimatedAssetCount
        self.collectionType = collection.assetCollectionType
        self.collectionSubtype = collection.assetCollectionSubtype
    }

    var sfSymbol: String {
        switch collectionSubtype {
        case .smartAlbumVideos:         "video.fill"
        case .smartAlbumScreenshots:    "camera.viewfinder"
        case .smartAlbumSelfPortraits:  "person.crop.circle"
        case .smartAlbumFavorites:      "heart.fill"
        case .smartAlbumPanoramas:      "panorama.fill"
        case .smartAlbumBursts:         "burst.fill"
        case .smartAlbumSlomoVideos:    "slowmo"
        case .smartAlbumTimelapses:     "timelapse"
        case .smartAlbumLivePhotos:     "livephoto"
        default:
            collectionType == .smartAlbum ? "wand.and.sparkles" : "rectangle.stack.fill"
        }
    }
}

// MARK: - Library Section

/// Top-level grouping shown in the sidebar.
struct LibrarySection: Identifiable {
    let id: String
    let title: String
    var albums: [AlbumItem]

    static func makeSections(from albums: [AlbumItem]) -> [LibrarySection] {
        let user = albums.filter { $0.collectionType == .album }
        let smart = albums.filter { $0.collectionType == .smartAlbum }
        var sections: [LibrarySection] = []
        if !user.isEmpty  { sections.append(LibrarySection(id: "user",  title: "My Albums",    albums: user)) }
        if !smart.isEmpty { sections.append(LibrarySection(id: "smart", title: "Smart Albums", albums: smart)) }
        return sections
    }
}
