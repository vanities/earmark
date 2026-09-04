import Foundation

/// A place Earmark reads audiobooks from. Files are never copied: a source is a
/// security-scoped bookmark to a folder (or single file) the user picked, or the
/// app's own Documents folder ("On My iPhone › Earmark" in the Files app).
struct LibrarySource: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A folder picked in the Files browser (iCloud Drive, On My iPhone, SMB share, other apps).
        case folder
        /// A single audio file handed to us via "Open in Earmark".
        case file
        /// The app's own Documents directory. Always present, cannot be removed.
        case appDocuments
        /// A folder on an SMB share (NAS). Streams on demand; books can be downloaded locally.
        case smb
    }

    let id: UUID
    var kind: Kind
    var displayName: String
    /// Security-scoped bookmark data. `nil` for `.appDocuments`.
    var bookmark: Data?
    var addedAt: Date
    var lastScanAt: Date?
    var lastScanBookCount: Int?
    var lastScanFileCount: Int?
    var lastError: String?
    /// For `.smb` sources: the server this folder lives on.
    var serverID: UUID?

    var isRemovable: Bool { kind != .appDocuments }
    var isRemote: Bool { kind == .smb }

    var systemImage: String {
        switch kind {
        case .folder: "folder.fill"
        case .file: "doc.fill"
        case .appDocuments: "iphone"
        case .smb: "externaldrive.connected.to.line.below"
        }
    }
}
