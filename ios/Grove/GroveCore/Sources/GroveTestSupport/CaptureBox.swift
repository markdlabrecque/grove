/// A thread-safe reference wrapper used in tests to capture values from
/// `@Sendable` closures (e.g. `StubURLProtocol` responders) without
/// requiring the captured variable to be `Sendable` itself.
///
/// Declare one `CaptureBox` per value you want to observe, pass it into the
/// stub closure via capture list, and read `box.value` after `await`:
///
/// ```swift
/// let box = CaptureBox<URLRequest>()
/// let (api, teardown) = makeAPI { request in
///   box.value = request
///   return (response, data)
/// }
/// defer { teardown() }
/// try await api.someCall()
/// let req = try #require(box.value)
/// ```
public final class CaptureBox<T>: @unchecked Sendable {
  public var value: T?
  public init() {}
}
