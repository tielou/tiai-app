import Foundation
import Security

/// Where credentials are kept.
///
/// A protocol so tests and SwiftUI previews never touch the real keychain —
/// `swift test` must not pop an unlock prompt on a CI runner.
public protocol CredentialStore: Sendable {
    func readToken() -> String?
    func writeToken(_ token: String)
    func readPassword() -> String?
    func writePassword(_ password: String)
    func clearPassword()
    func clearAll()
}

/// A lock-guarded box. Small and explicit rather than spreading
/// `@unchecked Sendable` state through every call site.
final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}

/// Credentials in the keychain, one generic password per item.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: survives a reboot once
/// the device has been unlocked (a generation that outlives the app needs to
/// keep its stream alive), and never travels in an iCloud or iTunes backup —
/// which matters because the thing being protected is access to someone's
/// home machine and their conversation history.
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "co.wobker.tiai") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String) {
        delete(account)
        var query = query(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    public func readToken() -> String? { read("token") }
    public func writeToken(_ token: String) { write("token", token) }
    public func readPassword() -> String? { read("password") }
    public func writePassword(_ password: String) { write("password", password) }
    public func clearPassword() { delete("password") }
    public func clearAll() {
        delete("token")
        delete("password")
    }
}
