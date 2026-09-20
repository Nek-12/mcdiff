import Foundation
import Security

public protocol GitHubCredentialStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data?) throws
}

public struct KeychainGitHubCredentialStore: GitHubCredentialStore {
    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.nek12.mcdiff.github",
         kSecAttrAccount as String: "oauth"]
    }

    public func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw GitHubError.credentials("The saved GitHub sign-in is unreadable. Sign out and sign in again.") }
        return data
    }

    public func save(_ data: Data?) throws {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw GitHubError.credentials("McDiff could not access its GitHub sign-in in Keychain (error \(status)). Unlock your Keychain and try again.")
        }
    }
}

struct GitHubCredential: Codable, Sendable {
    let accessToken: String
    let expiresAt: Date?
    let refreshToken: String?
    let refreshExpiresAt: Date?
}
