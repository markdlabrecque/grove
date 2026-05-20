import Foundation

/// A `URLProtocol` subclass that intercepts requests and returns a caller-
/// configured response without touching the network.
///
/// Both `GroveCoreTests` and the Xcode-project-side `GroveTests` bundle
/// import this type from the shared `GroveTestSupport` module, which is the
/// single source of truth.
///
/// ## Per-test isolation (preferred)
///
/// Use `StubURLProtocol.makeSession(responder:)` to obtain an isolated
/// `URLSessionConfiguration` + teardown closure. Each call embeds a unique
/// stub identifier in the session's `httpAdditionalHeaders` so concurrent
/// suites cannot corrupt each other's responders:
///
/// ```swift
/// let (config, teardown) = StubURLProtocol.makeSession { request in
///   let response = HTTPURLResponse(url: request.url!, statusCode: 201,
///                                  httpVersion: nil, headerFields: nil)!
///   return (response, jsonData)
/// }
/// defer { teardown() }
///
/// let api = GroveAPI(baseURL: url, bearerToken: "tok", configuration: config)
/// ```
///
/// For error paths, supply the error variant:
///
/// ```swift
/// let (config, teardown) = StubURLProtocol.makeSession(
///   errorResponder: { _ in URLError(.notConnectedToInternet) }
/// )
/// defer { teardown() }
/// ```
///
/// Suites using `makeSession` do **not** need `@Suite(.serialized)` for
/// cross-suite safety, though serializing within a suite is still good practice.
///
/// ## Legacy static API (deprecated)
///
/// The static `responder` / `errorResponder` properties still compile so
/// existing callers can be migrated incrementally. They carry the same
/// cross-suite race as before, so suites using them must remain serialised
/// and must not run concurrently with other suites that touch the same statics.
public final class StubURLProtocol: URLProtocol {

  // MARK: - Per-test isolation registry

  /// The header key that carries the per-test stub identifier.
  public static let stubIDHeaderKey = "X-Stub-ID"

  // Registry entries: either a success responder or an error responder.
  private enum RegistryEntry {
    case success((URLRequest) -> (HTTPURLResponse, Data))
    case failure((URLRequest) -> Error)
  }

  /// Protected by a lock because `startLoading` may be called from any thread
  /// that URLSession dispatches to.
  private static let lock = NSLock()
  // Marked nonisolated(unsafe) because all accesses are guarded by `lock`.
  nonisolated(unsafe) private static var registry: [UUID: RegistryEntry] = [:]

  /// Registers a success responder keyed to `id`. Used internally by `makeSession`.
  private static func register(id: UUID, entry: RegistryEntry) {
    lock.withLock { registry[id] = entry }
  }

  /// Removes the entry for `id`. Called by the teardown closure returned from
  /// `makeSession`.
  private static func unregister(id: UUID) {
    _ = lock.withLock { registry.removeValue(forKey: id) }
  }

  /// Returns the registry entry for `id`, if present.
  private static func entry(for id: UUID) -> RegistryEntry? {
    lock.withLock { registry[id] }
  }

  // MARK: - Factory

  /// Creates an isolated `URLSessionConfiguration` whose requests are
  /// intercepted by `StubURLProtocol` and routed to `responder`.
  ///
  /// - Parameter responder: A closure that receives each intercepted
  ///   `URLRequest` and returns an `(HTTPURLResponse, Data)` pair.
  /// - Returns: A tuple of:
  ///   - `config`: A `.default`-based `URLSessionConfiguration` with
  ///     `StubURLProtocol` installed and an `X-Stub-ID` header embedded.
  ///   - `teardown`: A closure that removes the responder from the registry.
  ///     Call it in `defer` or `tearDown`.
  public static func makeSession(
    responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)
  ) -> (URLSessionConfiguration, () -> Void) {
    let id = UUID()
    register(id: id, entry: .success(responder))
    let config = URLSessionConfiguration.default
    config.protocolClasses = [StubURLProtocol.self]
    config.httpAdditionalHeaders = [stubIDHeaderKey: id.uuidString]
    return (config, { unregister(id: id) })
  }

  /// Creates an isolated `URLSessionConfiguration` whose requests fail with
  /// the error returned by `errorResponder`.
  ///
  /// - Parameter errorResponder: A closure that receives each intercepted
  ///   `URLRequest` and returns the `Error` to deliver to the caller.
  /// - Returns: A tuple of `(config, teardown)` — same semantics as the
  ///   success variant.
  public static func makeSession(
    errorResponder: @escaping (URLRequest) -> Error
  ) -> (URLSessionConfiguration, () -> Void) {
    let id = UUID()
    register(id: id, entry: .failure(errorResponder))
    let config = URLSessionConfiguration.default
    config.protocolClasses = [StubURLProtocol.self]
    config.httpAdditionalHeaders = [stubIDHeaderKey: id.uuidString]
    return (config, { unregister(id: id) })
  }

  // MARK: - Test-support inspection

  /// Returns `true` if a registry entry exists for `id`.
  ///
  /// Intended for use in tests that verify the teardown closure removes the
  /// entry (see `StubURLProtocolIsolationTests`).
  public static func hasResponder(for id: UUID) -> Bool {
    entry(for: id) != nil
  }

  // MARK: - Legacy static API

  /// Configure this before each test. Returns `(response, body)` for any
  /// intercepted request. If `nil` and `errorResponder` is also `nil`, the stub
  /// crashes with a clear message so tests don't silently proceed with no response.
  ///
  /// Marked `nonisolated(unsafe)` because tests using this must be serialised —
  /// they never run concurrently — so accesses are externally synchronised
  /// without a Swift concurrency primitive.
  ///
  /// - Note: Prefer `makeSession(responder:)` for new tests. The static API
  ///   is retained for migration compatibility only.
  nonisolated(unsafe) public static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

  /// Alternative to `responder`. When set, `startLoading()` fails the request
  /// with the returned error instead of returning an HTTP response. Use this to
  /// simulate network-layer failures such as `URLError(.notConnectedToInternet)`.
  ///
  /// Only one of `responder` or `errorResponder` should be set at a time.
  ///
  /// - Note: Prefer `makeSession(errorResponder:)` for new tests.
  nonisolated(unsafe) public static var errorResponder: ((URLRequest) -> Error)?

  // MARK: - URLProtocol overrides

  override public class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override public func startLoading() {
    // Per-test isolation path: look up a responder by the stub ID embedded in
    // the request's headers. This path is race-free across concurrent suites.
    if let stubIDString = request.value(forHTTPHeaderField: StubURLProtocol.stubIDHeaderKey),
       let stubID = UUID(uuidString: stubIDString),
       let registryEntry = StubURLProtocol.entry(for: stubID) {
      switch registryEntry {
      case .success(let responder):
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      case .failure(let errorResponder):
        client?.urlProtocol(self, didFailWithError: errorResponder(request))
      }
      return
    }

    // Legacy static path: used by suites that haven't migrated yet.
    if let errorResponder = StubURLProtocol.errorResponder {
      client?.urlProtocol(self, didFailWithError: errorResponder(request))
      return
    }

    guard let responder = StubURLProtocol.responder else {
      preconditionFailure(
        "StubURLProtocol: no responder found. " +
        "Either call makeSession(responder:) and embed the returned config, " +
        "or set StubURLProtocol.responder before making a request."
      )
    }

    let (response, data) = responder(request)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override public func stopLoading() {
    // Nothing to cancel — responses are returned synchronously in startLoading.
  }
}
