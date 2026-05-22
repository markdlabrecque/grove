import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

// MARK: - GroveAPIListTasksV2Tests
//
// Tests for `GroveAPI.listTasks()` — GET /v1/tasks (no filter parameters).
// This is the spec-02 replacement for the spec-01 listTasksByMemoryIDs tests.
// The spec-01 file (GroveAPIListTasksTests.swift) will be removed in Part 3 (#453).
//
// Covers R2.1:
//   1. Happy path: stub returns 200 with a [TaskDTO] array → decoded correctly.
//   2. URL shape: no query parameters on the request.
//   3. 401 response: throws APIError.httpError(401, _).
//   4. Authorization header is present on the outbound request.
//   5. Empty array result: 200 with [] returns an empty Swift array.
//
// CI placement: GroveCoreTests (make ios-test-core).

@Suite("GroveAPI — listTasks (spec-02)")
struct GroveAPIListTasksV2Tests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "list-tasks-v2-token"

  private static let memoryID1 = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
  private static let memoryID2 = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!
  private static let taskID1   = UUID(uuidString: "AAAA1111-0000-0000-0000-000000000001")!
  private static let taskID2   = UUID(uuidString: "AAAA2222-0000-0000-0000-000000000002")!

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

  private func twoTasksJSON() -> Data {
    Data("""
    [
      {
        "id": "\(Self.taskID1.uuidString.lowercased())",
        "memory_id": "\(Self.memoryID1.uuidString.lowercased())",
        "description": "Buy oat milk",
        "due_date": null,
        "status": "open",
        "related_people": [],
        "eventkit_identifier": null,
        "eventkit_linked_at": null
      },
      {
        "id": "\(Self.taskID2.uuidString.lowercased())",
        "memory_id": "\(Self.memoryID2.uuidString.lowercased())",
        "description": "Call Theo",
        "due_date": "2026-06-01",
        "status": "open",
        "related_people": ["Theo"],
        "eventkit_identifier": null,
        "eventkit_linked_at": null
      }
    ]
    """.utf8)
  }

  // MARK: - Happy path

  @Test("listTasks: stub returns 200 with two TaskDTOs → decoded correctly")
  func happyPath() async throws {
    let responseData = twoTasksJSON()
    let (api, teardown) = makeAPI { request in
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, responseData)
    }
    defer { teardown() }

    let result = try await api.listTasks()

    #expect(result.count == 2)
    #expect(result[0].id == Self.taskID1)
    #expect(result[0].memoryID == Self.memoryID1)
    #expect(result[0].description == "Buy oat milk")
    #expect(result[1].id == Self.taskID2)
    #expect(result[1].dueDate == "2026-06-01")
    #expect(result[1].relatedPeople == ["Theo"])
  }

  // MARK: - Empty array result

  @Test("listTasks: stub returns 200 with [] → empty Swift array")
  func emptyResult() async throws {
    let (api, teardown) = makeAPI { request in
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (resp, Data("[]".utf8))
    }
    defer { teardown() }

    let result = try await api.listTasks()
    #expect(result.isEmpty)
  }

  // MARK: - URL shape

  @Test("listTasks: GET /v1/tasks with no query parameters")
  func urlShape() async throws {
    let box = CaptureBox<URLRequest>()

    let (api, teardown) = makeAPI { request in
      box.value = request
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, Data("[]".utf8))
    }
    defer { teardown() }

    _ = try await api.listTasks()

    let req = try #require(box.value)
    #expect(req.httpMethod == "GET")

    let url = try #require(req.url)
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    // No query parameters should be present.
    let queryItems = comps?.queryItems ?? []
    #expect(queryItems.isEmpty, "listTasks must send no query parameters")

    // Path should be exactly /v1/tasks.
    #expect(url.path == "/v1/tasks")
  }

  // MARK: - 401 unauthorized

  @Test("listTasks: 401 response throws APIError.httpError(401, _)")
  func http401ThrowsError() async throws {
    let errorBody = Data(#"{"detail":"unauthorized"}"#.utf8)

    let (api, teardown) = makeAPI { request in
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 401,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, errorBody)
    }
    defer { teardown() }

    do {
      _ = try await api.listTasks()
      Issue.record("Expected APIError.httpError(401) to be thrown")
    } catch let error as APIError {
      guard case .httpError(let code, _) = error else {
        Issue.record("Unexpected APIError: \(error)")
        return
      }
      #expect(code == 401)
    }
  }

  // MARK: - Authorization header

  @Test("listTasks: request includes Authorization header")
  func authorizationHeader() async throws {
    let box = CaptureBox<URLRequest>()

    let (api, teardown) = makeAPI { request in
      box.value = request
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, Data("[]".utf8))
    }
    defer { teardown() }

    _ = try await api.listTasks()

    let authHeader = box.value?.value(forHTTPHeaderField: "Authorization")
    #expect(authHeader == "Bearer \(Self.token)")
  }
}
