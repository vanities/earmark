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

    // A user-chosen cover needs a new id whenever it changes: views reload art only when
    // `Book.artworkID` changes, so a fixed id kept the old cover on screen until the view was rebuilt.

    /// Id for a cover found online. It depends only on the book and the URL, so every device can tell
    /// whether it already holds the synced choice (see `CoverSync.plan`).
    static func customID(for bookID: String, sourceURL: URL) -> String {
        hex(SHA256.hash(data: Data("\(bookID)|custom|\(sourceURL.absoluteString)".utf8)))
    }

    /// Id for a cover picked from Photos or Files, which has no URL to name it by.
    static func customID(for bookID: String, imageData: Data) -> String {
        var sha = SHA256()
        sha.update(data: Data("\(bookID)|custom|".utf8))
        sha.update(data: imageData)
        return hex(sha.finalize())
    }

    /// A short content hash, for telling whether an image file is still the one Earmark wrote.
    static func fingerprint(of data: Data) -> String {
        hex(SHA256.hash(data: data))
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
        guard let cgImage = Self.downsampled(imageData, maxPixelSize: maxPixelSize) else { return false }
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

    /// The image as a JPEG at most `maxPixelSize` on its long side — what Earmark writes next to the
    /// audio, so a 12-megapixel HEIC from Photos doesn't become a 5 MB cover.jpg.
    static func coverJPEG(from data: Data, maxPixelSize: Int = 1400) -> Data? {
        downsampled(data, maxPixelSize: maxPixelSize).flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.9) }
    }

    private static func downsampled(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            Logger.artwork.error("[artwork] undecodable image data bytes=\(data.count)")
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            Logger.artwork.error("[artwork] thumbnail creation failed bytes=\(data.count)")
            return nil
        }
        return image
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
        guard hasImage(id: id) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            Logger.artwork.info("[artwork] removed id=\(id, privacy: .public)")
        } catch {
            Logger.artwork.notice("[artwork] remove failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-files a thumbnail under a new id (a custom cover from an older build, whose id scheme changed).
    @discardableResult
    func move(from oldID: String, to newID: String) -> Bool {
        guard oldID != newID else { return true }
        do {
            try? FileManager.default.removeItem(at: fileURL(for: newID))
            try FileManager.default.moveItem(at: fileURL(for: oldID), to: fileURL(for: newID))
            if let image = memory.object(forKey: oldID as NSString) { memory.setObject(image, forKey: newID as NSString) }
            memory.removeObject(forKey: oldID as NSString)
            Logger.artwork.info("[artwork] moved id=\(oldID, privacy: .public) → \(newID, privacy: .public)")
            return true
        } catch {
            Logger.artwork.error("[artwork] move failed id=\(oldID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func removeAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Logger.artwork.info("[artwork] cache cleared")
    }
}
