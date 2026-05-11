import Foundation

/// A `URLProtocol` subclass that intercepts requests and returns a caller-
/// configured response without touching the network.
///
/// This is a copy of the same helper in `OracleCoreTests`. Because the two test
/// targets are separate bundles, the type cannot be shared directly. Keeping the
/// implementations identical is intentional — if one changes, update both.
///
/// Usage:
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
/// Reset `StubURLProtocol.responder = nil` after each test to prevent stub
/// leakage. Tests using this class must be serialised (`.serialized` suite trait).
final class StubURLProtocol: URLProtocol {

  /// Configure before each test. Returns `(response, body)` for any intercepted
  /// request. Crashes with a clear message if left `nil` when a request is made.
  ///
  /// `nonisolated(unsafe)` because tests using this are serialised — never concurrent.
  nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
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

  override func stopLoading() {}
}
