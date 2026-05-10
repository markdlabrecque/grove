import Foundation

/// A `URLProtocol` subclass that intercepts requests and returns a caller-
/// configured response without touching the network.
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
/// stubs don't leak between tests. The `OracleAPISmokeTests` suite is marked
/// `@Suite(.serialized)` to prevent Swift Testing's parallel runner from
/// mixing stubs across concurrent tests.
final class StubURLProtocol: URLProtocol {

  /// Configure this before each test. Returns `(response, body)` for any
  /// intercepted request. If `nil`, the stub crashes with a clear message so
  /// tests don't silently proceed with no response.
  ///
  /// Marked `nonisolated(unsafe)` because `OracleAPISmokeTests` is
  /// `@Suite(.serialized)` — tests never run concurrently — so accesses are
  /// externally synchronised without a Swift concurrency primitive.
  nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

  // MARK: - URLProtocol overrides

  override class func canInit(with request: URLRequest) -> Bool {
    // Intercept every request routed through a session using this protocol.
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    guard let responder = StubURLProtocol.responder else {
      preconditionFailure(
        "StubURLProtocol.responder must be set before making a request."
      )
    }

    let (response, data) = responder(request)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    // Nothing to cancel — responses are returned synchronously in startLoading.
  }
}
