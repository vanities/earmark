import SwiftUI
import os
import ShelfKit

/// Connects an SMB share (Unraid, Synology, a Mac…) as a library folder.
struct NASSetupView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    /// Empty means SMB's standard 445; a NAS behind a port forward or a Docker share differs.
    @State private var port = ""
    @State private var share = ""
    @State private var path = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    /// The port typed, or 445 when the field is empty; nil when what's typed isn't a port.
    private var portNumber: Int? {
        let typed = port.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return 445 }
        return Int(typed).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !share.trimmingCharacters(in: .whitespaces).isEmpty
            && portNumber != nil && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. NAS)", text: $name)
                    TextField("Host or IP (e.g. nas.local)", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port (445 if left empty)", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Share (e.g. media)", text: $share)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Folder in share (e.g. audiobooks)", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Earmark indexes this folder over SMB. Books stream from the NAS when you're on its network, and any book can be downloaded to this iPhone.")
                }
                Section("Login") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            if isConnecting { ProgressView().padding(.trailing, 6) }
                            Text(isConnecting ? "Connecting…" : "Connect & Add")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!canConnect)
                }
            }
            .navigationTitle("Add NAS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(isConnecting)
    }

    private func connect() {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).replacingOccurrences(of: "\\", with: "/")
        let server = NASServer(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? trimmedHost,
            host: trimmedHost,
            port: portNumber ?? 445,
            share: share.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
            path: trimmedPath,
            username: username.trimmingCharacters(in: .whitespaces),
            addedAt: .now
        )
        isConnecting = true
        errorMessage = nil
        Logger.ui.info("[ui] connecting NAS \(server.displayLocation, privacy: .public)")
        Task {
            do {
                try await library.addNAS(server, password: password)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
