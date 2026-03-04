import SwiftUI
import Photos

struct ContentView: View {
    @EnvironmentObject var library: LibraryViewModel
    @StateObject private var compressionVM = CompressionViewModel()
    @StateObject private var duplicateVM = DuplicateViewModel()
    @StateObject private var folderVM = FolderCompressionViewModel()
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            switch library.authState {
            case .unknown:
                ProgressView("Checking photo library access…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .denied:
                PermissionDeniedView()

            case .authorized, .limited:
                mainInterface

            @unknown default:
                EmptyView()
            }
        }
        .sheet(isPresented: $compressionVM.isShowingJobSheet) {
            JobSheetView(
                assets: compressionVM.assetsToProcess,
                settings: settings,
                engine: compressionVM.engine,
                onStart: { compressionVM.startJob(settings: settings) },
                onCancel: { compressionVM.cancelJob() },
                onDone: { compressionVM.dismissSheet() },
                onRetryFailed: { failedAssets in
                    compressionVM.retryFailed(assets: failedAssets, settings: settings)
                }
            )
        }
        .sheet(isPresented: $folderVM.isShowingJobSheet) {
            FolderJobSheetView(
                files: folderVM.filesToProcess,
                outputFolder: folderVM.outputFolder,
                totalSourceBytes: folderVM.totalSourceBytes,
                imageCount: folderVM.imageCount,
                videoCount: folderVM.videoCount,
                settings: settings,
                engine: folderVM.engine,
                onStart: { folderVM.startJob(settings: settings) },
                onCancel: { folderVM.cancelJob() },
                onDone: { folderVM.dismissSheet() }
            )
        }
    }

    // MARK: - Main Interface

    @ViewBuilder
    private var mainInterface: some View {
        NavigationSplitView {
            SidebarView(
                sections: library.sections,
                selection: library.selection,
                onSelectAllPhotos: { library.selectAllPhotos() },
                onSelectAlbum: { library.selectAlbum($0) },
                onOpenFolder: { folderVM.openFolder() }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } content: {
            AssetGridView(
                assets: library.displayedAssets,
                selection: library.selection,
                isLoading: library.isLoadingAssets
            )
            .navigationSplitViewColumnWidth(min: 400, ideal: 640)
        } detail: {
            InspectorView(
                selection: library.selection,
                onStartCompression: {
                    compressionVM.prepare(from: library.selection)
                },
                onScanDuplicates: {
                    let result = library.selection.buildFetchResult()
                    var assets: [PHAsset] = []
                    result.enumerateObjects { a, _, _ in assets.append(a) }
                    duplicateVM.startScan(assets: assets)
                }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 260)
        }
        .toolbar { toolbarItems }
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(isPresented: isDuplicateScanVisible) {
            DuplicateReviewView(viewModel: duplicateVM, settings: settings)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                compressionVM.prepare(from: library.selection)
            } label: {
                Label("Start Compression", systemImage: "bolt.fill")
            }
            .disabled(!library.selection.hasSelection || compressionVM.isRunning)
        }
        ToolbarItem {
            Button {
                let result = library.selection.buildFetchResult()
                var assets: [PHAsset] = []
                result.enumerateObjects { a, _, _ in assets.append(a) }
                duplicateVM.startScan(assets: assets)
            } label: {
                Label("Scan for Duplicates", systemImage: "doc.on.doc")
            }
            .disabled(!library.selection.hasSelection)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text(library.scopeSummaryText)
                .foregroundStyle(.secondary)
                .font(.footnote)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Duplicate Sheet Visibility

    private var isDuplicateScanVisible: Binding<Bool> {
        Binding(
            get: {
                if case .scanning = duplicateVM.scanState { return true }
                if case .done = duplicateVM.scanState { return true }
                return false
            },
            set: { if !$0 { duplicateVM.cancelScan() } }
        )
    }
}

// MARK: - Permission Denied

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Photo Library Access Required")
                .font(.headline)
            Text("Tidio needs access to your photo library.\nPlease grant access in System Settings → Privacy & Security → Photos.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
