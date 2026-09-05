import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os

/// Feeds AVFoundation byte ranges read over SMB, so AVPlayer (and metadata loading) work on
/// files that never touch the disk.
final class SMBResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.vanities.earmark.smb-loader")

    private let client: NASClient
    private let relativePath: String
    private let fileSize: Int64
    private let contentType: String
    private let inflight = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: (task: Task<Void, Never>, cancelled: OSAllocatedUnfairLock<Bool>)]())

    init(client: NASClient, relativePath: String, fileSize: Int64, containerHint: String? = nil) {
        self.client = client
        self.relativePath = relativePath
        self.fileSize = fileSize
        // Prefer what the scanner sniffed from the header (files are often misnamed), and never
        // advertise Apple's *protected* audiobook type for plain .m4b files.
        let ext = containerHint ?? (relativePath as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4b", "m4a", "aac": contentType = "public.mpeg-4-audio"
        case "mp3": contentType = UTType.mp3.identifier
        case "flac": contentType = "org.xiph.flac"
        case "wav": contentType = UTType.wav.identifier
        default: contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.audio.identifier
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = fileSize
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let offset = dataRequest.currentOffset
        let alreadyDelivered = offset - dataRequest.requestedOffset
        let wanted = dataRequest.requestsAllDataToEndOfResource ? fileSize - offset : Int64(dataRequest.requestedLength) - alreadyDelivered
        let length = max(0, min(wanted, fileSize - offset))
        let key = ObjectIdentifier(loadingRequest)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let client = client
        let path = relativePath
        Logger.nas.debug("[smb-loader] request offset=\(offset) length=\(length) file=\((path as NSString).lastPathComponent, privacy: .public)")

        let task = Task.detached(priority: .userInitiated) { [inflight] in
            do {
                if length > 0 {
                    try await client.read(path, offset: offset, length: length) { chunk in
                        if cancelled.withLock({ $0 }) { return false }
                        dataRequest.respond(with: chunk)
                        return true
                    }
                }
                if !cancelled.withLock({ $0 }) { loadingRequest.finishLoading() }
            } catch {
                if !cancelled.withLock({ $0 }) {
                    Logger.nas.error("[smb-loader] read failed offset=\(offset): \(error.localizedDescription, privacy: .public)")
                    loadingRequest.finishLoading(with: error)
                }
            }
            inflight.withLock { _ = $0.removeValue(forKey: key) }
        }
        inflight.withLock { $0[key] = (task, cancelled) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        if let entry = inflight.withLock({ $0.removeValue(forKey: key) }) {
            entry.cancelled.withLock { $0 = true }
            entry.task.cancel()
        }
    }
}
