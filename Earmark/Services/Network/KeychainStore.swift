import ShelfKit

/// NAS logins in the Keychain, under Earmark's own service. Pinned: a different service can't
/// see the passwords already saved under this one, so every NAS would need signing into again.
enum KeychainStore {
    private static let keychain = Keychain(service: "com.vanities.earmark.nas")

    static func set(_ value: String, for key: String) throws { try keychain.set(value, for: key) }
    static func get(_ key: String) -> String? { keychain.get(key) }
    static func delete(_ key: String) { keychain.delete(key) }
}
