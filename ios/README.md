# Oracle — iOS Client

iPhone-only SwiftUI app for The Oracle personal memory system.

- **Deployment target:** iOS 26.0+
- **Reference device:** iPhone 17
- **Bundle identifier:** `com.markdlabrecque.oracle`
- **Xcode project:** `ios/Oracle/Oracle.xcodeproj`

---

## First-time setup

### 1. Create the local config files

The project uses two gitignored `.xcconfig` files — one per build configuration.

```bash
cd ios/Oracle/Oracle
cp Config.xcconfig.example Config.debug.xcconfig
cp Config.xcconfig.example Config.release.xcconfig
```

Edit each file:

| Variable | What to put |
|---|---|
| `BASE_URL` | Your server's base URL, e.g. `https://oracle.your-host.ts.net` |
| `BEARER_TOKEN` | The long-lived bearer token set on the server |

Note: `$()` in the example value is xcconfig syntax for a literal `//`. Without
it, xcconfig treats `//` as a line comment and `BASE_URL` silently becomes empty.

### 2. Verify which config is in use

On first launch the app prints to the Xcode console:

```
[Oracle] baseURL: https://oracle.your-host.ts.net
```

If you see a crash with "BASE_URL is missing or malformed" or "BEARER_TOKEN is
missing", the active `.xcconfig` file has not been filled in.

### 3. Select the right build configuration in Xcode

- **Debug builds** (Run button, simulator, on-device development) use
  `Config.debug.xcconfig` — no action required; Xcode selects Debug by default.
- **Release builds** (Archive, TestFlight, App Store) use
  `Config.release.xcconfig` — Xcode selects Release automatically for archives.

To verify: in Xcode, open the Oracle scheme editor (Product → Scheme → Edit
Scheme). The Build Configuration column shows which config each action uses.

---

## Building and running

1. Open `ios/Oracle/Oracle.xcodeproj` in Xcode 26.
2. Select the Oracle scheme.
3. Choose a simulator or your connected iPhone.
4. Press Run (⌘R).

The shared scheme (`xcshareddata/xcschemes/Oracle.xcscheme`) is committed so
anyone cloning the repo can build immediately.

---

## Archiving for TestFlight

Use the **Release** build configuration so `Config.release.xcconfig` is the
active config. Confirm `BEARER_TOKEN` in that file points at the production
server.

### Steps

1. In Xcode, select a real device (not a simulator) or "Any iOS Device (arm64)"
   as the run destination.
2. Product → Archive.
3. When the Organizer opens, click **Distribute App**.
4. Choose **App Store Connect** → Next.
5. Choose **Upload** → Next.
6. Leave "Automatically manage signing" checked if your Apple Developer team is
   set up in Xcode (Signing & Capabilities tab → Team).
7. Review the distribution summary and click **Upload**.
8. In [App Store Connect](https://appstoreconnect.apple.com), open the Oracle
   app record → TestFlight tab. The build appears within a few minutes.
9. Under Internal Testing, add `mark@affinitybridge.com` as an internal tester
   and enable the build.

### Prerequisite: Apple Developer account + App Store Connect record

Before the first archive, the user must:

- Sign in to an Apple Developer account in Xcode (Settings → Accounts).
- Create an App Store Connect app record with:
  - **Name:** Oracle
  - **Bundle ID:** `com.markdlabrecque.oracle`
  - **SKU:** anything unique (e.g. `oracle-001`)
  - **Primary language:** English

This is a one-time manual step; it cannot be scripted without App Store Connect
API credentials.

---

## Testing

### Running tests

Three Makefile targets correspond to the two-job CI strategy:

```bash
make ios-test-core   # OracleCore swift package only — no simulator needed
make ios-test-app    # Full Oracle scheme on iPhone 17 simulator (requires xcconfig)
make ios-test        # Both in sequence (local green check before pushing)
```

`make ios-test-core` is the fast, always-available check. It runs `swift test`
against the `OracleCore` package and requires no simulator or xcconfig.

`make ios-test-app` runs `xcodebuild test` against the full Oracle scheme and
requires a populated `Config.debug.xcconfig`. After a failure:

```bash
open ios/build/TestResults.xcresult
```

To wipe build artefacts and run from a clean slate:

```bash
make ios-test-clean
```

**In Xcode:** Open `ios/Oracle/Oracle.xcodeproj`, select the Oracle scheme, and
press `Cmd+U`. Both the `OracleTests` and `OracleUITests` targets run (requires
a populated xcconfig — see First-time setup above).

### Project structure: OracleCore package

SDK-version-independent logic lives in a local Swift Package at
`ios/Oracle/OracleCore/`. The package has an iOS 18 + macOS 15 deployment target,
which allows `swift test` to run on macOS CI hosts without a simulator.

```
ios/Oracle/
  OracleCore/            ← Swift Package (iOS 18, macOS 15)
    Package.swift
    Sources/OracleCore/
      Config.swift       ← typed wrapper for build-settings values
      OracleAPI.swift    ← URLSession client, DTOs, Codable models
    Tests/OracleCoreTests/
      ConfigTests.swift
      OracleAPITests.swift
      JSONCodingTests.swift
      Fixtures/
        capture_response.json
  Oracle.xcodeproj/      ← app target (iOS 26, imports OracleCore)
  OracleTests/           ← Xcode unit test target (@testable import Oracle)
  OracleUITests/         ← Xcode UI test target (XCUITest)
```

The `Oracle` app target keeps its iOS 26 deployment target. It will import
`OracleCore` once the Xcode project is wired up as a local package reference
(pending first use in `#61` / `#62`).

### What is covered

| Target | Framework | Scope |
|---|---|---|
| `OracleCoreTests` (SPM) | Swift Testing | Unit tests: `Config`, `OracleAPI` request builder, JSON coding |
| `OracleTests` (Xcode) | Swift Testing | Same seed tests, via `@testable import Oracle` |
| `OracleUITests` (Xcode) | XCUITest | Placeholder only — no real UI to drive yet |

Seed unit tests (`#64`):

- **`ConfigTests`** — verifies `Config.init(baseURL:bearerToken:)` stores the
  correct values. Uses an internal initialiser rather than `Config.shared`
  because the test bundle does not have a populated `Info.plist`. The
  `Config.shared` path is exercised by every app build via `OracleApp.init()`.
- **`OracleAPITests`** — verifies `OracleAPI.captureRequest(for:)` produces a
  `POST` request to `baseURL/v1/captures` with correct `Authorization` and
  `Content-Type` headers and a round-trippable JSON body. No live server.
- **`JSONCodingTests`** — verifies `CaptureResponseBody` decodes from a canned
  fixture and that `captured_at` parses as a timezone-aware `Date`. In the SPM
  target the fixture is loaded via `Bundle.module`; in the Xcode target via
  `Bundle(for: BundleLocator.self)`.

Real UI tests (Save flow, Ask flow) are deferred to the tickets that land those
screens (`#61`, `#62`).

### Future: snapshot testing

`// TODO(snapshot):` — once `#61`/`#62` have stable SwiftUI layouts, consider
adding [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
as the one third-party SPM dependency. This is noted as an explicit future
option, not a current commitment. See ticket `#64` for the rationale.

### CI

`ios-ci.yml` uses a two-job strategy:

| Job | Runner | Tool | Required? |
|---|---|---|---|
| `stable` (Core) | `macos-latest`, Xcode 16.2 | `swift test` on `OracleCore` package | Yes — merge gate |
| `canary` (App) | `macos-latest`, Xcode 16.2 | `xcodebuild test` on `Oracle` scheme | No — `continue-on-error: true` |

**The `stable` job is the required check.** It covers all logic-level code
(Config, OracleAPI, Codable models) and runs without a simulator or iOS 26 SDK,
so it is always green on `macos-latest` with Xcode 16.2.

**The `canary` job is informational.** It covers iOS 26-specific code paths and
the app scheme tests. It will fail on CI until GitHub ships Xcode 26 on
`macos-latest` runners — this is expected and does not block merges. Once Xcode
26 lands on runners and canary goes green, it will be promoted to a required
check and the two-job split retired (see `TODO(ci):` in `ios-ci.yml`).

**Manual step after `#64` merges:** add the `stable` job to the branch-protection
ruleset so iOS PRs can't merge with a red stable gate:
GitHub → Settings → Branches → develop → Require status checks →
`Core (stable gate)` (from the `iOS CI` workflow).

---

## Build configuration detail

The project has two build configurations: Debug and Release. Each is backed by
a gitignored `.xcconfig` file that injects `BASE_URL` and `BEARER_TOKEN` into
build settings. The build settings flow into `Info.plist` via `$(BASE_URL)` and
`$(BEARER_TOKEN)` substitution variables, and `Config.swift` reads them from
the bundle at runtime via `Bundle.main.object(forInfoDictionaryKey:)`.

```
Config.debug.xcconfig / Config.release.xcconfig
         ↓ (xcconfig → build settings)
     Info.plist  ($(BASE_URL), $(BEARER_TOKEN))
         ↓ (bundle at runtime)
       Config.swift  (Config.shared.baseURL, Config.shared.bearerToken)
         ↓
      OracleAPI  (Authorization: Bearer …)
```

**V1 note on bearer token storage:** The bearer token lives in `.xcconfig` for
V1. A future ticket migrates it to iOS Keychain protected by `LAContext`
(Face/Touch ID). `TODO(auth):` markers in `Config.swift` and `OracleAPI.swift`
mark the migration points.

---

## File layout

```
ios/
  Oracle/
    OracleCore/                ← local Swift Package (iOS 18 + macOS 15)
      Package.swift
      Sources/OracleCore/
        Config.swift           ← typed wrapper for build-settings values
        OracleAPI.swift        ← URLSession client, DTOs, Codable models
      Tests/OracleCoreTests/
        ConfigTests.swift      ← seed unit tests (Swift Testing)
        OracleAPITests.swift
        JSONCodingTests.swift
        Fixtures/
          capture_response.json
    Oracle.xcodeproj/
      xcshareddata/xcschemes/Oracle.xcscheme   ← committed; shared build scheme
      project.xcworkspace/contents.xcworkspacedata
      project.pbxproj
    Oracle/
      OracleApp.swift          ← @main entry point
      Config.swift             ← thin re-export / app-only init via Bundle.main
      Info.plist               ← references $(BASE_URL) and $(BEARER_TOKEN)
      Config.xcconfig.example  ← committed template; copy to the two below
      Config.debug.xcconfig    ← gitignored; fill in before building
      Config.release.xcconfig  ← gitignored; fill in before archiving
      Networking/
        OracleAPI.swift        ← URLSession client; stubs for #61 and #62
      Views/
        RootView.swift         ← TabView shell
        CaptureView.swift      ← Save tab placeholder
        QueryView.swift        ← Ask tab placeholder
      Assets.xcassets/
      Preview Content/
    OracleTests/               ← Xcode unit test target (mirrors OracleCoreTests)
    OracleUITests/             ← Xcode UI test target (XCUITest placeholder)
  README.md                    ← this file
```
