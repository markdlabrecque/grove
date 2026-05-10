# V2 Spike: Background URLSession + URLSessionDataDelegate Pipeline

**Ticket:** #89
**Status:** Ready for review
**Author:** Kai (iOS)
**Date:** 2026-05-10

---

### 1. Problem statement

V1 has two user-visible failure modes that V2 must eliminate:

**(a) Tap Save, background the app.** The user types a capture, taps Save, and immediately locks the phone — the canonical "quick capture" use case from PRD §5. V1's `OracleAPI.postCapture` runs over a `.default` URLSession. When the app suspends, any in-flight `data(for:)` task is torn down by the OS. The capture is lost. No error surfaces; the user has no indication anything went wrong.

**(b) Tap Save while offline.** The Tailscale tunnel is down, the server is unreachable, or the phone is on a plane. V1's `postCapture` throws immediately; `CaptureViewModel.save()` catches it, surfaces an alert, and then discards the payload once the user dismisses. The capture exists nowhere. The user must retype it.

Both failures are silent from the user's perspective when they look at the app later. The PRD's 99%+ capture success rate (§4, Phase 1 KPI) is not achievable with V1's network layer. The `TODO(offline)` comment at `OracleAPI.swift:83` documents exactly this.

---

### 2. Current state (V1 baseline)

`OracleAPI` (post-#87) is a Swift `actor` with a single `URLSession` created from `.default` configuration. `postCapture` calls `session.data(for: request)` — the async/await convenience method. The `private init()` singleton builds the session; two additional initialisers exist for testing, including the `configuration:`-accepting one added in #88 to enable `StubURLProtocol` injection.

The `TODO(offline)` at line 83 explicitly defers:
- SwiftData persistence of failed captures
- NWPathMonitor retry on "satisfied"
- `client_id` idempotency (already server-side; iOS just needs to reuse the same UUID)
- Migration to background `URLSessionConfiguration` with a delegate pipeline

That comment is the authoritative scope statement for this spike.

---

### 3. The crux constraint

Three Apple platform facts that shape every downstream decision — internalise them before reading the design.

**Background sessions only support file-based upload tasks.** `URLSessionConfiguration.background(withIdentifier:)` accepts `uploadTask(with:fromFile:)` and `downloadTask`. It does not accept `dataTask`, `dataTask(with:completionHandler:)`, or the async `data(for:)` convenience. This means the JSON body that V1 builds via `JSONEncoder` and places in `request.httpBody` cannot be used directly. It must first be written to a temp file on disk, then handed to `uploadTask(with:fromFile:)`. See [Apple's background session documentation](https://developer.apple.com/documentation/foundation/urlsession/1411418-uploadtask).

That introduces disk I/O into the hot path (write before every upload), a lifecycle question (when is it safe to delete the temp file?), and a new failure surface: sandbox storage limits, disk-full conditions, and file-not-found errors if the OS cleans the temp directory between scheduling the task and executing it. All three are manageable, but the implementer must handle them explicitly — they don't surface as `NSURLErrorDomain` errors, they surface as `NSCocoaErrorDomain` file errors before the network layer is ever reached.

**`URLProtocol` subclasses cannot be registered on background sessions.** The `StubURLProtocol` mechanism used in `OracleAPISmokeTests` works by registering a custom protocol handler via `URLSessionConfiguration.protocolClasses`. Background session configurations [ignore `protocolClasses` entirely](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/1411050-protocolclasses). There is no way to inject a stub into a background session. This is a hard test-coverage constraint: the OS-relaunch path cannot be exercised by unit or integration tests. Manual device testing is the only coverage for it.

**Async/await is not available on background sessions.** The `urlSession(_:task:didCompleteWithError:)` delegate callback is the only way to receive completion events from a background session. There is no `await`-able equivalent. The entire callback chain is delegate-based, which means a bridge is needed to restore async call-site ergonomics at the `postCapture` API surface.

These three facts are load-bearing for every decision below.

---

### 4. Apple's mandated lifecycle integration

**`application(_:handleEventsForBackgroundURLSession:completionHandler:)`** is the `UIApplicationDelegate` method the OS calls when it relaunches or wakes the app to deliver upload completion events. The OS passes an identifier (matching the one used to create the background session) and a completion handler. The app **must** store that completion handler and call it — not in this method, but after `urlSessionDidFinishEvents(forBackgroundURLSession:)` fires on the session's delegate, which signals that all pending events have been delivered. Failing to call the handler triggers an OS watchdog kill within seconds. Reference: [Handling background events for URLSession](https://developer.apple.com/documentation/foundation/url_loading_system/downloading_files_in_the_background#3899567).

**SwiftUI `@main` does not expose `UIApplicationDelegate` methods.** `OracleApp` is a `@main struct OracleApp: App`. The SwiftUI `App` lifecycle has no `application(_:handleEventsForBackgroundURLSession:)` equivalent. The solution is `@UIApplicationDelegateAdaptor`, which bridges a `UIApplicationDelegate` subclass into the SwiftUI app lifecycle. The adaptor lives in `OracleApp.swift`:

```swift
// OracleApp.swift
import SwiftUI

@main
struct OracleApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    // Hand the handler to the API actor, which stores it until
    // urlSessionDidFinishEvents fires.
    Task {
      await OracleAPI.shared.storeBackgroundCompletionHandler(
        completionHandler,
        forIdentifier: identifier
      )
    }
  }
}
```

`AppDelegate.swift` lives alongside `OracleApp.swift` in `ios/Oracle/Oracle/`.

**`sessionSendsLaunchEvents = true`** (the default for background sessions) tells the OS to relaunch the app when uploads complete while the app is terminated. Leave it at the default `true`. Setting it to `false` would silently drop completions after a force-kill and break the airplane-mode → reconnect scenario.

**`isDiscretionary = false`** (the default). This means the OS schedules the upload as soon as connectivity allows, rather than deferring to an opportunistic window. For a capture app where "did my thought land?" is the core reliability promise, non-discretionary is correct. Setting `isDiscretionary = true` would be appropriate for large media uploads where timing is flexible; it is wrong here.

**`waitsForConnectivity = true`** must be set explicitly on the background configuration. Without it, a task enqueued while offline fails immediately with `NSURLErrorNotConnectedToInternet` rather than waiting for connectivity to return. With it, the task is held by the OS until a path becomes available — this is the mechanism that handles case (b) from §1 without any NWPathMonitor involvement at the URLSession level. However: `waitsForConnectivity` covers the "already enqueued, now waiting" case. It does not cover the "user tapped Save while offline and the app persisted nothing" case — that requires the SwiftData queue in §6.

The `CaptureViewModel.saveStatus` spinner should reflect the local-persist-and-enqueue latency only, not network latency. Once the payload is written to SwiftData and an `uploadTask` is enqueued, the UI should confirm success. The user does not wait for the server. This is already the intent of the `TODO(offline)` comment; it just isn't implemented.

---

### 5. Async/await bridge design

The delegate callbacks arrive on the URLSession's delegateQueue (a serial `OperationQueue` the session owns). The call site awaits `postCapture`. The bridge connects them via `withCheckedThrowingContinuation`.

**Recommended approach: continuation map keyed by `taskIdentifier`.**

```swift
// MARK: - Pending upload tracking

struct PendingUpload {
  var continuation: CheckedContinuation<CaptureResponseBody, Error>
  var accumulatedData: Data
  let tempFileURL: URL   // deleted on terminal completion (success or non-retryable error)
}
```

The `OracleAPI` actor holds:

```swift
private var pendingUploads: [Int: PendingUpload] = [:]
```

`postCapture` writes the JSON body to a temp file, creates the `uploadTask`, stores the continuation in the map keyed by `task.taskIdentifier`, and then calls `task.resume()`:

```swift
public func postCapture(_ payload: CapturePayload) async throws -> CaptureResponseBody {
  let request = try captureRequest(for: payload)
  let tempURL = try writeBodyToTempFile(for: payload)

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
```

`writeBodyToTempFile` encodes the payload via `JSONEncoder` and writes it to `FileManager.default.temporaryDirectory`. The filename is the `payload.clientID.uuidString` so temp files are idempotent and diagnosable.

**The delegate class** is a non-isolated `NSObject` that holds a weak reference to the actor. It cannot be the actor itself because `URLSessionDataDelegate` requires an `NSObject` subclass, and Swift actors cannot inherit from `NSObject`. Isolation is maintained by dispatching back to the actor via `Task { await api.handle(...) }`:

```swift
final class UploadSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionDelegate {
  weak var api: OracleAPI?

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    let id = dataTask.taskIdentifier
    Task { await api?.appendData(data, forTaskIdentifier: id) }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let id = task.taskIdentifier
    let response = task.response as? HTTPURLResponse
    Task { await api?.completeTask(identifier: id, response: response, error: error) }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { await api?.drainBackgroundCompletionHandlers() }
  }
}
```

**On the actor side:**

```swift
// Called from the delegate — appends data as chunks arrive
func appendData(_ data: Data, forTaskIdentifier id: Int) {
  pendingUploads[id]?.accumulatedData.append(data)
}

// Called from the delegate on terminal completion
func completeTask(
  identifier id: Int,
  response: HTTPURLResponse?,
  error: Error?
) {
  guard var upload = pendingUploads.removeValue(forKey: id) else { return }
  defer { try? FileManager.default.removeItem(at: upload.tempFileURL) }

  if let error {
    upload.continuation.resume(throwing: error)
    return
  }

  guard let response else {
    upload.continuation.resume(throwing: APIError.unexpectedResponse)
    return
  }

  let status = response.statusCode
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
```

**Temp file lifecycle:** The `defer { removeItem }` in `completeTask` deletes the temp file on every terminal outcome — success and failure. The only time a temp file outlives its task is if the app is killed before `didCompleteWithError` fires; in that case, `sessionSendsLaunchEvents = true` ensures the OS will relaunch the app and replay the completion event, at which point the `defer` block runs. Orphaned temp files (if the app is killed between `writeBodyToTempFile` and `uploadTask` creation) are cleaned up on next launch by a sweep that deletes any `*.upload-body` files older than one hour from `temporaryDirectory`.

**Background completion handler lifecycle:**

```swift
private var backgroundCompletionHandlers: [String: () -> Void] = [:]

func storeBackgroundCompletionHandler(
  _ handler: @escaping () -> Void,
  forIdentifier identifier: String
) {
  backgroundCompletionHandlers[identifier] = handler
}

func drainBackgroundCompletionHandlers() {
  let handlers = backgroundCompletionHandlers.values
  backgroundCompletionHandlers.removeAll()
  DispatchQueue.main.async {
    handlers.forEach { $0() }
  }
}
```

The completion handler must be called on the main thread per Apple's documentation — hence `DispatchQueue.main.async`.

---

### 6. Offline queue interaction

The `TODO(offline)` identifies three promises: persist failed captures, retry on reconnect, reuse `client_id`. Background sessions with `waitsForConnectivity = true` handle "task enqueued while online, network drops mid-flight, OS waits and retries." They do not handle "user taps Save while completely offline before any task is enqueued" — the task must be created while the session is reachable or `waitsForConnectivity` will hold it, but the task cannot be created at all if the app has nothing to write. That gap requires an explicit offline queue.

**SwiftData model:**

```swift
@Model
final class QueuedCapture {
  @Attribute(.unique) var clientID: UUID
  var content: String
  var sourceModality: String
  var sourceDevice: String
  var language: String
  var capturedAt: Date
  var enqueuedAt: Date
  var attempts: Int
  var lastAttemptAt: Date?
  var status: QueuedCaptureStatus  // .pending | .uploading | .synced | .failed
  var lastErrorMessage: String?

  init(payload: CapturePayload) { ... }
}

enum QueuedCaptureStatus: String, Codable {
  case pending
  case uploading
  case synced
  case failed
}
```

**Queue-to-session interaction:**

1. `CaptureViewModel.save()` writes a `QueuedCapture` to SwiftData with `.pending` status. This is the local confirm — the UI transitions to `.success` immediately.
2. `UploadQueue` (a singleton actor) observes the SwiftData store. For each `.pending` capture, it calls `OracleAPI.shared.postCapture`, transitioning the row to `.uploading`, then `.synced` on success or `.failed` with the error message on terminal failure.
3. On `.synced`, the queue row is deleted. On `.failed` for a 4xx (non-retryable), the row persists and is surfaced in a debug screen (per the V1 implementation plan Phase 5).
4. On 5xx or network errors, the row remains `.pending` to be picked up by the next sweep.

**NWPathMonitor integration:** A `NetworkMonitor` singleton actor starts an `NWPathMonitor` on `init`. When the path transitions to `.satisfied`, it calls `UploadQueue.shared.sweep()`. The monitor is started from the root SwiftUI view's `.task` modifier on first appearance:

```swift
// RootView.swift
.task {
  await NetworkMonitor.shared.start()
}
```

This is the right place — `.task` on the root view means the monitor runs for the app's lifetime, and it avoids a `UIApplicationDelegate` method for something that has a clean SwiftUI idiom.

**Sweep on launch** happens in the same `.task` call: `UploadQueue.shared.sweep()` runs once immediately when `RootView` appears, then again whenever NWPathMonitor fires `.satisfied`. The monitor and queue do not need a reference to each other beyond the singleton call.

**`client_id` idempotency:** The `QueuedCapture.clientID` is generated at capture time (same UUID across all retry attempts). The server's `UNIQUE` constraint on `memories.client_id` makes duplicate uploads no-ops. The iOS queue never generates a new UUID for a retry.

---

### 7. Test strategy

The `URLProtocol` constraint (§3) forces a layered approach. No single test suite covers everything.

**Unit tests — bridge logic in isolation (`OracleCoreTests`):**

Extract `completeTask`, `appendData`, and `drainBackgroundCompletionHandlers` into a testable shape by making them callable on the actor directly without a live session. The `PendingUpload` struct and the continuation map are internal state — tests can be `@testable import OracleCore` and construct controlled scenarios:

```swift
// Example: verify that didCompleteWithError→completeTask decodes a 201 response
func testCompleteTask_201_decodesResponseBody() async throws {
  let api = OracleAPI(baseURL: ..., bearerToken: "test", configuration: .default)
  // manually insert a fake PendingUpload with a CheckedContinuation
  // call api.completeTask(identifier:response:error:)
  // assert continuation resumed with expected CaptureResponseBody
}
```

This requires the continuation infrastructure to be visible to tests (via `internal` access). Keep it `internal`, not `public`.

**Integration tests — stub session covers happy/error paths (`OracleCoreTests`):**

The existing `StubURLProtocol` + `.default` configuration path (from #88) remains valid for testing `postCapture`'s request construction, HTTP error handling, and JSON decoding. These tests do not exercise the background session at all — they test the *same code paths* but via the default-session initialiser. That's the correct trade-off: the stub covers the business logic; the background session mechanics are covered by manual tests.

**Manual device tests (`docs/manual-tests/89-background-urlsession.md` — written at V2 implementation time):**

The following scenarios cannot be automated and must be manually verified on device before merging V2 to `develop`:

- **Scenario A: Background mid-upload.** Tap Save on a 500-word capture. Immediately press the Home button. Wait 30 seconds. Reopen the app. Confirm the capture appears as synced and is visible in a query. Verify the temp file is gone from the sandbox.
- **Scenario B: Offline at save time.** Enable Airplane Mode. Tap Save. Confirm the UI shows success (local-only confirm). Disable Airplane Mode. Confirm the capture uploads and transitions to synced within 60 seconds. Verify no duplicate in the server.
- **Scenario C: Force-kill during upload.** Tap Save. Immediately force-kill the app via App Switcher (swipe up). Wait for the OS to deliver completions (up to 5 minutes in practice on cellular; faster on Wi-Fi). Reopen the app. Confirm the capture is synced. This tests `sessionSendsLaunchEvents` + `AppDelegate.application(_:handleEventsForBackgroundURLSession:)` end-to-end.

Acknowledge the coverage gap explicitly: Scenario C cannot be reproduced in a simulator. It requires a physical device, a live server, and patience. It should be gated before V2 ships to `develop`.

---

### 8. Capture vs Query split

V2's `OracleAPI` has two sessions. This is the right architecture and should be implemented from the start of V2, not retrofitted:

**Capture: background session.** Tiny JSON POST, user may background the app at any moment, the OS-relaunch path must work. Background session is the correct choice.

**Query: default session.** The user is actively staring at the Ask screen waiting for an answer. A query in flight when the user backgrounds the app should be dropped — a stale synthesis response landing 10 minutes after the user has moved on is worse than an error. `postQuery` must remain on a `.default` session and must support cancellation (tracked in #91). Background delivery of a query response has no value.

This means `OracleAPI.init()` creates two sessions:

```swift
private init() {
  self.baseURL = Config.shared.baseURL
  self.bearerToken = Config.shared.bearerToken

  let bgConfig = URLSessionConfiguration.background(
    withIdentifier: "com.the-oracle.capture-upload"
  )
  bgConfig.isDiscretionary = false
  bgConfig.sessionSendsLaunchEvents = true
  bgConfig.waitsForConnectivity = true
  self.backgroundSession = URLSession(
    configuration: bgConfig,
    delegate: uploadDelegate,
    delegateQueue: nil  // nil → OS creates a serial queue
  )

  self.defaultSession = URLSession(configuration: .default)
}

private let uploadDelegate = UploadSessionDelegate()
private var backgroundSession: URLSession!
private var defaultSession: URLSession!
```

The `uploadDelegate` is an `UploadSessionDelegate` instance created before the session so it can be passed to `URLSession(configuration:delegate:delegateQueue:)`. The `UploadSessionDelegate` receives `weak var api: OracleAPI?` set immediately after the actor is initialised. Since `actor` isolated properties can't be captured in the `private init()` ordering, set it in a lazy property or a post-init hook.

`postQuery` continues to use `defaultSession.data(for: request)` — no delegate changes needed. The `postCapture` → `backgroundSession.uploadTask(with:fromFile:)` path goes through `UploadSessionDelegate`.

Testing implications: the `OracleAPI(baseURL:bearerToken:session:)` public test initialiser needs to grow a second parameter for a `querySession`, or a single-session path needs to be documented as default-session-only. The existing test coverage does not break because it exercises `postQuery` and `captureRequest` construction, neither of which uses the background session.

---

### 9. Migration and rollout

**One PR stack, not a single monolithic PR.** The V2 changes span: `AppDelegate` wiring, `UploadSessionDelegate`, `OracleAPI` refactor (two sessions, pending map, bridge), `QueuedCapture` SwiftData model, `UploadQueue` actor, `NetworkMonitor` actor, and `RootView` `.task` integration. That is six separable concerns. A single 800-line PR is harder to review and harder to revert if one piece fails device testing.

Suggested stack:
1. `AppDelegate` + `@UIApplicationDelegateAdaptor` wiring (no functional change yet)
2. `UploadSessionDelegate` + bridge logic in `OracleAPI` (background session for `postCapture`; default session stays for `postQuery`)
3. `QueuedCapture` SwiftData model + `UploadQueue` actor
4. `NetworkMonitor` + sweep wiring in `RootView`
5. `CaptureViewModel` updated to write to queue rather than call API directly

**Feature flag:** Not worth it for a single-user app. If V2 breaks, the branch is reverted. No flag needed.

**Manual test gate:** Scenarios A, B, C from §7 must all pass on a physical device before the final PR in the stack merges to `develop`. This is the same pattern as #61/#62 (manual test scripts committed to `docs/manual-tests/` before merge was approved).

---

### 10. Effort estimate

Focused implementation, not counting re-reading this spike:

| Work | Estimate |
|---|---|
| `AppDelegate` + `@UIApplicationDelegateAdaptor` wiring | 0.5 day |
| `UploadSessionDelegate` + bridge in `OracleAPI` (two sessions, pending map, temp file lifecycle) | 1.5 days |
| `QueuedCapture` SwiftData model + `UploadQueue` actor | 1 day |
| `NetworkMonitor` actor + `RootView` sweep integration | 0.5 day |
| `CaptureViewModel` updated to write to queue first | 0.5 day |
| Unit tests (bridge logic) + integration tests (stub session happy/error paths) | 1 day |
| Manual device testing — Scenarios A, B, C | 1 day |
| **Total** | **~6 days** |

The 6-day estimate assumes one developer, evenings/weekends. The most likely time sink is Scenario C (force-kill test) because it requires a live server, a physical device, and non-trivial wait times between attempts.

---

### 11. Recommendation

V2 should ship with the continuation-map bridge design from §5, the two-session architecture from §8, and the SwiftData offline queue from §6. The five-PR stack from §9 is the right shape for review and rollout. The implementation is well-defined enough to write without additional prototyping — the Swift signatures in §5 are directly portable to production code with `@testable`-accessible internals. The single open risk is the `UploadSessionDelegate` weak-reference setup ordering between `private init()` and the actor's `uploadDelegate` property (see §8) — the implementer should verify the weak ref is set before any upload is attempted, which a unit test on the init sequence can confirm. Manual device tests for Scenarios A, B, C must pass before the final PR merges to `develop`; that gate has been the pattern for all previous iOS PRs and should not be relaxed here. Estimated effort is 6 days. Top risks: (1) temp file lifecycle under OS memory pressure cleaning `tmp/` before the upload task executes — mitigated by using `FileManager.default.temporaryDirectory` with a known filename and sweeping orphaned files on launch; (2) `UploadSessionDelegate` weak-reference tear-down if the actor is ever deallocated between task creation and `didCompleteWithError` — not a risk in practice since `OracleAPI.shared` is a singleton, but worth a `guard let api` in every delegate method; (3) Scenario C flakiness on device — the only mitigation is patience and a clean test run the day before merge.

---

### 12. Open questions

None that require a prototyping spike or Apple Developer Forums input. All three crux constraints in §3 are documented Apple behaviour with no ambiguity. The bridge design in §5 follows the standard `withCheckedThrowingContinuation` + delegate pattern used across the platform. Design is ready to implement from this doc.

One implementation detail to verify during PR 2 of the stack: whether the `URLSession(configuration:delegate:delegateQueue:)` initialiser with `delegateQueue: nil` creates a serial queue (Apple's docs say yes, but confirming with `assert(session.delegateQueue.maxConcurrentOperationCount == 1)` in a debug build is cheap insurance).
