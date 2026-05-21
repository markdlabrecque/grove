import Testing
import Foundation
import GroveTestSupport
@testable import GroveCore

// MARK: - GroveAPIListTasksByEventKitIDsTests
//
// Tests for `GroveAPI.listTasksByEventKitIdentifiers(_:)` (#439):
//   1. Happy path: stub returns 200 with a [TaskDTO] array → decoded correctly.
//   2. Empty input: no network call made, returns [].
//   3. URL shape: eventkit_identifiers joined as comma-separated, query-encoded.
//   4. 422 response: throws APIError.httpError(422, _).
//   5. Authorization header is present on the outbound request.
//
// CI placement: GroveCoreTests (make ios-test-core).

@Suite("GroveAPI — listTasksByEventKitIdentifiers")
struct GroveAPIListTasksByEventKitIDsTests {

  // MARK: - Fixtures

  private static let baseURL = URL(string: "https://grove.example.ts.net")!
  private static let token = "list-tasks-by-ek-token"

  private static let memoryID1 = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
  private static let memoryID2 = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!
  private static let taskID1   = UUID(uuidString: "BBBB1111-0000-0000-0000-000000000001")!
  private static let taskID2   = UUID(uuidString: "BBBB2222-0000-0000-0000-000000000002")!

  private static let ekIdentifier1 = "EK-ABC-DEF-001"
  private static let ekIdentifier2 = "EK-XYZ-GHI-002"

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

  /// Build a minimal JSON array of two TaskDTO objects that include
  /// `eventkit_identifier` fields, for use in stub responses.
  private func twoTasksJSON() -> Data {
    Data("""
    [
      {
        "id": "\(Self.taskID1.uuidString.lowercased())",
        "memory_id": "\(Self.memoryID1.uuidString.lowercased())",
        "description": "Call Theo",
        "due_date": null,
        "status": "open",
        "related_people": [],
        "eventkit_identifier": "\(Self.ekIdentifier1)",
        "eventkit_linked_at": null
      },
      {
        "id": "\(Self.taskID2.uuidString.lowercased())",
        "memory_id": "\(Self.memoryID2.uuidString.lowercased())",
        "description": "Buy oat milk",
        "due_date": null,
        "status": "open",
        "related_people": [],
        "eventkit_identifier": "\(Self.ekIdentifier2)",
        "eventkit_linked_at": null
      }
    ]
    """.utf8)
  }

  // MARK: - Happy path

  @Test("listTasksByEventKitIdentifiers: stub returns 200 with two TaskDTOs → decoded correctly")
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

    let result = try await api.listTasksByEventKitIdentifiers([Self.ekIdentifier1, Self.ekIdentifier2])

    #expect(result.count == 2)
    #expect(result[0].id == Self.taskID1)
    #expect(result[0].memoryID == Self.memoryID1)
    #expect(result[0].eventkitIdentifier == Self.ekIdentifier1)
    #expect(result[1].id == Self.taskID2)
    #expect(result[1].memoryID == Self.memoryID2)
    #expect(result[1].eventkitIdentifier == Self.ekIdentifier2)
  }

  // MARK: - Empty input short-circuit

  @Test("listTasksByEventKitIdentifiers: empty input returns [] without making a network call")
  func emptyInputNoNetworkCall() async throws {
    var requestMade = false
    let (api, teardown) = makeAPI { _ in
      requestMade = true
      // This should never be called; return a dummy response.
      let resp = HTTPURLResponse(
        url: Self.baseURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, Data("[]".utf8))
    }
    defer { teardown() }

    let result = try await api.listTasksByEventKitIdentifiers([])

    #expect(result.isEmpty)
    #expect(requestMade == false, "No network call should be made for empty input")
  }

  // MARK: - URL shape

  @Test("listTasksByEventKitIdentifiers: eventkit_identifiers query string is comma-joined and query-encoded")
  func urlShape() async throws {
    let box = CaptureBox<URL>()

    let (api, teardown) = makeAPI { request in
      box.value = request.url
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, Data("[]".utf8))
    }
    defer { teardown() }

    _ = try await api.listTasksByEventKitIdentifiers([Self.ekIdentifier1, Self.ekIdentifier2])

    guard let url = box.value else {
      Issue.record("No request URL captured")
      return
    }

    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let ekParam = comps?.queryItems?.first(where: { $0.name == "eventkit_identifiers" })?.value
    #expect(ekParam != nil, "eventkit_identifiers query parameter must be present")

    // Both identifiers should appear in the comma-separated value (order-agnostic).
    let paramValue = try #require(ekParam)
    let parts = paramValue.split(separator: ",").map(String.init)
    #expect(parts.count == 2)
    #expect(parts.contains(Self.ekIdentifier1))
    #expect(parts.contains(Self.ekIdentifier2))
  }

  // MARK: - 422 error

  @Test("listTasksByEventKitIdentifiers: 422 response throws APIError.httpError(422, _)")
  func http422ThrowsError() async throws {
    let errorBody = Data(#"{"detail": "eventkit_identifiers and memory_ids cannot both be supplied"}"#.utf8)

    let (api, teardown) = makeAPI { request in
      let resp = HTTPURLResponse(
        url: request.url!,
        statusCode: 422,
        httpVersion: nil,
        headerFields: nil
      )!
      return (resp, errorBody)
    }
    defer { teardown() }

    do {
      _ = try await api.listTasksByEventKitIdentifiers([Self.ekIdentifier1])
      Issue.record("Expected APIError.httpError(422) to be thrown")
    } catch let error as APIError {
      guard case .httpError(let code, _) = error else {
        Issue.record("Unexpected APIError: \(error)")
        return
      }
      #expect(code == 422)
    }
  }

  // MARK: - Authorization header

  @Test("listTasksByEventKitIdentifiers: request includes Authorization header")
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

    _ = try await api.listTasksByEventKitIdentifiers([Self.ekIdentifier1])

    let authHeader = box.value?.value(forHTTPHeaderField: "Authorization")
    #expect(authHeader == "Bearer \(Self.token)")
  }
}
