import Foundation
import Security
import os

/// Persists calendar credentials under Application Support (mode `0600`).
///
/// Keychain is intentionally avoided for day-to-day access: ad-hoc / Debug builds
/// re-sign on every rebuild, which spam “wants to use your confidential information
/// in the keychain” dialogs. Legacy Keychain items are migrated once, then deleted
/// without reading so prompts stop.
enum CredentialStore {
    private static let logger = Logger(subsystem: "com.meetingmonitor.app", category: "Credentials")
    private static let keychainService = "com.meetingmonitor.app.credentials"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func save(credential: CalendarCredentials) {
        guard let data = try? encoder.encode(credential) else {
            logger.error("Failed to encode credentials for \(credential.provider, privacy: .public)")
            return
        }
        writeFile(provider: credential.provider, data: data)
        // Drop any legacy Keychain copy without reading (reading triggers the prompt).
        deleteKeychain(provider: credential.provider)
    }

    static func load(provider: String) -> CalendarCredentials? {
        if let data = readFile(provider: provider),
           let creds = try? decoder.decode(CalendarCredentials.self, from: data)
        {
            return creds
        }

        // One-time migration from older Keychain-backed builds.
        if let legacy = loadFromKeychain(provider: provider) {
            save(credential: legacy)
            logger.info("Migrated \(provider, privacy: .public) credentials from Keychain to Application Support")
            return legacy
        }
        return nil
    }

    static func delete(provider: String) {
        removeFile(provider: provider)
        deleteKeychain(provider: provider)
    }

    // MARK: - Application Support

    private static var storeDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MeetingMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir.path
        )
        return dir
    }

    private static func fileURL(provider: String) -> URL {
        // Keep provider in the filename so google / spacemail stay separate.
        let safe = provider.replacingOccurrences(of: "/", with: "_")
        return storeDir.appendingPathComponent("credentials_\(safe).dat")
    }

    private static func writeFile(provider: String, data: Data) {
        let url = fileURL(provider: provider)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            logger.error("Failed to write credentials for \(provider, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func readFile(provider: String) -> Data? {
        try? Data(contentsOf: fileURL(provider: provider))
    }

    private static func removeFile(provider: String) {
        try? FileManager.default.removeItem(at: fileURL(provider: provider))
    }

    // MARK: - Legacy Keychain (migrate + delete only)

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

    /// Delete without reading — avoids the access-dialog loop on unsigned builds.
    private static func deleteKeychain(provider: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
