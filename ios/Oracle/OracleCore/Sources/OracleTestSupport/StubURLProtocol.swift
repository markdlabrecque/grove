import Foundation

/// A `URLProtocol` subclass that intercepts requests and returns a caller-
/// configured response without touching the network.
///
/// Both `OracleCoreTests` and the Xcode-project-side `OracleTests` bundle
/// import this type from the shared `OracleTestSupport` module, which is the
/// single source of truth.
///
/// Usage in a test:
///
/// ```swift
/// StubURLProtocol.responder = { request in
///   let response = HTTPURLResponse(
///     url: request.url!,
///     statusCode: 201,
///     httpVersion: nil,
///     headerFields: ["Content-Type": "application/json"]
///   )!
///   return (response, jsonData)
/// }
///
/// let config = URLSessionConfiguration.default
/// config.protocolClasses = [StubURLProtocol.self]
/// let api = OracleAPI(baseURL: url, bearerToken: "tok", configuration: config)
/// ```
///
/// Reset `StubURLProtocol.responder = nil` in `tearDown` / after the test so
/// stubs don't leak between tests. Test suites using this class should be marked
/// `@Suite(.serialized)` to prevent Swift Testing's parallel runner from
/// mixing stubs across concurrent tests.
public final class StubURLProtocol: URLProtocol {

  /// Configure this before each test. Returns `(response, body)` for any
  /// intercepted request. If `nil` and `errorResponder` is also `nil`, the stub
  /// crashes with a clear message so tests don't silently proceed with no response.
  ///
  /// Marked `nonisolated(unsafe)` because tests using this must be serialised —
  /// they never run concurrently — so accesses are externally synchronised
  /// without a Swift concurrency primitive.
  nonisolated(unsafe) public static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

  /// Alternative to `responder`. When set, `startLoading()` fails the request
  /// with the returned error instead of returning an HTTP response. Use this to
  /// simulate network-layer failures such as `URLError(.notConnectedToInternet)`.
  ///
  /// Only one of `responder` or `errorResponder` should be set at a time.
  nonisolated(unsafe) public static var errorResponder: ((URLRequest) -> Error)?

  // MARK: - URLProtocol overrides

  override public class func canInit(with request: URLRequest) -> Bool {
    // Intercept every request routed through a session using this protocol.
    return true
  }

  override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override public func startLoading() {
    if let errorResponder = StubURLProtocol.errorResponder {
      client?.urlProtocol(self, didFailWithError: errorResponder(request))
      return
    }

    guard let responder = StubURLProtocol.responder else {
      preconditionFailure(
        "StubURLProtocol.responder or errorResponder must be set before making a request."
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
