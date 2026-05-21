import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Smoke tests that exercise `GroveAPI` through the same `URLSession(configuration:)`
/// code path as the production singleton (`GroveAPI.shared`).
///
/// # Why this suite exists
///
/// `GroveAPITests` only exercises request-building (`captureRequest(for:)`) and
/// never actually calls `session.data(for:)`. The bug fixed in #87 — constructing
/// `GroveAPI.shared` with a background `URLSessionConfiguration`, then calling
/// the async `data(for:)` API — was invisible to that suite because the broken
/// code path was never executed.
///
/// These smoke tests use `StubURLProtocol` injected via the internal
/// `GroveAPI.init(baseURL:bearerToken:configuration:)` so that `URLSession` is
/// constructed the same way the singleton does it (via
/// `URLSession(configuration:)`), but with a `.default`-shaped config rather
/// than a `.background(...)` one. This makes the async `data(for:)` call legal
/// and exercises the full round-trip up to (but not including) the real network.
///
/// # Per-test isolation
///
/// All tests use `StubURLProtocol.makeSession(responder:)` (#422) which embeds a
/// unique stub ID in each session's `httpAdditionalHeaders`. The registry lookup in
/// `startLoading()` is keyed on that ID, so concurrent suites cannot corrupt each
/// other's responders. Tests in this suite run in parallel to verify the isolation
/// is race-free.
@Suite("GroveAPI Smoke Tests")
struct GroveAPISmokeTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "smoke-test-token"

  /// Build a `GroveAPI` whose `URLSession` uses the per-test-isolated config
  /// from `StubURLProtocol.makeSession`. Returns both the API and the teardown
  /// closure; callers must invoke teardown (typically via `defer`) after the test.
  private func makeAPI(
    responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)
  ) -> (GroveAPI, () -> Void) {
    let (config, teardown) = StubURLProtocol.makeSession(responder: responder)
    let api = GroveAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )
    return (api, teardown)
  }

  private func makePayload(content: String = "Buy oat milk.") -> CapturePayload {
    CapturePayload(
      clientID: UUID(),
      content: content,
      sourceModality: "text",
      sourceDevice: "iphone",
      language: "en",
      capturedAt: Date()
    )
  }

  // MARK: - Helpers

  private func loadFixture(_ name: String) throws -> Data {
    // .process("Fixtures") in Package.swift copies JSON files to the bundle
    // root — no subdirectory argument needed here.
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
      throw FixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
  }

  private enum FixtureError: Error {
    case notFound(String)
  }

  // MARK: - postCapture happy path

  @Test("postCapture happy path: stub returns 201, response decodes correctly")
  func postCaptureHappyPath() async throws {
    let captureURL = Self.baseURL.appendingPathComponent("v1/captures")
    let responseData = try loadFixture("capture_response")

    let (api, teardown) = makeAPI { [captureURL, responseData] _ in
      let resp = HTTPURLResponse(
        url: captureURL,
        statusCode: 201,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, responseData)
    }
    defer { teardown() }

    let result = try await api.postCapture(makePayload())

    // Spot-check the decoded fixture values.
    #expect(result.id == UUID(uuidString: "b3d6e4f2-1a2b-4c3d-8e9f-0a1b2c3d4e5f"))
    #expect(result.clientID == UUID(uuidString: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"))
    #expect(result.enriched == false)
  }

  // MARK: - postQuery happy path

  @Test("postQuery happy path: stub returns 200, results decode correctly")
  func postQueryHappyPath() async throws {
    let queryURL = Self.baseURL.appendingPathComponent("v1/queries")
    let responseData = try loadFixture("query_response")

    let (api, teardown) = makeAPI { [queryURL, responseData] _ in
      let resp = HTTPURLResponse(
        url: queryURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, responseData)
    }
    defer { teardown() }

    let result = try await api.postQuery("SwiftData local store")

    #expect(result.sources.count == 2)
    #expect(result.queryTokenCount == 7)
    #expect(result.latencyMs == 612.4)

    let first = try #require(result.sources.first)
    #expect(first.matchedVia == "whole")
    #expect(first.score > 0.9)
  }

  // MARK: - Network failure / HTTP error path

  @Test("postCapture HTTP 500 throws APIError.httpError(500, _)")
  func postCaptureHTTPError() async throws {
    let captureURL = Self.baseURL.appendingPathComponent("v1/captures")
    let errorBody = #"{"detail":"internal server error"}"#.data(using: .utf8)!

    let (api, teardown) = makeAPI { [captureURL, errorBody] _ in
      let resp = HTTPURLResponse(
        url: captureURL,
        statusCode: 500,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, errorBody)
    }
    defer { teardown() }

    do {
      _ = try await api.postCapture(makePayload())
      Issue.record("Expected APIError.httpError to be thrown, but postCapture succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 500)
      #expect(detail == "internal server error")
    }
  }

  // MARK: - Background session regression test (#87)

  /// Regression test for #87: constructing a URLSession with a background
  /// configuration and then calling async `data(for:)` triggers an NSException
  /// at runtime ("background session") that cannot be caught as a Swift `Error`.
  ///
  /// # What this test verifies
  ///
  /// The production singleton's `private init()` now uses `.default` (the fix
  /// from #87). This test confirms that path — constructing a session via
  /// `URLSession(configuration: .default)` and calling `data(for:)` — works
  /// correctly end-to-end, by using a `.default`-shaped config with
  /// `StubURLProtocol` injected. If someone regresses the singleton back to
  /// `.background(...)`, this test won't catch it directly (because
  /// `NSException` isn't a Swift `Error`), but it DOES prove that the
  /// `.default` path is green.
  ///
  /// # Why we don't test the background config directly
  ///
  /// `URLSession.data(for:)` raises an `NSException` (not a Swift `Error`)
  /// when called on a background-configured session. NSExceptions bypass
  /// Swift's `do/try/catch` and terminate the process. There is no portable
  /// way to catch an `NSException` in Swift without an Objective-C wrapper,
  /// and adding one would introduce test-only production complexity.
  ///
  /// Instead, we document the limitation here and rely on code review to keep
  /// the singleton's `private init()` using `.default`. The comment block in
  /// `GroveAPI.swift`'s `private init()` is the source of truth for that
  /// constraint.
  @Test("postCapture succeeds through URLSession(configuration: .default) path")
  func defaultConfigPathSucceeds() async throws {
    // This test is the affirmative half of the #87 regression guard: the
    // .default config + async data(for:) path must work end-to-end.
    let captureURL = Self.baseURL.appendingPathComponent("v1/captures")
    let responseData = try loadFixture("capture_response")

    let (api, teardown) = makeAPI { [captureURL, responseData] _ in
      let resp = HTTPURLResponse(
        url: captureURL,
        statusCode: 201,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, responseData)
    }
    defer { teardown() }

    // If this throws or crashes, the .default path is broken.
    let result = try await api.postCapture(makePayload())
    #expect(result.enriched == false)
  }

  // MARK: - Task EventKit linking (PATCH /v1/tasks/{id})
  //
  // Nested inside GroveAPISmokeTests. Cross-suite safety is provided by
  // per-test stub ID isolation (#422); no `.serialized` needed.

  private static let taskID = UUID(uuidString: "AABBCCDD-0000-0000-0000-000000000001")!
  private static let ekIdentifier = "EK-stub-identifier-789"

  private func taskResponse(
    id: UUID = GroveAPISmokeTests.taskID,
    ekIdentifier: String? = GroveAPISmokeTests.ekIdentifier
  ) -> Data {
    let identifierJSON: String
    if let ekIdentifier {
      identifierJSON = "\"\(ekIdentifier)\""
    } else {
      identifierJSON = "null"
    }
    let json = """
    {
      "id": "\(id.uuidString.lowercased())",
      "memory_id": "00000000-0000-0000-0000-000000000000",
      "description": "Call Theo about the demo",
      "due_date": null,
      "status": "open",
      "related_people": [],
      "eventkit_identifier": \(identifierJSON),
      "eventkit_linked_at": "2026-05-18T12:00:00Z"
    }
    """
    return Data(json.utf8)
  }

  @Test("patchTaskEventKit sends PATCH to /v1/tasks/{id}")
  func patchTaskEventKitMethod() async throws {
    // Use CaptureBox so the closure can capture and mutate it.
    let box = CaptureBox<URLRequest>()

    let (api, teardown) = makeAPI { request in
      box.value = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, taskResponse())
    }
    defer { teardown() }

    _ = try await api.patchTaskEventKit(
      taskID: Self.taskID,
      eventkitIdentifier: Self.ekIdentifier
    )

    #expect(box.value?.httpMethod == "PATCH")
    let expectedURL = Self.baseURL
      .appendingPathComponent("v1/tasks/\(Self.taskID.uuidString.lowercased())")
    #expect(box.value?.url == expectedURL)
  }

  @Test("patchTaskEventKit encodes eventkit_identifier in body")
  func patchTaskEventKitBody() async throws {
    let box = CaptureBox<Data>()

    let (api, teardown) = makeAPI { request in
      // URLSession delivers the body as an HTTPBodyStream when using data(for:)
      // through URLProtocol — httpBody is nil. Read the stream here.
      if let stream = request.httpBodyStream {
        stream.open()
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
          let read = stream.read(buffer, maxLength: 4096)
          if read > 0 { data.append(buffer, count: read) }
        }
        stream.close()
        box.value = data
      } else {
        box.value = request.httpBody
      }
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, taskResponse())
    }
    defer { teardown() }

    _ = try await api.patchTaskEventKit(
      taskID: Self.taskID,
      eventkitIdentifier: Self.ekIdentifier
    )

    guard let bodyData = box.value,
          let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String]
    else {
      Issue.record("Request body was missing or not JSON")
      return
    }
    #expect(json["eventkit_identifier"] == Self.ekIdentifier)
  }

  @Test("patchTaskEventKit 200: returns decoded TaskDTO with identifier")
  func patchTaskEventKitHappyPath() async throws {
    let (api, teardown) = makeAPI { [self] request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, taskResponse())
    }
    defer { teardown() }

    let task = try await api.patchTaskEventKit(
      taskID: Self.taskID,
      eventkitIdentifier: Self.ekIdentifier
    )

    #expect(task.id == Self.taskID)
    #expect(task.eventkitIdentifier == Self.ekIdentifier)
  }

  @Test("patchTaskEventKit 409: throws TaskLinkingError.alreadyLinked with existing identifier")
  func patchTaskEventKit409() async throws {
    let existingID = "EK-pre-existing-conflict"
    let conflictBody = Data("""
    {
      "detail": {
        "detail": "Task already linked to a reminder.",
        "existing_identifier": "\(existingID)"
      }
    }
    """.utf8)

    let (api, teardown) = makeAPI { [conflictBody] request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 409,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, conflictBody)
    }
    defer { teardown() }

    do {
      _ = try await api.patchTaskEventKit(
        taskID: Self.taskID,
        eventkitIdentifier: Self.ekIdentifier
      )
      Issue.record("Expected TaskLinkingError.alreadyLinked but no error was thrown")
    } catch let e as TaskLinkingError {
      if case .alreadyLinked(let id) = e {
        #expect(id == existingID)
      } else {
        Issue.record("Unexpected TaskLinkingError case: \(e)")
      }
    }
  }

  @Test("patchTaskEventKit 404: throws APIError.httpError(404)")
  func patchTaskEventKit404() async throws {
    let notFoundBody = Data("{\"detail\": \"Task not found\"}".utf8)

    let (api, teardown) = makeAPI { [notFoundBody] request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 404,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, notFoundBody)
    }
    defer { teardown() }

    do {
      _ = try await api.patchTaskEventKit(
        taskID: Self.taskID,
        eventkitIdentifier: Self.ekIdentifier
      )
      Issue.record("Expected an error but none was thrown")
    } catch let e as APIError {
      if case .httpError(let code, _) = e {
        #expect(code == 404)
      } else {
        Issue.record("Unexpected APIError: \(e)")
      }
    }
  }

  // MARK: - TaskDTO nullability regression (#392)

  /// Regression test: server returns `null` for `status` and `related_people`
  /// when the enricher has not yet populated those fields. Swift's JSONDecoder
  /// throws `valueNotFound` for non-optional properties — this test guards
  /// against that crash.
  @Test("TaskDTO decodes null status and related_people to nil")
  func taskDTONullStatusAndRelatedPeople() throws {
    let json = Data("""
    {
      "id": "AABBCCDD-0000-0000-0000-000000000001",
      "memory_id": "00000000-0000-0000-0000-000000000000",
      "description": "Send the report",
      "due_date": null,
      "status": null,
      "related_people": null,
      "eventkit_identifier": null,
      "eventkit_linked_at": null
    }
    """.utf8)

    let decoder = JSONDecoder()
    let task = try decoder.decode(TaskDTO.self, from: json)
    #expect(task.status == nil)
    #expect(task.relatedPeople == nil)
  }

  /// Confirm that a task with non-null status and related_people still decodes
  /// correctly after the nullability change.
  @Test("TaskDTO decodes non-null status and related_people")
  func taskDTONonNullStatusAndRelatedPeople() throws {
    let json = Data("""
    {
      "id": "AABBCCDD-0000-0000-0000-000000000002",
      "memory_id": "00000000-0000-0000-0000-000000000000",
      "description": "Call Theo about the demo",
      "due_date": null,
      "status": "open",
      "related_people": ["Theo"],
      "eventkit_identifier": null,
      "eventkit_linked_at": null
    }
    """.utf8)

    let decoder = JSONDecoder()
    let task = try decoder.decode(TaskDTO.self, from: json)
    #expect(task.status == "open")
    #expect(task.relatedPeople == ["Theo"])
  }

  @Test("patchTaskEventKit includes Authorization header")
  func patchTaskEventKitAuthorizationHeader() async throws {
    let box = CaptureBox<URLRequest>()

    let (api, teardown) = makeAPI { request in
      box.value = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, taskResponse())
    }
    defer { teardown() }

    _ = try await api.patchTaskEventKit(
      taskID: Self.taskID,
      eventkitIdentifier: Self.ekIdentifier
    )

    let authHeader = box.value?.value(forHTTPHeaderField: "Authorization")
    #expect(authHeader == "Bearer \(Self.token)")
  }
}
