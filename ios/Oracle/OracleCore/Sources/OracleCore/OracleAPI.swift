import Foundation

/// Async HTTP client for the Oracle backend.
///
/// `postCapture` uploads a capture via a background URLSession so it survives
/// app suspension (e.g. user presses Home immediately after tapping Save).
/// `postQuery` uses a default URLSession — queries are interactive, and a stale
/// response delivered minutes later is worse than an error; the default session
/// is also required for #91 `Task.cancel()` support.
///
/// # Two-session design (V2)
///
/// `backgroundSession` — `URLSessionConfiguration.background(…)` with a named
/// identifier, `isDiscretionary = false`, `sessionSendsLaunchEvents = true`,
/// and `waitsForConnectivity = true`. Used exclusively for `postCapture`. Only
/// `uploadTask(with:fromFile:)` is legal on a background session; the JSON body
/// is first written to a temp file then handed to the task. Completion events
/// arrive via `UploadSessionDelegate`.
///
/// `defaultSession` — `URLSession(configuration: .default)`. Used exclusively
/// for `postQuery`. Supports async `data(for:)` and Swift structured-
/// concurrency cancellation per #91.
///
/// # Actor isolation
///
/// All mutable state (`pendingUploads`, `backgroundCompletionHandlers`) is
/// isolated to the actor. `UploadSessionDelegate` callbacks cross back to the
/// actor via `Task { await api?.… }` so they are never concurrent with each
/// other or with `postCapture` / `postQuery`.
///
/// # Auth model (V1 — as of #184)
///
/// The shared singleton reads `bearerToken` and `baseURL` from
/// `Config.shared`, which itself reads the Keychain first (with xcconfig as a
/// first-launch fallback — see `Config.swift`).  When the user updates the
/// token or URL in Settings, `SettingsViewModel` writes the new values to the
/// Keychain and calls `OracleAPI.shared.updateCredentials(baseURL:bearerToken:)`
/// so in-flight auth is kept consistent without requiring an app restart.
///
/// TODO(auth-v2): Add Face/Touch ID gate (`LAContext`) around the Keychain
/// token read before any production or wider-distribution use.
public actor OracleAPI {

  // MARK: - Shared instance

  public static let shared = OracleAPI()

  // MARK: - Private state — sessions

  // The delegate must be created before the background session (it is passed
  // into the URLSession initialiser). The `api` back-reference is set in the
  // init after `self` is available.
  private let uploadDelegate: UploadSessionDelegate
  private let backgroundSession: URLSession
  private let defaultSession: URLSession

  // MARK: - Internal state — in-flight uploads (test-accessible)

  /// Keyed by `URLSessionTask.taskIdentifier`. Entries are inserted in
  /// `postCapture` and removed in `completeTask`.
  var pendingUploads: [Int: PendingUpload] = [:]

  // MARK: - Internal state — background completion handlers (test-accessible)

  /// Stored by `AppDelegate.application(_:handleEventsForBackgroundURLSession:…)`
  /// (wired in PR 2). Called on the main thread after
  /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` fires.
  ///
  /// `@Sendable` is required so the closures can be passed across the actor
  /// boundary into `DispatchQueue.main.async` without a Swift 6 data-race warning.
  var backgroundCompletionHandlers: [String: @Sendable () -> Void] = [:]

  // MARK: - Private state — config

  /// The server's base URL.  Mutable so `SettingsViewModel` can push an
  /// updated URL without requiring an app restart.
  private var baseURL: URL

  /// The bearer token used in `Authorization` headers.  Mutable so
  /// `SettingsViewModel` can push a new token after the user edits Settings.
  private var bearerToken: String

  // MARK: - Background session identifier

  /// The stable identifier used when creating the background URLSession.
  /// `AppDelegate` matches on this string to route completion handlers.
  public static let backgroundSessionIdentifier =
    "com.the-oracle.capture-upload"

  // MARK: - Init (production singleton)

  private init() {
    self.baseURL = Config.shared.baseURL
    self.bearerToken = Config.shared.bearerToken

    // Background session for capture uploads — survives app suspension.
    //
    // Configuration decisions (per spike §4 and §8):
    //   isDiscretionary = false  → upload as soon as connectivity allows;
    //                              true is appropriate for large media, wrong here.
    //   sessionSendsLaunchEvents = true  → OS relaunches the app when uploads
    //                              complete after a force-kill (Scenario C).
    //   waitsForConnectivity = true  → enqueued tasks wait rather than failing
    //                              immediately when offline; covers the
    //                              "task already enqueued, network drops" case.
    //                              Does NOT cover offline-at-save (PR 3 queue).
    let bgConfig = URLSessionConfiguration.background(
      withIdentifier: OracleAPI.backgroundSessionIdentifier
    )
    bgConfig.isDiscretionary = false
    bgConfig.sessionSendsLaunchEvents = true
    bgConfig.waitsForConnectivity = true

    let delegate = UploadSessionDelegate()
    self.uploadDelegate = delegate

    // delegateQueue: nil → URLSession creates its own serial OperationQueue.
    self.backgroundSession = URLSession(
      configuration: bgConfig,
      delegate: delegate,
      delegateQueue: nil
    )

    // Default session for queries — supports async data(for:) + cancellation.
    self.defaultSession = URLSession(configuration: .default)

    // Complete the cycle: give the delegate a weak back-reference to `self`
    // so it can dispatch delegate callbacks back to actor methods.
    delegate.api = self
  }

  // MARK: - Init (testing — explicit sessions)

  /// Designated initialiser used by unit tests that need to inspect constructed
  /// `URLRequest` values or supply a stub session.
  ///
  /// Both `captureSession` and `querySession` default to `URLSession.shared` so
  /// callers that only care about one path can omit the other.
  public init(
    baseURL: URL,
    bearerToken: String,
    captureSession: URLSession = .shared,
    querySession: URLSession = .shared
  ) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
    self.backgroundSession = captureSession
    self.defaultSession = querySession
    // uploadDelegate is unused when sessions are injected externally, but it
    // must still be initialised to satisfy the stored property requirement.
    // api back-reference intentionally left nil.
    self.uploadDelegate = UploadSessionDelegate()
  }

  /// Testing-only initialiser that accepts a `URLSessionConfiguration`.
  ///
  /// Tests inject a configuration (e.g. `.default` with `StubURLProtocol`
  /// added to `protocolClasses`) so the delegate-backed session construction
  /// path is exercised without a real background session identifier.
  ///
  /// The session is created with `uploadDelegate` as its delegate so that
  /// `StubURLProtocol` callbacks flow through the same
  /// `urlSession(_:dataTask:didReceive:)` / `urlSession(_:task:didCompleteWithError:)`
  /// path as in production. This means integration tests in `OracleAPISmokeTests`
  /// exercise the full continuation-map bridge, not just `data(for:)`.
  ///
  /// Both the capture (backgroundSession) and query (defaultSession) paths share
  /// the same injected session — tests that stub both paths need only one config.
  ///
  /// Access is `internal` — tests use `@testable import OracleCore`. Do not
  /// widen to `public`.
  init(baseURL: URL, bearerToken: String, configuration: URLSessionConfiguration) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
    let delegate = UploadSessionDelegate()
    self.uploadDelegate = delegate
    // Use the delegate-backed initialiser so StubURLProtocol callbacks arrive
    // via URLSessionDataDelegate (the production path), not via completion handlers.
    let session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: nil
    )
    self.backgroundSession = session
    self.defaultSession = session
    // Wire the back-reference so delegate methods can call api?.appendData etc.
    delegate.api = self
  }

  // MARK: - Capture

  /// Upload a single capture to the server (POST /v1/captures).
  ///
  /// Writes the JSON body to a temp file then enqueues an `uploadTask` on the
  /// background URLSession. The task survives app suspension — the OS will
  /// deliver the completion event via `UploadSessionDelegate` even if the app
  /// is killed and relaunched (provided `sessionSendsLaunchEvents = true` and
  /// `AppDelegate` is wired per PR 2).
  ///
  /// The call site awaits `withCheckedThrowingContinuation`: the continuation
  /// is stored in `pendingUploads` keyed by `task.taskIdentifier` and resumed
  /// (success or throw) inside `completeTask(identifier:response:error:)` when
  /// the delegate receives `urlSession(_:task:didCompleteWithError:)`.
  ///
  /// Temp file lifecycle: the file is written to `FileManager.temporaryDirectory`
  /// with the `clientID` UUID as the filename suffix so it is diagnosable and
  /// idempotent. It is deleted inside `completeTask` on every terminal outcome
  /// (success or failure). Orphaned files older than one hour are swept on
  /// launch (see `sweepOrphanedTempFiles()`).
  ///
  /// Note: the `backgroundSession` initialised in tests via
  /// `init(baseURL:bearerToken:configuration:)` is a plain `.default`-shaped
  /// session, so `StubURLProtocol` can intercept the upload and the async
  /// `data(for:)` / `uploadTask` distinction is transparent to those tests.
  /// Integration tests in `OracleAPISmokeTests` use this path.
  public func postCapture(_ payload: CapturePayload) async throws -> CaptureResponseBody {
    let request = try captureRequest(for: payload)
    let tempURL = try writeBodyToTempFile(for: payload, request: request)

    return try await withCheckedThrowingContinuation { continuation in
      let task = backgroundSession.uploadTask(with: request, fromFile: tempURL)
      pendingUploads[task.taskIdentifier] = PendingUpload(
        continuation: continuation,
        accumulatedData: Data(),
        tempFileURL: tempURL
      )
      task.resume()
    }
  }

  /// Build (but do not send) a URLRequest for POST /v1/captures.
  ///
  /// Separated from `postCapture` so unit tests can assert on the fully-formed
  /// request without a live server. The request has no `httpBody` set — for the
  /// background upload path the body lives in a temp file. For tests that use
  /// the default-session path (via `init(baseURL:bearerToken:configuration:)`),
  /// the body is set before the task is enqueued inside `postCapture`.
  public func captureRequest(for payload: CapturePayload) throws -> URLRequest {
    let url = baseURL.appendingPathComponent("v1/captures")
    var request = authorizedRequest(for: url)
    request.httpMethod = "POST"
    // Note: httpBody is NOT set here. For the background-session path the body
    // lives in a temp file passed to uploadTask(with:fromFile:). For the
    // default-session test path the body is supplied the same way. Tests that
    // only call captureRequest(for:) and inspect the result will see a nil body
    // unless they explicitly call writeBodyToTempFile and read the file back.
    return request
  }

  // MARK: - Query

  /// Send a natural-language query and receive ranked memory snippets.
  ///
  /// Hits POST /v1/queries with `{"query": <text>, "limit": 10}`. Stays on the
  /// `defaultSession` so `Task.cancel()` drops the in-flight request cleanly
  /// (per #91). Background delivery of a query response is not useful — the
  /// user is staring at the Ask screen.
  ///
  /// `minSimilarity` is forwarded to the server's optional `min_similarity`
  /// field. When `nil` (default) the server applies no similarity floor.
  /// Out-of-range values (< 0 or > 1) produce a 422 from the server.
  ///
  /// TODO(offline): V2 should queue failed queries locally and retry on
  /// NWPathMonitor "satisfied", consistent with the capture offline strategy.
  public func postQuery(
    _ queryText: String,
    limit: Int = 10,
    minSimilarity: Double? = nil
  ) async throws -> QueryResponseBody {
    let url = baseURL.appendingPathComponent("v1/queries")
    var request = authorizedRequest(for: url)
    request.httpMethod = "POST"

    let body = QueryRequestBody(query: queryText, limit: limit, minSimilarity: minSimilarity)
    let encoder = JSONEncoder()
    request.httpBody = try encoder.encode(body)

    let (data, response) = try await defaultSession.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.unexpectedResponse
    }

    let status = httpResponse.statusCode
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    print("[query] sent query_chars=\(queryText.count) status=\(status)")

    guard status == 200 else {
      let detail = extractDetail(from: data)
      throw APIError.httpError(statusCode: status, detail: detail)
    }

    let result = try decoder.decode(QueryResponseBody.self, from: data)
    print("[query] sent query_chars=\(queryText.count) status=\(status) sources=\(result.sources.count)")
    return result
  }

  // MARK: - Recent queries

  /// Fetch the user's most-recent distinct queries (GET /v1/queries/recent).
  ///
  /// Returns up to `limit` items ordered newest-first. Items are deduplicated
  /// server-side (case-insensitive on query text). The call uses the
  /// `defaultSession` — it's interactive, and Task cancellation support is
  /// desirable so the caller can abandon a stale in-flight fetch when the view
  /// disappears.
  ///
  /// A 5xx from the server is thrown as `APIError.httpError` so the caller can
  /// decide how to handle it. The `QueryViewModel` swallows the error silently —
  /// the chip strip just shows empty rather than breaking the Ask flow.
  ///
  /// - Parameter limit: Maximum number of items to return (server validates
  ///   `ge=1, le=50`; out-of-range produces a 422 thrown here).
  public func recentQueries(limit: Int = 10) async throws -> [RecentQueryItem] {
    var comps = URLComponents(
      url: baseURL.appendingPathComponent("v1/queries/recent"),
      resolvingAgainstBaseURL: false
    )!
    comps.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
    let url = comps.url!

    var request = authorizedRequest(for: url)
    request.httpMethod = "GET"

    let (data, response) = try await defaultSession.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.unexpectedResponse
    }

    let status = httpResponse.statusCode
    print("[recent-queries] limit=\(limit) status=\(status)")

    guard status == 200 else {
      let detail = extractDetail(from: data)
      throw APIError.httpError(statusCode: status, detail: detail)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([RecentQueryItem].self, from: data)
  }

  // MARK: - Feedback

  /// Submit thumbs-up or thumbs-down feedback for a query result
  /// (POST /v1/queries/{id}/feedback).
  ///
  /// Uses the `defaultSession` — feedback is an interactive gesture tied to
  /// a visible answer card and benefits from Swift structured-concurrency
  /// cancellation support.
  ///
  /// On success the server returns 204 No Content with an empty body. Any
  /// non-204 status is thrown as `APIError.httpError` so the caller can decide
  /// how to handle it. For the fire-and-forget use case, the `QueryViewModel`
  /// swallows 5xx errors — the API method throws so the ViewModel test can
  /// verify the swallow path independently.
  public func submitFeedback(queryID: UUID, feedback: Feedback) async throws {
    let url = baseURL.appendingPathComponent(
      "v1/queries/\(queryID.uuidString.lowercased())/feedback"
    )
    var request = authorizedRequest(for: url)
    request.httpMethod = "POST"

    let body = FeedbackRequestBody(feedback: feedback)
    let encoder = JSONEncoder()
    request.httpBody = try encoder.encode(body)

    let (data, response) = try await defaultSession.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.unexpectedResponse
    }

    let status = httpResponse.statusCode
    print("[feedback] query_id=\(queryID.uuidString.lowercased()) feedback=\(feedback.rawValue) status=\(status)")

    guard status == 204 else {
      let detail = extractDetail(from: data)
      throw APIError.httpError(statusCode: status, detail: detail)
    }
  }

  // MARK: - Delete

  /// Delete a memory by ID (DELETE /v1/memories/{id}).
  ///
  /// Uses the `defaultSession` — deletes are interactive (triggered from the
  /// detail view) and must support Swift structured-concurrency cancellation.
  /// A 404 response is re-thrown as `APIError.httpError(404, _)` so callers
  /// can decide whether to treat it as a success (already gone) or surface it.
  ///
  /// On success the server returns 204 No Content with an empty body.
  public func deleteMemory(id: UUID) async throws {
    let url = baseURL.appendingPathComponent(
      "v1/memories/\(id.uuidString.lowercased())"
    )
    var request = authorizedRequest(for: url)
    request.httpMethod = "DELETE"

    let (data, response) = try await defaultSession.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.unexpectedResponse
    }

    let status = httpResponse.statusCode
    print("[delete] memory_id=\(id.uuidString.lowercased()) status=\(status)")

    guard status == 204 else {
      let detail = extractDetail(from: data)
      throw APIError.httpError(statusCode: status, detail: detail)
    }
  }

  // MARK: - Delegate bridge (called from UploadSessionDelegate)

  /// Accumulate a chunk of response body data for a pending upload.
  ///
  /// Called by `UploadSessionDelegate.urlSession(_:dataTask:didReceive:)` via
  /// `Task { await api?.appendData(…) }`. The actor's serial executor
  /// serialises concurrent calls automatically.
  func appendData(_ data: Data, forTaskIdentifier id: Int) {
    pendingUploads[id]?.accumulatedData.append(data)
  }

  /// Resolve a pending upload to success or failure and clean up the temp file.
  ///
  /// Called by `UploadSessionDelegate.urlSession(_:task:didCompleteWithError:)`
  /// via `Task { await api?.completeTask(…) }`. This is the terminal handler
  /// for every upload task regardless of outcome.
  ///
  /// The `defer` block deletes the temp file on every code path. The only
  /// scenario where the temp file outlives this function is if the app is
  /// killed between `postCapture` writing the file and `didCompleteWithError`
  /// firing — in that case `sessionSendsLaunchEvents = true` ensures the OS
  /// relaunches the app and replays the event. Orphaned files older than one
  /// hour are swept on next launch via `sweepOrphanedTempFiles()`.
  func completeTask(
    identifier id: Int,
    response: HTTPURLResponse?,
    error: Error?
  ) {
    guard let upload = pendingUploads.removeValue(forKey: id) else {
      // Task identifier not in the map — likely an OS-replayed event for a
      // task whose continuation was already resumed (e.g. after a force-kill
      // and relaunch). Nothing to do.
      return
    }
    defer {
      do {
        try FileManager.default.removeItem(at: upload.tempFileURL)
      } catch {
        print("[capture] failed to delete temp file \(upload.tempFileURL.path): \(error)")
      }
    }

    if let error {
      upload.continuation.resume(throwing: error)
      return
    }

    guard let response else {
      upload.continuation.resume(throwing: APIError.unexpectedResponse)
      return
    }

    let status = response.statusCode
    print("[capture] sent status=\(status)")

    // 200 (idempotent re-upload) and 201 (new record) are both success.
    guard status == 200 || status == 201 else {
      let detail = extractDetail(from: upload.accumulatedData)
      upload.continuation.resume(
        throwing: APIError.httpError(statusCode: status, detail: detail)
      )
      return
    }

    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let body = try decoder.decode(CaptureResponseBody.self, from: upload.accumulatedData)
      upload.continuation.resume(returning: body)
    } catch {
      upload.continuation.resume(throwing: error)
    }
  }

  /// Store the background-session completion handler delivered by `AppDelegate`.
  ///
  /// Called in PR 2 from `AppDelegate.application(_:handleEventsForBackgroundURLSession:…)`.
  /// The stored handler is called from `drainBackgroundCompletionHandlers()` after
  /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` signals that all
  /// pending events have been delivered.
  public func storeBackgroundCompletionHandler(
    _ handler: @escaping @Sendable () -> Void,
    forIdentifier identifier: String
  ) {
    backgroundCompletionHandlers[identifier] = handler
  }

  /// Call all stored background-session completion handlers on the main thread.
  ///
  /// Called by `UploadSessionDelegate.urlSessionDidFinishEvents(…)` via
  /// `Task { await api?.drainBackgroundCompletionHandlers() }`. Apple's docs
  /// require the handler to be called on the main thread.
  public func drainBackgroundCompletionHandlers() {
    let handlers = Array(backgroundCompletionHandlers.values)
    backgroundCompletionHandlers.removeAll()
    // Apple's documentation requires the completion handler to be called on
    // the main thread. `@Sendable` on the stored closures satisfies Swift 6
    // strict-concurrency checks when the array is captured across the actor boundary.
    Task { @MainActor in
      handlers.forEach { $0() }
    }
  }

  // MARK: - Runtime credential update (called by SettingsViewModel)

  /// Update the base URL and bearer token used for all subsequent API calls.
  ///
  /// Called by `SettingsViewModel` after the user saves new values in Settings
  /// and the Keychain has been updated.  Takes effect immediately for all API
  /// calls that start after this method returns — in-flight requests are
  /// unaffected (they already have their auth headers baked in).
  ///
  /// Background upload tasks use the token baked into the URLRequest at task-
  /// creation time; those are not retroactively updated.  For V1 this is
  /// acceptable — the user changes credentials rarely and can force-resync.
  public func updateCredentials(baseURL: URL, bearerToken: String) {
    self.baseURL = baseURL
    self.bearerToken = bearerToken
  }

  // MARK: - Temp file management

  /// Write the JSON-encoded request body to a temp file and return its URL.
  ///
  /// Background sessions require file-based upload tasks — `httpBody` is not
  /// delivered to the server when using `uploadTask(with:fromFile:)`. The body
  /// is still present on `request` (to preserve test compatibility) but the
  /// background path reads from the file.
  ///
  /// The filename is `<clientID>.upload-body` so it is:
  ///   - Diagnosable: you can inspect the file and see which capture it belongs to.
  ///   - Idempotent: re-writing the same payload produces the same filename.
  ///   - Sweepable: `sweepOrphanedTempFiles()` can find all `*.upload-body` files.
  private func writeBodyToTempFile(
    for payload: CapturePayload,
    request: URLRequest
  ) throws -> URL {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let body = CaptureRequestBody(
      clientID: payload.clientID,
      content: payload.content,
      sourceModality: payload.sourceModality,
      sourceDevice: payload.sourceDevice,
      language: payload.language,
      capturedAt: payload.capturedAt
    )
    let data = try encoder.encode(body)

    let tmpURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(payload.clientID.uuidString).upload-body")
    try data.write(to: tmpURL, options: .atomic)
    return tmpURL
  }

  /// Delete any `*.upload-body` temp files older than one hour.
  ///
  /// Call this on app launch (before enqueuing new tasks) to recover from
  /// crashes or OS memory-pressure evictions that left orphaned files behind.
  /// The one-hour threshold is conservative — any legitimate in-flight upload
  /// either completes or is replayed by the OS well within that window.
  public func sweepOrphanedTempFiles() {
    let tmp = FileManager.default.temporaryDirectory
    let cutoff = Date().addingTimeInterval(-3600)
    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        at: tmp,
        includingPropertiesForKeys: [.creationDateKey],
        options: .skipsHiddenFiles
      )
    else { return }

    for url in contents where url.pathExtension == "upload-body" {
      let creation = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
      if let creation, creation < cutoff {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  // MARK: - Test helpers (internal — @testable import only)

  /// Insert a `PendingUpload` with a live continuation directly into the
  /// actor's pending map. Used by `OracleAPIBridgeTests` to drive
  /// `completeTask` and `appendData` without going through a real URLSession.
  ///
  /// Tests pair this with `withCheckedThrowingContinuation`: the continuation
  /// is obtained inside the closure, passed to this method via a nested `Task`,
  /// and the test then drives `appendData` / `completeTask` to resolve it.
  func insertTestPendingUploadWithContinuation(
    taskID: Int,
    tempFileURL: URL,
    continuation: CheckedContinuation<CaptureResponseBody, Error>
  ) {
    pendingUploads[taskID] = PendingUpload(
      continuation: continuation,
      accumulatedData: Data(),
      tempFileURL: tempFileURL
    )
  }

  /// Number of stored background completion handlers (for assertions in tests).
  var backgroundHandlerCount: Int {
    backgroundCompletionHandlers.count
  }

  // MARK: - Helpers

  public func authorizedRequest(for url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    // bearerToken is already the Keychain-resolved value (set at init time via
    // Config.shared, or updated live by SettingsViewModel via
    // updateCredentials(baseURL:bearerToken:)).
    // TODO(auth-v2): Read the token fresh from Keychain on every call once
    //               the LAContext / biometric gate is added in V2.
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  /// Extract the `detail` string from a FastAPI-style JSON error body.
  ///
  /// FastAPI returns `{"detail": "…"}` for 4xx/5xx errors. Returns `nil`
  /// if the body is not JSON or does not contain a `detail` key.
  private func extractDetail(from data: Data) -> String? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let detail = json["detail"] as? String
    else { return nil }
    return detail
  }
}

// MARK: - API errors

/// Errors surfaced by `OracleAPI` network calls.
public enum APIError: Error, LocalizedError {
  case unexpectedResponse
  case httpError(statusCode: Int, detail: String?)

  public var errorDescription: String? {
    switch self {
    case .unexpectedResponse:
      return "Received an unexpected response from the server."
    case .httpError(let code, let detail):
      if let detail {
        return detail
      }
      return "Server returned HTTP \(code)."
    }
  }
}

// MARK: - Data transfer objects

public struct CapturePayload: Sendable {
  public let clientID: UUID
  public let content: String
  public let sourceModality: String   // "text" | "voice"
  public let sourceDevice: String     // "iphone"
  public let language: String         // BCP-47 language code, e.g. "en"
  public let capturedAt: Date

  public init(
    clientID: UUID,
    content: String,
    sourceModality: String,
    sourceDevice: String,
    language: String,
    capturedAt: Date
  ) {
    self.clientID = clientID
    self.content = content
    self.sourceModality = sourceModality
    self.sourceDevice = sourceDevice
    self.language = language
    self.capturedAt = capturedAt
  }
}

/// Wire format sent to POST /v1/captures.
///
/// `CodingKeys` maps Swift camelCase property names to the server's
/// snake_case JSON keys. Using explicit keys instead of `.convertToSnakeCase`
/// avoids the gotcha where `clientID` would encode as `client_i_d` rather
/// than `client_id`.
public struct CaptureRequestBody: Codable, Sendable {
  public let clientID: UUID
  public let content: String
  public let sourceModality: String
  public let sourceDevice: String
  public let language: String
  public let capturedAt: Date

  public init(
    clientID: UUID,
    content: String,
    sourceModality: String,
    sourceDevice: String,
    language: String,
    capturedAt: Date
  ) {
    self.clientID = clientID
    self.content = content
    self.sourceModality = sourceModality
    self.sourceDevice = sourceDevice
    self.language = language
    self.capturedAt = capturedAt
  }

  public enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case content
    case sourceModality = "source_modality"
    case sourceDevice = "source_device"
    case language
    case capturedAt = "captured_at"
  }
}

/// Wire format returned by POST /v1/captures.
///
/// Matches the server's `CaptureResponse` Pydantic model.
/// `id` and `clientID` are UUIDs; `capturedAt` is an ISO 8601 timestamp
/// (nullable: rows pre-dating migration 0010 may have `captured_at IS NULL`).
public struct CaptureResponseBody: Codable, Sendable {
  public let id: UUID
  public let clientID: UUID
  public let capturedAt: Date?
  public let enriched: Bool

  public enum CodingKeys: String, CodingKey {
    case id
    case clientID = "client_id"
    case capturedAt = "captured_at"
    case enriched
  }
}

/// Wire format sent to POST /v1/queries.
///
/// `minSimilarity` maps to the server's optional `min_similarity` float field
/// (range 0.0–1.0). When `nil` the key is omitted from the encoded JSON and
/// the server applies no similarity floor, preserving V1 behaviour.
///
/// `CodingKeys` is declared explicitly (matching the pattern in
/// `CaptureRequestBody`) so the mapping is obvious at a glance and immune to
/// future renames or `.convertToSnakeCase` strategy changes on the encoder.
public struct QueryRequestBody: Codable, Sendable {
  public let query: String
  public let limit: Int
  public let minSimilarity: Double?

  public init(query: String, limit: Int = 10, minSimilarity: Double? = nil) {
    self.query = query
    self.limit = limit
    self.minSimilarity = minSimilarity
  }

  public enum CodingKeys: String, CodingKey {
    case query
    case limit
    case minSimilarity = "min_similarity"
  }
}

/// A single ranked result returned by POST /v1/queries.
///
/// `matchedVia` is either `"whole"` (whole-memory cosine match) or `"chunk"`
/// (chunk-level match). When `"chunk"`, `matchedChunkIndex` carries the
/// 0-based chunk index from the server.
public struct QueryResult: Codable, Sendable {
  public let memoryID: UUID
  public let score: Float
  public let matchedVia: String         // "whole" | "chunk"
  public let matchedChunkIndex: Int?    // 0-based; nil when matchedVia == "whole"
  public let excerpt: String
  public let capturedAt: Date?
  public let sourceModality: String?

  public init(
    memoryID: UUID,
    score: Float,
    matchedVia: String,
    matchedChunkIndex: Int?,
    excerpt: String,
    capturedAt: Date?,
    sourceModality: String?
  ) {
    self.memoryID = memoryID
    self.score = score
    self.matchedVia = matchedVia
    self.matchedChunkIndex = matchedChunkIndex
    self.excerpt = excerpt
    self.capturedAt = capturedAt
    self.sourceModality = sourceModality
  }

  public enum CodingKeys: String, CodingKey {
    case memoryID = "memory_id"
    case score
    case matchedVia = "matched_via"
    case matchedChunkIndex = "matched_chunk_index"
    case excerpt
    case capturedAt = "captured_at"
    case sourceModality = "source_modality"
  }
}

/// Wire format returned by POST /v1/queries.
///
/// Matches the server's `QueryResponse` Pydantic model.
/// `answer` carries the RAG-synthesised answer string (added in #170). It is
/// `nil` when the server skips synthesis (e.g., no OpenAI key configured, or
/// the query matched no sources). The iOS client falls back to snippet-only
/// display when `answer` is nil — see `QueryView`.
/// `queryID` is the server-assigned UUID for this query, used to submit
/// feedback via POST /v1/queries/{id}/feedback (added in #209).
public struct QueryResponseBody: Codable, Sendable {
  public let answer: String?
  public let sources: [QueryResult]
  public let queryTokenCount: Int
  public let latencyMs: Double
  /// Server-assigned UUID for this query. Used as the target for
  /// `OracleAPI.submitFeedback(queryID:feedback:)`.
  public let queryID: UUID?

  public init(
    answer: String? = nil,
    sources: [QueryResult],
    queryTokenCount: Int,
    latencyMs: Double,
    queryID: UUID? = nil
  ) {
    self.answer = answer
    self.sources = sources
    self.queryTokenCount = queryTokenCount
    self.latencyMs = latencyMs
    self.queryID = queryID
  }

  public enum CodingKeys: String, CodingKey {
    case answer
    case sources
    case queryTokenCount = "query_token_count"
    case latencyMs = "latency_ms"
    case queryID = "query_id"
  }
}

// MARK: - Feedback

/// The user's thumbs-up or thumbs-down signal for a query result.
///
/// Raw string values match the server's expected `feedback` field values
/// (`"positive"` / `"negative"`) in POST /v1/queries/{id}/feedback.
public enum Feedback: String, Sendable, Codable, Equatable {
  case positive
  case negative
}

/// Wire format sent to POST /v1/queries/{id}/feedback.
public struct FeedbackRequestBody: Codable, Sendable {
  public let feedback: Feedback

  public init(feedback: Feedback) {
    self.feedback = feedback
  }
}

// MARK: - Recent query item

/// A single entry returned by GET /v1/queries/recent.
///
/// Matches the server's `RecentQueryItem` Pydantic model. `id` is the
/// server-assigned UUID for the query log row; `queryText` is the raw text
/// the user submitted; `createdAt` is the UTC timestamp the query was logged.
///
/// The chip strip in `QueryView` uses `queryText` as the chip label and
/// passes the same text to `QueryViewModel.tapRecentQuery(_:)` when the user
/// taps.
public struct RecentQueryItem: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let queryText: String
  public let createdAt: Date

  public init(id: UUID, queryText: String, createdAt: Date) {
    self.id = id
    self.queryText = queryText
    self.createdAt = createdAt
  }

  public enum CodingKeys: String, CodingKey {
    case id
    case queryText = "query_text"
    case createdAt = "created_at"
  }
}
