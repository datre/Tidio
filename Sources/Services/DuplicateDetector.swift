import Foundation
import Photos
import CryptoKit

/// Finds exact duplicate assets using SHA-256 content hashing.
actor DuplicateDetector {

    // MARK: - Public API

    struct DuplicateGroup: Identifiable {
        let id = UUID()
        let assets: [PHAsset]       // 2+ assets with identical content
        var keepIndex: Int = 0      // index of the asset the user wants to keep
    }

    struct Progress: Sendable {
        let completed: Int
        let total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    /// Scans assets and returns groups of exact duplicates.
    /// `onProgress` is called on each hashed asset.
    func findDuplicates(
        in assets: [PHAsset],
        onProgress: @Sendable (Progress) -> Void
    ) async throws -> [DuplicateGroup] {
        var hashMap: [String: [PHAsset]] = [:]
        let total = assets.count

        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()

            if let hash = await computeHash(for: asset) {
                if hashMap[hash] != nil {
                    hashMap[hash]!.append(asset)
                } else {
                    hashMap[hash] = [asset]
                }
            }

            onProgress(Progress(completed: index + 1, total: total))
        }

        // Only groups with 2+ assets are duplicates
        return hashMap
            .filter { $0.value.count >= 2 }
            .map { DuplicateGroup(assets: $0.value) }
            .sorted { $0.assets.count > $1.assets.count }
    }

    // MARK: - Hashing

    private func computeHash(for asset: PHAsset) async -> String? {
        guard let data = await fetchRawData(for: asset) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func fetchRawData(for asset: PHAsset) async -> Data? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the original resource to hash
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video })
                             ?? resources.first
        else { return nil }

        return await withCheckedContinuation { continuation in
            var collectedData = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    collectedData.append(chunk)
                },
                completionHandler: { error in
                    if error != nil {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: collectedData)
                    }
                }
            )
        }
    }
}
