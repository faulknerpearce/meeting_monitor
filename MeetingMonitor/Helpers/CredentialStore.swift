import Foundation
import os
import Security

/// Persists calendar credentials under Application Support (directory `0700`, files `0600`).
/// The app is sandboxed, so this resolves inside its container:
/// `~/Library/Containers/com.meetingmonitor.app/Data/Library/Application Support/MeetingMonitor/`.
///
/// Keychain is avoided for day-to-day access: ad-hoc / Debug builds are re-signed on every
/// rebuild, which makes Keychain show an access prompt each launch. When no file exists for a
/// provider, a Keychain item from older builds is migrated to a file and then deleted.
enum CredentialStore {
    private static let logger = Logger(category: "Credentials")
    private static let keychainService = "com.meetingmonitor.app.credentials"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Where credential files live. Tests point this at a temporary directory.
    nonisolated(unsafe) static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingMonitor", isDirectory: true)
    }()

    static func save(credential: CalendarCredentials) {
        guard let data = try? encoder.encode(credential) else {
            logger.error("Failed to encode credentials for \(credential.provider, privacy: .public)")
            return
        }
        writeFile(provider: credential.provider, data: data)
        // Drop any Keychain copy without reading it (reading triggers the access prompt).
        deleteKeychain(provider: credential.provider)
    }

    static func load(provider: String) -> CalendarCredentials? {
        if let data = try? Data(contentsOf: fileURL(provider: provider)) {
            return try? decoder.decode(CalendarCredentials.self, from: data)
        }
        if let legacy = loadFromKeychain(provider: provider) {
            save(credential: legacy)
            logger.info("Migrated \(provider, privacy: .public) credentials from Keychain to Application Support")
            return legacy
        }
        return nil
    }

    static func delete(provider: String) {
        try? FileManager.default.removeItem(at: fileURL(provider: provider))
        deleteKeychain(provider: provider)
    }

    // MARK: - Application Support

    static func fileURL(provider: String) -> URL {
        let safe = provider.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("credentials_\(safe).dat")
    }

    private static func writeFile(provider: String, data: Data) {
        let url = fileURL(provider: provider)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.error(
                "Failed to write credentials for \(provider, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Keychain (migration and deletion only)

    private static func loadFromKeychain(provider: String) -> CalendarCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? decoder.decode(CalendarCredentials.self, from: data)
    }

    /// Deletes without reading, which never prompts.
    private static func deleteKeychain(provider: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
