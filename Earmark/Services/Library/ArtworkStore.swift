import CryptoKit
import Foundation
import ImageIO
import UIKit
import os

/// Downscaled cover thumbnails in the Caches directory — the only files Earmark
/// ever writes about the user's books. Safe to delete at any time.
final class ArtworkStore: @unchecked Sendable {
    static let shared = ArtworkStore()

    let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    private let maxPixelSize = 900

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.directory = caches.appending(path: "Artwork", directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        memory.countLimit = 200
    }

    func id(for key: String) -> String {
        Self.hex(SHA256.hash(data: Data(key.utf8)))
    }

    /// Id for a user-chosen cover. It changes with the image, so every view keyed on `Book.artworkID`
    /// reloads when a cover is replaced — a fixed id kept the old cover on screen until the view was rebuilt.
    func customID(for bookID: String, imageData: Data) -> String {
        var sha = SHA256()
        sha.update(data: Data("\(bookID)|custom|".utf8))
        sha.update(data: imageData)
        return Self.hex(sha.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for id: String) -> URL {
        directory.appending(path: "\(id).jpg")
    }

    func hasImage(id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    /// Decodes, downsamples, and writes a JPEG thumbnail. Returns false for undecodable data.
    @discardableResult
    func store(imageData: Data, id: String) -> Bool {
        let sw = Stopwatch()
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            Logger.artwork.error("[artwork] undecodable image data bytes=\(imageData.count)")
            return false
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            Logger.artwork.error("[artwork] thumbnail creation failed")
            return false
        }
        let image = UIImage(cgImage: cgImage)
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try jpeg.write(to: fileURL(for: id), options: .atomic)
            memory.setObject(image, forKey: id as NSString)
            Logger.artwork.info("[artwork] stored id=\(id, privacy: .public) \(Int(image.size.width))x\(Int(image.size.height)) bytes=\(jpeg.count) in \(sw.ms, format: .fixed(precision: 0))ms")
            return true
        } catch {
            Logger.artwork.error("[artwork] write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func image(for id: String?) -> UIImage? {
        guard let id else { return nil }
        if let cached = memory.object(forKey: id as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: fileURL(for: id).path) else { return nil }
        memory.setObject(image, forKey: id as NSString)
        return image
    }

    func loadImage(for id: String?) async -> UIImage? {
        guard let id else { return nil }
        if let cached = memory.object(forKey: id as NSString) { return cached }
        return await Task.detached(priority: .utility) { [self] in
            self.image(for: id)
        }.value
    }

    /// Drops one thumbnail (e.g. a custom cover that was just replaced) from memory and disk.
    func remove(id: String) {
        memory.removeObject(forKey: id as NSString)
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            Logger.artwork.info("[artwork] removed id=\(id, privacy: .public)")
        } catch {
            Logger.artwork.notice("[artwork] remove failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Logger.artwork.info("[artwork] cache cleared")
    }
}
