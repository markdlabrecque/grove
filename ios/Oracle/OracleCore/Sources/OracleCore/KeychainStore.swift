import Foundation
import Security

/// A thin, type-safe wrapper around the iOS Keychain Services API.
///
/// `KeychainStore` stores and retrieves `String` values keyed by a logical name
/// (the `key` parameter) within an isolated Keychain service namespace (the
/// `service` parameter).  All operations are synchronous and execute on the
/// caller's thread.
///
/// # Design
///
/// - **Service isolation.** Each `KeychainStore` is scoped to a single service
///   string (a reverse-DNS identifier, e.g. `com.the-oracle.app`).  Separate
///   service strings mean separate Keychain items — tests use per-run UUIDs to
///   avoid pollution.
/// - **Error surfacing.** Failures produce a thrown `KeychainError` with the
///   raw `OSStatus` code.  Callers must not silently swallow these errors; they
///   should log and fall back gracefully.
/// - **No silent data loss.** `write` uses `kSecClassGenericPassword` and
///   either adds a new item or updates an existing one — it never drops a value
///   silently.
///
/// # Auth model (V1)
///
/// The bearer token and server URL are the only Keychain items in V1.
/// On first launch `Config.swift` seeds the token from the xcconfig bootstrap
/// value into the Keychain; subsequent reads go through `KeychainStore` only.
///
/// V2 will add Face/Touch ID protection via `LAContext`.  See the
/// `TODO(auth-v2):` markers in `Config.swift` and `OracleAPI.swift`.
public struct KeychainStore: KeychainStoreProtocol {

  // MARK: - Well-known keys

  /// Keychain account name used to store the bearer token.
  public static let bearerTokenKey = "bearer_token"

  /// Keychain account name used to store the server URL.
  public static let serverURLKey = "server_url"

  // MARK: - Properties

  /// The Keychain service namespace (reverse-DNS identifier).
  private let service: String

  // MARK: - Init

  /// Create a `KeychainStore` scoped to the given service namespace.
  ///
  /// Production code should use `KeychainStore.shared`; tests pass a per-run
  /// UUID service string to ensure isolation.
  public init(service: String) {
    self.service = service
  }

  /// The shared production instance, scoped to the app's bundle identifier.
  public static let shared = KeychainStore(service: "com.the-oracle.app")

  // MARK: - CRUD

  /// Write (add or update) a `String` value for the given `key`.
  ///
  /// If an item for `(service, key)` already exists it is updated via
  /// `SecItemUpdate`; otherwise a new item is added via `SecItemAdd`.
  ///
  /// - Throws: `KeychainError.writeFailed(status:)` on any non-success
  ///   `OSStatus`.
  public func write(_ value: String, forKey key: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw KeychainError.encodingFailed
    }

    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: key,
    ]

    // Try an update first; if the item is missing, add it.
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)

    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var addQuery = query
      addQuery[kSecValueData] = data
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw KeychainError.writeFailed(status: addStatus)
      }
    default:
      throw KeychainError.writeFailed(status: status)
    }
  }

  /// Read the `String` value for the given `key`.
  ///
  /// Returns `nil` when no item exists for `(service, key)`.
  ///
  /// - Throws: `KeychainError.readFailed(status:)` on any non-success
  ///   `OSStatus` other than `errSecItemNotFound`.
  public func read(forKey key: String) throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: key,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    switch status {
    case errSecSuccess:
      guard
        let data = result as? Data,
        let string = String(data: data, encoding: .utf8)
      else {
        throw KeychainError.decodingFailed
      }
      return string
    case errSecItemNotFound:
      return nil
    default:
      throw KeychainError.readFailed(status: status)
    }
  }

  /// Delete the item for the given `key`.
  ///
  /// No-op if the item does not exist.
  ///
  /// - Throws: `KeychainError.deleteFailed(status:)` on any unexpected
  ///   `OSStatus`.
  public func delete(forKey key: String) throws {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: key,
    ]

    let status = SecItemDelete(query as CFDictionary)

    switch status {
    case errSecSuccess, errSecItemNotFound:
      return  // Success or item never existed — both are fine.
    default:
      throw KeychainError.deleteFailed(status: status)
    }
  }

  // MARK: - Token resolution

  /// Return the bearer token from the Keychain, falling back to the xcconfig
  /// bootstrap value when the Keychain has no entry yet.
  ///
  /// This is the V1 token-getter precedence rule:
  ///   1. Keychain has a value → use it.
  ///   2. Keychain is empty or read fails → use `xconfigFallback`.
  ///
  /// A Keychain read failure is logged but does not throw — the caller (Config
  /// init) must not brick the app if the Keychain is temporarily unavailable
  /// (e.g. simulator entitlement edge case).
  ///
  /// - Parameter xconfigFallback: The `BEARER_TOKEN` value from Info.plist /
  ///   xcconfig, used only when the Keychain has nothing.
  public func resolveToken(xconfigFallback: String) -> String {
    do {
      if let token = try read(forKey: KeychainStore.bearerTokenKey), !token.isEmpty {
        return token
      }
    } catch {
      print("[KeychainStore] WARN read failed for bearer_token: \(error) — using xcconfig fallback")
    }
    return xconfigFallback
  }

  // MARK: - URL validation

  /// Returns `true` if `raw` is a syntactically valid URL with an `http` or
  /// `https` scheme and a non-empty host.
  ///
  /// This is the canonical validation used by `SettingsViewModel.commitServerURL()`.
  /// The same check must be applied whenever a server URL is persisted.
  public static func isValidServerURL(_ raw: String) -> Bool {
    guard
      !raw.isEmpty,
      let url = URL(string: raw),
      let scheme = url.scheme,
      (scheme == "https" || scheme == "http"),
      let host = url.host,
      !host.isEmpty
    else {
      return false
    }
    return true
  }
}

// MARK: - Errors

/// Errors thrown by `KeychainStore` operations.
public enum KeychainError: Error, LocalizedError, Sendable {
  /// The string value could not be UTF-8 encoded before writing.
  case encodingFailed
  /// The raw `Data` read from the Keychain could not be decoded as UTF-8.
  case decodingFailed
  /// `SecItemAdd` or `SecItemUpdate` returned a non-success `OSStatus`.
  case writeFailed(status: OSStatus)
  /// `SecItemCopyMatching` returned a non-success `OSStatus` (excluding
  /// `errSecItemNotFound`, which is surfaced as `nil`).
  case readFailed(status: OSStatus)
  /// `SecItemDelete` returned a non-success `OSStatus`.
  case deleteFailed(status: OSStatus)

  public var errorDescription: String? {
    switch self {
    case .encodingFailed:
      return "Could not encode the value for Keychain storage."
    case .decodingFailed:
      return "Could not decode a value read from the Keychain."
    case .writeFailed(let status):
      return "Keychain write failed (OSStatus \(status))."
    case .readFailed(let status):
      return "Keychain read failed (OSStatus \(status))."
    case .deleteFailed(let status):
      return "Keychain delete failed (OSStatus \(status))."
    }
  }
}
