import Foundation
import LocalAuthentication
import LyricsXFoundation
import Security

enum AICredentialError: Error {
    case keychain(OSStatus)
    case invalidStoredValue

    var isTransient: Bool {
        guard case let .keychain(status) = self else {
            return false
        }
        return [
            errSecInteractionNotAllowed,
            errSecNotAvailable,
        ].contains(status)
    }
}

enum AICredentialStore {
    private struct StoredCredential: Codable {
        let version: Int
        let endpointOrigin: String
        let apiKey: String
    }

    private static let account = "api-key-v2"
    private static let legacyAccount = "api-key"
    private static let cacheLock = NSLock()
    private static var cachedCredential: StoredCredential?

    private static var service: String {
        return "\(Bundle.main.bundleIdentifier ?? "com.JH.LyricsX").ai-lyrics-translation"
    }

    static func apiKey(
        for endpoint: URL,
        allowingAuthenticationUI: Bool = false
    ) throws -> String? {
        return try readAPIKey(
            for: endpoint,
            allowingAuthenticationUI: allowingAuthenticationUI,
            useCache: true
        )
    }

    private static func readAPIKey(
        for endpoint: URL,
        allowingAuthenticationUI: Bool,
        useCache: Bool
    ) throws -> String? {
        guard let endpointOrigin = AIConnectionPolicy.endpointOrigin(endpoint) else {
            throw AICredentialError.invalidStoredValue
        }
        if useCache,
           let cachedCredential = cachedCredentialValue(),
           cachedCredential.endpointOrigin == endpointOrigin {
            return cachedCredential.apiKey
        }

        var result: CFTypeRef?
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = !allowingAuthenticationUI
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            // Background translation passes `false` and therefore never surprises
            // the user with an authentication sheet after a signer or ACL change.
            kSecUseAuthenticationContext as String: authenticationContext,
        ] as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AICredentialError.keychain(status)
        }
        guard let data = result as? Data,
              let storedCredential = try? JSONDecoder().decode(StoredCredential.self, from: data),
              storedCredential.version == 1 else {
            throw AICredentialError.invalidStoredValue
        }
        guard storedCredential.endpointOrigin == endpointOrigin else {
            return nil
        }
        let apiKey = try validatedAPIKey(storedCredential.apiKey)
        let validatedCredential = StoredCredential(
            version: 1,
            endpointOrigin: endpointOrigin,
            apiKey: apiKey
        )
        cacheCredential(validatedCredential)
        return apiKey
    }

    /// Whether a key is stored for this endpoint's origin, without disclosing
    /// it. The cache is deliberately bypassed: the point of asking is to tell
    /// the user what the Keychain actually holds, so a key removed out of band
    /// must not keep reporting as present for the rest of the session.
    static func hasAccessibleAPIKey(
        for endpoint: URL,
        allowingAuthenticationUI: Bool = false
    ) throws -> Bool {
        return try readAPIKey(
            for: endpoint,
            allowingAuthenticationUI: allowingAuthenticationUI,
            useCache: false
        ) != nil
    }

    static func store(apiKey: String, for endpoint: URL) throws {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            try removeAPIKey()
            return
        }
        let validatedAPIKey = try validatedAPIKey(apiKey)
        guard let endpointOrigin = AIConnectionPolicy.endpointOrigin(endpoint) else {
            throw AICredentialError.invalidStoredValue
        }
        let storedCredential = StoredCredential(
            version: 1,
            endpointOrigin: endpointOrigin,
            apiKey: validatedAPIKey
        )
        guard let credentialData = try? JSONEncoder().encode(storedCredential) else {
            throw AICredentialError.invalidStoredValue
        }

        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary
        let attributes = [kSecValueData as String: credentialData] as CFDictionary
        let updateStatus = SecItemUpdate(query, attributes)
        if updateStatus == errSecSuccess {
            cacheCredential(storedCredential)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AICredentialError.keychain(updateStatus)
        }

        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: credentialData,
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AICredentialError.keychain(addStatus)
        }
        cacheCredential(storedCredential)
    }

    static func removeAPIKey() throws {
        cacheCredential(nil)
        var firstError: OSStatus?
        for account in [account, legacyAccount] {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            if status != errSecSuccess,
               status != errSecItemNotFound,
               firstError == nil {
                firstError = status
            }
        }
        if let firstError {
            throw AICredentialError.keychain(firstError)
        }
    }

    static func validatedAPIKey(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AICredentialError.invalidStoredValue
        }
        return value
    }

    private static func cachedCredentialValue() -> StoredCredential? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedCredential
    }

    private static func cacheCredential(_ value: StoredCredential?) {
        cacheLock.lock()
        cachedCredential = value
        cacheLock.unlock()
    }
}

// Source compatibility for the translation UI and existing callers. Storage
// service/account names intentionally retain their pre-refactor identifiers.
typealias AILyricsTranslationCredentialError = AICredentialError
typealias AILyricsTranslationCredentialStore = AICredentialStore
