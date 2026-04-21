import Foundation
import Security

protocol SecretStore {
    func saveAdvancedHeadersSecret(_ secret: StoredAdvancedHeadersSecret, for reference: String) throws
    func loadAdvancedHeadersSecret(for reference: String) throws -> StoredAdvancedHeadersSecret?
    func deleteSecret(for reference: String) throws
}

enum SecretStoreError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the saved authentication headers."
        case .decodingFailed:
            return "Saved authentication headers could not be read back."
        case .unexpectedStatus(let status):
            return "Keychain access failed with status \(status)."
        }
    }
}

final class KeychainSecretStore: SecretStore {
    private let service: String

    init(service: String = "com.bryan.mediagetter.auth-profile") {
        self.service = service
    }

    func saveAdvancedHeadersSecret(_ secret: StoredAdvancedHeadersSecret, for reference: String) throws {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(secret) else {
            throw SecretStoreError.encodingFailed
        }

        let query = baseQuery(for: reference)
        let attributes = [kSecValueData as String: data]
        let status = SecItemCopyMatching(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecretStoreError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            var createQuery = query
            createQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    func loadAdvancedHeadersSecret(for reference: String) throws -> StoredAdvancedHeadersSecret? {
        var query = baseQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let secret = try? JSONDecoder().decode(StoredAdvancedHeadersSecret.self, from: data) else {
                throw SecretStoreError.decodingFailed
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    func deleteSecret(for reference: String) throws {
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
    }
}
