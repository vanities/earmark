import Foundation

/// An SMB share on a NAS or file server. The password lives in the Keychain, keyed by `id`.
struct NASServer: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int = 445
    var share: String
    /// Folder inside the share to treat as the library root ("downloads/books"). Empty = share root.
    var path: String
    var username: String
    var domain: String = ""
    var addedAt: Date

    var displayLocation: String {
        var location = "smb://\(host)"
        if port != 445 { location += ":\(port)" }
        location += "/\(share)"
        if !path.isEmpty { location += "/\(path)" }
        return location
    }

    /// Joins the library root with a path relative to it, SMB style.
    func remotePath(for relativePath: String) -> String {
        [path, relativePath].filter { !$0.isEmpty }.joined(separator: "/")
    }
}
