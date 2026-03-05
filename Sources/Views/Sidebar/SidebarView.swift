import SwiftUI
import Photos

struct SidebarView: View {
    let sections: [LibrarySection]
    @ObservedObject var selection: SelectionModel
    let onSelectAllPhotos: () -> Void
    let onSelectAlbum: (AlbumItem) -> Void
    var onOpenFolder: (() -> Void)? = nil

    var body: some View {
        List {
            // All Photos row
            allPhotosRow

            // Album sections
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.albums) { album in
                        AlbumRow(
                            album: album,
                            isChecked: selection.selectedAlbumIDs.contains(album.id),
                            onToggleCheck: { selection.toggleAlbum(album) },
                            onTap: { onSelectAlbum(album) }
                        )
                    }
                }
            }

            // Folder section (macOS only)
            #if os(macOS)
            if let onOpenFolder {
                Section("Folders") {
                    Button {
                        onOpenFolder()
                    } label: {
                        Label("Open Folder\u{2026}", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif
        }
        .listStyle(.sidebar)
        .navigationTitle("Tidio")
    }

    private var allPhotosRow: some View {
        HStack {
            Toggle("", isOn: $selection.includeAllPhotos)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .labelsHidden()
            Button {
                onSelectAllPhotos()
            } label: {
                Label("All Photos", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Album Row

struct AlbumRow: View {
    let album: AlbumItem
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in onToggleCheck() }))
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .labelsHidden()

            Button {
                onTap()
            } label: {
                Label {
                    HStack {
                        Text(album.title)
                            .lineLimit(1)
                        Spacer()
                        if album.assetCount > 0 {
                            Text("\(album.assetCount)")
                                .foregroundStyle(.tertiary)
                                .font(.footnote)
                        }
                    }
                } icon: {
                    Image(systemName: album.sfSymbol)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
