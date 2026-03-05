import SwiftUI
import Photos

struct DuplicateReviewView: View {
    @ObservedObject var viewModel: DuplicateViewModel
    let settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Duplicate Review")
                    .font(.title2.bold())
                Spacer()
                Button("Close") {
                    viewModel.cancelScan()
                }
            }
            .padding()

            Divider()

            // Body
            switch viewModel.scanState {
            case .idle:
                EmptyView()

            case .scanning(let progress):
                scanningView(progress: progress)

            case .done(let groups):
                if groups.isEmpty {
                    noDuplicatesView
                } else {
                    reviewView(groups: groups)
                }

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.red)
                    Text("Scan Failed")
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(macOS)
        .frame(width: 680, height: 520)
        #endif
    }

    // MARK: - Scanning

    private func scanningView(progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .frame(width: 300)
            Text("Scanning for duplicates…  \(Int(progress * 100))%")
                .foregroundStyle(.secondary)
            Button("Cancel") { viewModel.cancelScan() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No Duplicates

    private var noDuplicatesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("No Exact Duplicates Found")
                .font(.headline)
            Text("All assets in the selected scope are unique.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review

    private func reviewView(groups: [DuplicateDetector.DuplicateGroup]) -> some View {
        VStack(spacing: 0) {
            // Stats bar
            HStack {
                Text("Group \(viewModel.currentGroupIndex + 1) of \(groups.count)  ·  \(totalDuplicateCount(groups)) duplicate items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.quinary)

            // Duplicate pair(s)
            if let group = viewModel.currentGroup {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(group.assets.enumerated()), id: \.offset) { index, asset in
                            DuplicateAssetCard(
                                asset: asset,
                                isKeeping: group.keepIndex == index,
                                onKeep: { viewModel.setKeep(index: index) }
                            )
                        }
                    }
                    .padding()
                }
            }

            Spacer()

            Divider()

            // Navigation + action
            HStack {
                Button("← Previous") { viewModel.previousGroup() }
                    .disabled(viewModel.currentGroupIndex == 0)

                Spacer()

                Button {
                    Task {
                        try? await viewModel.sendDuplicatesToAlbum(albumName: settings.duplicatesAlbumName)
                        viewModel.cancelScan()
                    }
                } label: {
                    Label("Send Duplicates to Album", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Next →") { viewModel.nextGroup() }
                    .disabled(viewModel.currentGroupIndex + 1 >= viewModel.totalGroupCount)
            }
            .padding()
        }
    }

    private func totalDuplicateCount(_ groups: [DuplicateDetector.DuplicateGroup]) -> Int {
        groups.reduce(0) { $0 + $1.assets.count - 1 }
    }
}

// MARK: - Duplicate Asset Card

struct DuplicateAssetCard: View {
    let asset: PHAsset
    let isKeeping: Bool
    let onKeep: () -> Void

    @State private var thumbnail: PlatformImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Group {
                    if let img = thumbnail {
                        #if os(macOS)
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                        #else
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                        #endif
                    } else {
                        #if os(macOS)
                        Rectangle().fill(Color(.windowBackgroundColor))
                        #else
                        Rectangle().fill(Color(.systemBackground))
                        #endif
                    }
                }
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isKeeping ? Color.green : Color.clear, lineWidth: 3)
                )

                if isKeeping {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .background(Circle().fill(.white))
                                .padding(6)
                        }
                        Spacer()
                    }
                    .frame(width: 200, height: 200)
                }
            }

            // Metadata
            VStack(alignment: .leading, spacing: 2) {
                if let date = asset.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 200, alignment: .leading)

            if isKeeping {
                Button("Keeping", action: onKeep)
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
            } else {
                Button("Keep This", action: onKeep)
                    .buttonStyle(.bordered)
                    .font(.caption)
            }
        }
        .task {
            thumbnail = await PhotoLibraryService.shared.loadThumbnail(
                for: asset, size: CGSize(width: 400, height: 400)
            )
        }
    }
}
