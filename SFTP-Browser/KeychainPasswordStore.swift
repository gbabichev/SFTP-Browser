//
//  KeychainPasswordStore.swift
//  SFTP-Browser
//
//  Created by OpenAI on 4/27/26.
//

import Foundation
import Security

struct KeychainPasswordStore {
    private let service: String
    private let account: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "SFTP-Browser",
        account: String = "last-sftp-password"
    ) {
        self.service = service
        self.account = account
    }

    func loadPassword() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return ""
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    func savePassword(_ password: String) {
        guard !password.isEmpty else {
            deletePassword()
            return
        }

        let data = Data(password.utf8)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            _ = SecItemAdd(query as CFDictionary, nil)
        }
    }

    func deletePassword() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
