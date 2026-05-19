import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

/// Tests for `GroveAPI.patchTaskEventKit` — PATCH /v1/tasks/{id}.
///
/// # CI placement
///
/// Lives in `GroveCoreTests` (SPM target) so it is covered by
/// `make ios-test-core`. Uses `StubURLProtocol` for all network I/O.
///
/// # Serialization
///
/// `StubURLProtocol.responder` is a class-level static, so tests must
/// not run concurrently — `@Suite(.serialized)` opts out of the parallel runner.
@Suite("GroveAPI task EventKit linking", .serialized)
struct GroveAPITaskTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "task-test-token"
  private static let taskID = UUID(uuidString: "AABBCCDD-0000-0000-0000-000000000001")!
  private static let ekIdentifier = "EK-stub-identifier-789"

  private func makeAPI() -> GroveAPI {
    let config = URLSessionConfiguration.default
    config.protocolClasses = [StubURLProtocol.self]
    return GroveAPI(
      baseURL: Self.baseURL,
      bearerToken: Self.token,
      configuration: config
    )
  }

  private func taskResponse(
    id: UUID = GroveAPITaskTests.taskID,
    ekIdentifier: String? = GroveAPITaskTests.ekIdentifier
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

  // MARK: - PATCH request shape

  @Test("patchTaskEventKit sends PATCH to /v1/tasks/{id}")
  func patchRequestMethod() async throws {
    var capturedRequest: URLRequest?
    StubURLProtocol.responder = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, taskResponse())
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
    _ = try await api.patchTaskEventKit(
      taskID: Self.taskID,
      eventkitIdentifier: Self.ekIdentifier
    )

    #expect(capturedRequest?.httpMethod == "PATCH")
    let expectedURL = Self.baseURL
      .appendingPathComponent("v1/tasks/\(Self.taskID.uuidString.lowercased())")
    #expect(capturedRequest?.url == expectedURL)
  }

  @Test("patchTaskEventKit encodes eventkit_identifier in body")
  func patchRequestBody() async throws {
    var capturedRequest: URLRequest?
    StubURLProtocol.responder = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, taskResponse())
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
    _ = try await api.patchTaskEventKit(
      taskID: Self.taskID,
      eventkitIdentifier: Self.ekIdentifier
    )

    guard let bodyData = capturedRequest?.httpBody,
          let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: String]
    else {
      Issue.record("Request body was missing or not JSON")
      return
    }
    #expect(json["eventkit_identifier"] == Self.ekIdentifier)
  }

  // MARK: - 200 happy path

  @Test("patchTaskEventKit 200: returns decoded TaskDTO with identifier")
  func patchHappyPath() async throws {
    StubURLProtocol.responder = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, taskResponse())
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
    let task = try await api.patchTaskEventKit(
      taskID: Self.taskID,
      eventkitIdentifier: Self.ekIdentifier
    )

    #expect(task.id == Self.taskID)
    #expect(task.eventkitIdentifier == Self.ekIdentifier)
  }

  // MARK: - 409 conflict

  @Test("patchTaskEventKit 409: throws TaskLinkingError.alreadyLinked with existing identifier")
  func patch409Conflict() async throws {
    let existingID = "EK-pre-existing-conflict"
    let conflictBody = Data("""
    {
      "detail": {
        "detail": "Task already linked to a reminder.",
        "existing_identifier": "\(existingID)"
      }
    }
    """.utf8)

    StubURLProtocol.responder = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 409,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, conflictBody)
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
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

  // MARK: - 404

  @Test("patchTaskEventKit 404: throws APIError.httpError(404)")
  func patch404() async throws {
    StubURLProtocol.responder = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 404,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, Data("{\"detail\": \"Task not found\"}".utf8))
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
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

  // MARK: - Authorization header

  @Test("patchTaskEventKit includes Authorization header")
  func patchAuthorizationHeader() async throws {
    var capturedRequest: URLRequest?
    StubURLProtocol.responder = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, taskResponse())
    }
    defer { StubURLProtocol.responder = nil }

    let api = makeAPI()
    _ = try await api.patchTaskEventKit(
      taskID: Self.taskID,
      eventkitIdentifier: Self.ekIdentifier
    )

    let authHeader = capturedRequest?.value(forHTTPHeaderField: "Authorization")
    #expect(authHeader == "Bearer \(Self.token)")
  }
}
