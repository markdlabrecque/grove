import Foundation

/// A `URLProtocol` subclass that intercepts requests and returns a caller-
/// configured response without touching the network.
///
/// Both `GroveCoreTests` and the Xcode-project-side `GroveTests` bundle
/// import this type from the shared `GroveTestSupport` module, which is the
/// single source of truth.
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
/// cross-suite safety.
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

  // MARK: - Legacy static responders (backward compatibility)

  /// A global success responder for use in suites that cannot embed a per-test
  /// stub identifier in the session config (e.g. because the URLSession is
  /// created inside the system under test).
  ///
  /// Only active when a request does NOT carry an `X-Stub-ID` header.
  /// Suites that use this path MUST be annotated `@Suite(.serialized)` to prevent
  /// concurrent tests from clobbering each other's responder. Prefer
  /// `makeSession(responder:)` for new tests — it is race-free even in parallel suites.
  ///
  /// Set to non-nil before the request fires; clear with `= nil` in `defer`.
  nonisolated(unsafe) public static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

  /// A global error responder for the legacy static path.
  ///
  /// When set, `startLoading` delivers this error rather than calling `responder`.
  /// Same safety requirements as `responder` above.
  nonisolated(unsafe) public static var errorResponder: ((URLRequest) -> Error)?

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

  // MARK: - Registry mutation (for mutable-responder sessions)

  /// Replace the success responder for an existing session without tearing it
  /// down and re-creating it.
  ///
  /// Used by `makeQueueWithStub` in `StubNetworkFixtures` so tests can change
  /// what the stub returns between steps (e.g. succeed on the first N calls,
  /// then fail). Calling this with an `id` that is not in the registry is a
  /// no-op (safe to call after teardown).
  public static func updateResponder(
    for id: UUID,
    to responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)
  ) {
    lock.withLock { registry[id] = .success(responder) }
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

  // MARK: - URLProtocol overrides

  override public class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override public func startLoading() {
    // Fast path: per-test isolated session with X-Stub-ID header (preferred).
    if let stubIDString = request.value(forHTTPHeaderField: StubURLProtocol.stubIDHeaderKey),
       let stubID = UUID(uuidString: stubIDString) {
      guard let registryEntry = StubURLProtocol.entry(for: stubID) else {
        preconditionFailure(
          "StubURLProtocol: no entry found for stub ID \(stubID). " +
          "The teardown closure may have been called before the request completed, " +
          "or the stub ID header was set to an unregistered value."
        )
      }
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

    // Fallback: legacy static responder path for suites that cannot embed a
    // per-test ID (e.g. when the URLSession is owned by the system under test).
    // The calling suite MUST be @Suite(.serialized) to prevent cross-test races.
    if let errorResponder = StubURLProtocol.errorResponder {
      client?.urlProtocol(self, didFailWithError: errorResponder(request))
      return
    }

    if let responder = StubURLProtocol.responder {
      let (response, data) = responder(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    preconditionFailure(
      "StubURLProtocol: request has no \(StubURLProtocol.stubIDHeaderKey) header and no " +
      "static responder is set. Either use StubURLProtocol.makeSession(responder:) to create " +
      "an isolated session, or set StubURLProtocol.responder before the request fires."
    )
  }

  override public func stopLoading() {
    // Nothing to cancel — responses are returned synchronously in startLoading.
  }
}
