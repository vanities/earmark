import SwiftUI
import ShelfKit

/// Connects an SMB share (Unraid, Synology, a Mac…) as a library folder: ShelfKit's form, the
/// same one Mango uses. The share is added only once it answers; the password goes to the
/// Keychain.
struct NASSetupView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        NASSetupForm(
            folderPlaceholder: "audiobooks",
            footer: "Earmark indexes this folder over SMB. Books stream from the NAS when you're on its network, and any book can be downloaded to this \(DeviceStorage.device)."
        ) { server, password in
            try await library.addNAS(server, password: password)
        }
    }
}
