import Foundation

// MARK: - Timeout safety

/// Thrown by `withBridgeTimeout` when a delegate-bridge continuation is not
/// resumed within the allowed window. Turns a silent hang into a fast failure.
///
/// Both `GroveCoreTests` and the Xcode-project-side `GroveTests` bundle
/// import this type from the shared `GroveTestSupport` module, which is the
/// single source of truth.
public struct BridgeTimeoutError: Error, CustomStringConvertible {
  public let seconds: Double
  public var description: String {
    "Bridge continuation not resumed within \(seconds) s — likely a mis-keyed task ID or missing resume path."
  }
}

/// Run `operation` and throw `BridgeTimeoutError` if it does not complete
/// within `seconds`. Used to guard every `withCheckedContinuation` /
/// `withCheckedThrowingContinuation` sentinel site in the test suite so a
/// stuck continuation fails the test in bounded time instead of hanging the
/// runner.
public func withBridgeTimeout<T: Sendable>(
  seconds: Double = 5,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw BridgeTimeoutError(seconds: seconds)
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}
