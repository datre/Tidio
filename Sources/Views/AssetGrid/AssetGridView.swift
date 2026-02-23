import SwiftUI

struct AssetGridView: View {
    let assets: [AssetItem]
    @ObservedObject var selection: SelectionModel
    let isLoading: Bool

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 4)]

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if assets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(assets) { item in
                            AssetThumbnailCell(
                                item: item,
                                isSelected: selection.selectedAssetIDs.contains(item.id),
                                onToggle: { selection.toggleAsset(item) }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
        if assets.isEmpty { return "Photos" }
        return "\(assets.count) item\(assets.count == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select an album from the sidebar")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Thumbnail Cell

struct AssetThumbnailCell: View {
    @ObservedObject var item: AssetItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Thumbnail
            Group {
                if let image = item.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(.windowBackgroundColor))
                        .overlay(ProgressView().scaleEffect(0.5))
                }
            }
            .frame(width: 130, height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            // Selection checkbox
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(4)

            // Video badge
            if item.mediaType == .video, let dur = item.formattedDuration {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(dur)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }
                }
                .frame(width: 130, height: 130)
            }

            // iCloud badge
            if item.isCloudOnly {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "icloud")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                        Spacer()
                    }
                }
                .frame(width: 130, height: 130)
            }
        }
        .onTapGesture { onToggle() }
        .help(item.sourceFilename ?? "")
    }
}
