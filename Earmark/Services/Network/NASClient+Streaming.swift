import AVFoundation
import Foundation
import ShelfKit

/// The one thing Earmark needs from SMB that Mango doesn't: an `AVURLAsset` that streams a
/// track through `SMBResourceLoader`. The client itself is ShelfKit's, shared with Mango.
extension NASClient {
    static let scheme = "earmark-smb"

    static func assetURL(serverID: UUID, relativePath: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = serverID.uuidString.lowercased()
        components.path = "/" + relativePath
        guard let url = components.url else {
            preconditionFailure("unrepresentable remote path: \(relativePath)")
        }
        return url
    }

    /// An asset that streams from this server through `SMBResourceLoader`. Keep the loader
    /// alive for as long as the asset is in use.
    func makeAsset(relativePath: String, size: Int64, preciseTiming: Bool = false, containerHint: String? = nil) -> (asset: AVURLAsset, loader: SMBResourceLoader) {
        let url = Self.assetURL(serverID: server.id, relativePath: relativePath)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: preciseTiming])
        let loader = SMBResourceLoader(client: self, relativePath: relativePath, fileSize: size, containerHint: containerHint)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }
}
