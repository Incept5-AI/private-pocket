import Foundation
import Security

/// The few facts the app shares with its widget extension. The signing profile has no
/// App Group, so they travel through the Keychain, in the app's own access group
/// (`<team prefix>.com.incept5.private-pocket`), which the extension's entitlements
/// also list. The team prefix is read off the Keychain itself: a query that names no
/// group answers with the caller's default one, `<prefix>.<its bundle id>`.
enum SharedState {
    static let appBundleID = "com.incept5.private-pocket"
    private static let service = "com.incept5.private-pocket.shared"

    static let accessGroup: String? = {
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "probe",
                                    kSecValueData as String: Data([1]),
                                    kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        var status = SecItemAdd(probe as CFDictionary, &out)
        if status == errSecDuplicateItem {
            var query = probe
            query[kSecValueData as String] = nil
            status = SecItemCopyMatching(query as CFDictionary, &out)
        }
        guard status == errSecSuccess, let attrs = out as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first else { return nil }
        return "\(prefix).\(appBundleID)"
    }()

    /// The Pocket is recording right now. Written by the app, read by Control Center's toggle.
    static var recording: Bool {
        get { read("recording") == "1" }
        set { write("recording", newValue ? "1" : "0") }
    }

    private static func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    private static func read(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func write(_ account: String, _ value: String) {
        var q = base(account)
        let data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}
