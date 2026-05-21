import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

// MARK: - GroveAPIDeleteTaskTests
//
// Tests for `GroveAPI.deleteTask(id:)` — DELETE /v1/tasks/{id}.
//
// Covers R2.2:
//   1. Happy path: 204 No Content completes without throwing.
//   2. 404 response: throws APIError.httpError(404, _).
//   3. URL shape: DELETE to /v1/tasks/{uuid} with Authorization header.
//   4. 401 unauthorized: throws APIError.httpError(401, _).
//   5. 500 server error: throws APIError.httpError(500, _).
//
// CI placement: GroveCoreTests (make ios-test-core).

@Suite("GroveAPI — deleteTask")
struct GroveAPIDeleteTaskTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "delete-task-token"
  private static let taskID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")!

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

  private func deleteURL(for id: UUID) -> URL {
    Self.baseURL.appendingPathComponent("v1/tasks/\(id.uuidString.lowercased())")
  }

  // MARK: - Happy path: 204 No Content

  @Test("deleteTask returns void on 204 No Content")
  func deleteTaskHappyPath() async throws {
    let url = deleteURL(for: Self.taskID)

    let (api, teardown) = makeAPI { [url] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { teardown() }

    // Should complete without throwing.
    try await api.deleteTask(id: Self.taskID)
  }

  // MARK: - 404: task not found (or not owned by caller)

  @Test("deleteTask throws httpError(404, _) when task is not found")
  func deleteTask404() async throws {
    let url = deleteURL(for: Self.taskID)
    let body = #"{"detail":"task not found"}"#.data(using: .utf8)!

    let (api, teardown) = makeAPI { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { teardown() }

    do {
      try await api.deleteTask(id: Self.taskID)
      Issue.record("Expected APIError.httpError(404, _) but deleteTask succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 404)
      #expect(detail == "task not found")
    }
  }

  // MARK: - 401: unauthorized

  @Test("deleteTask throws httpError(401, _) when token is invalid")
  func deleteTask401() async throws {
    let url = deleteURL(for: Self.taskID)
    let body = #"{"detail":"unauthorized"}"#.data(using: .utf8)!

    let (api, teardown) = makeAPI { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 401,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { teardown() }

    do {
      try await api.deleteTask(id: Self.taskID)
      Issue.record("Expected APIError.httpError(401, _) but deleteTask succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, _) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 401)
    }
  }

  // MARK: - 500: server error

  @Test("deleteTask throws httpError(500, _) on generic server error")
  func deleteTask500() async throws {
    let url = deleteURL(for: Self.taskID)
    let body = #"{"detail":"internal server error"}"#.data(using: .utf8)!

    let (api, teardown) = makeAPI { [url, body] _ in
      let resp = HTTPURLResponse(
        url: url,
        statusCode: 500,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, body)
    }
    defer { teardown() }

    do {
      try await api.deleteTask(id: Self.taskID)
      Issue.record("Expected APIError.httpError(500, _) but deleteTask succeeded.")
    } catch let error as APIError {
      guard case .httpError(let statusCode, let detail) = error else {
        Issue.record("Expected APIError.httpError but got \(error).")
        return
      }
      #expect(statusCode == 500)
      #expect(detail == "internal server error")
    }
  }

  // MARK: - Request shape

  @Test("deleteTask sends DELETE to /v1/tasks/{id} with correct Authorization header")
  func deleteTaskRequestShape() async throws {
    let expectedURL = deleteURL(for: Self.taskID)
    let box = CaptureBox<URLRequest>()

    let (api, teardown) = makeAPI { [expectedURL] request in
      box.value = request
      let resp = HTTPURLResponse(
        url: expectedURL,
        statusCode: 204,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (resp, Data())
    }
    defer { teardown() }

    try await api.deleteTask(id: Self.taskID)

    let req = try #require(box.value)
    #expect(req.httpMethod == "DELETE")
    #expect(req.url == expectedURL)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
  }
}
