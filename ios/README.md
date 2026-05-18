# Grove — iOS Client

iPhone-only SwiftUI app for Grove personal memory system.

- **Deployment target:** iOS 26.0+
- **Reference device:** iPhone 17
- **Bundle identifier:** `com.markdlabrecque.grove`
- **Xcode project:** `ios/Grove/Grove.xcodeproj`

---

## First-time setup

### 1. Create the local config files

The project uses two gitignored `.xcconfig` files — one per build configuration.

```bash
cd ios/Grove/Grove
cp Config.xcconfig.example Config.debug.xcconfig
cp Config.xcconfig.example Config.release.xcconfig
```

Edit each file:

| Variable | What to put |
|---|---|
| `BASE_URL` | Your server's base URL, e.g. `https://grove.your-host.ts.net` |
| `BEARER_TOKEN` | The long-lived bearer token set on the server |

Note: `$()` in the example value is xcconfig syntax for a literal `//`. Without
it, xcconfig treats `//` as a line comment and `BASE_URL` silently becomes empty.

### 2. Verify which config is in use

On first launch the app prints to the Xcode console:

```
[Grove] baseURL: https://grove.your-host.ts.net
```

If you see a crash with "BASE_URL is missing or malformed" or "BEARER_TOKEN is
missing", the active `.xcconfig` file has not been filled in.

### 3. Select the right build configuration in Xcode

- **Debug builds** (Run button, simulator, on-device development) use
  `Config.debug.xcconfig` — no action required; Xcode selects Debug by default.
- **Release builds** (Archive, TestFlight, App Store) use
  `Config.release.xcconfig` — Xcode selects Release automatically for archives.

To verify: in Xcode, open the Grove scheme editor (Product → Scheme → Edit
Scheme). The Build Configuration column shows which config each action uses.

---

## Building and running

1. Open `ios/Grove/Grove.xcodeproj` in Xcode 26.
2. Select the Grove scheme.
3. Choose a simulator or your connected iPhone.
4. Press Run (⌘R).

The shared scheme (`xcshareddata/xcschemes/Grove.xcscheme`) is committed so
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
8. In [App Store Connect](https://appstoreconnect.apple.com), open the Grove
   app record → TestFlight tab. The build appears within a few minutes.
9. Under Internal Testing, add `mark@affinitybridge.com` as an internal tester
   and enable the build.

### Prerequisite: Apple Developer account + App Store Connect record

Before the first archive, the user must:

- Sign in to an Apple Developer account in Xcode (Settings → Accounts).
- Create an App Store Connect app record with:
  - **Name:** Grove
  - **Bundle ID:** `com.markdlabrecque.grove`
  - **SKU:** anything unique (e.g. `grove-001`)
  - **Primary language:** English

This is a one-time manual step; it cannot be scripted without App Store Connect
API credentials.

---

## Testing

### Pre-push checklist

Before pushing any iOS change, run the full local test suite:

```bash
make ios-test
```

This runs both targets in sequence:

```bash
make ios-test-core   # GroveCore swift package only — no simulator needed
make ios-test-app    # Full Grove scheme on iPhone 17 simulator (requires xcconfig)
```

Both must be green before pushing. `make ios-test` is the local gate that
replaces the canary CI job (see CI section below for why the canary was removed).

### Running tests

`make ios-test-core` is the fast, always-available check. It runs `swift test`
against the `GroveCore` package and requires no simulator or xcconfig.

`make ios-test-app` runs `xcodebuild test` against the full Grove scheme. It
requires Xcode 26 and a populated `Config.debug.xcconfig` (see First-time setup
above). After a failure:

```bash
open ios/build/TestResults.xcresult
```

To wipe build artefacts and run from a clean slate:

```bash
make ios-test-clean
```

**In Xcode:** Open `ios/Grove/Grove.xcodeproj`, select the Grove scheme, and
press `Cmd+U`. Both the `GroveTests` and `GroveUITests` targets run (requires
a populated xcconfig — see First-time setup above).

### Project structure: GroveCore package

SDK-version-independent logic lives in a local Swift Package at
`ios/Grove/GroveCore/`. The package has an iOS 18 + macOS 15 deployment target,
which allows `swift test` to run on macOS CI hosts without a simulator.

```
ios/Grove/
  GroveCore/             ← Swift Package (iOS 18, macOS 15)
    Package.swift
    Sources/GroveCore/
      Config.swift       ← typed wrapper for build-settings values
      GroveAPI.swift    ← URLSession client, DTOs, Codable models
    Tests/GroveCoreTests/
      ConfigTests.swift
      GroveAPITests.swift
      JSONCodingTests.swift
      Fixtures/
        capture_response.json
  Grove.xcodeproj/       ← app target (iOS 26, imports GroveCore)
  GroveTests/            ← Xcode unit test target (@testable import Grove)
  GroveUITests/          ← Xcode UI test target (XCUITest)
```

The `Grove` app target keeps its iOS 26 deployment target. It imports
`GroveCore` as a local package reference.

### What is covered

| Target | Framework | Scope |
|---|---|---|
| `GroveCoreTests` (SPM) | Swift Testing | Unit tests: `Config`, `GroveAPI` request builder, JSON coding |
| `GroveTests` (Xcode) | Swift Testing | Same seed tests, via `@testable import Grove` |
| `GroveUITests` (Xcode) | XCUITest | Placeholder only — no real UI to drive yet |

Seed unit tests (`#64`):

- **`ConfigTests`** — verifies `Config.init(baseURL:bearerToken:)` stores the
  correct values. Uses an internal initialiser rather than `Config.shared`
  because the test bundle does not have a populated `Info.plist`. The
  `Config.shared` path is exercised by every app build via `GroveApp.init()`.
- **`GroveAPITests`** — verifies `GroveAPI.captureRequest(for:)` produces a
  `POST` request to `baseURL/v1/captures` with correct `Authorization` and
  `Content-Type` headers and a round-trippable JSON body. No live server.
- **`JSONCodingTests`** — verifies `CaptureResponseBody` decodes from a canned
  fixture and that `captured_at` parses as a timezone-aware `Date`. In the SPM
  target the fixture is loaded via `Bundle.module`; in the Xcode target via
  `Bundle(for: BundleLocator.self)`.

Real UI tests (Save flow, Ask flow) are deferred to the tickets that land those
screens (`#61`, `#62`).

### CI

`ios-ci.yml` runs a single required job:

| Job | Runner | Tool | Required? |
|---|---|---|---|
| `stable` (Core) | `macos-latest`, Xcode 16.2 | `swift test` on `GroveCore` package | Yes — merge gate |

**The `stable` job is the only CI job.** It covers all logic-level code
(Config, GroveAPI, Codable models) and runs without a simulator or iOS 26 SDK,
so it passes on `macos-latest` with Xcode 16.2.

The full-app job (`xcodebuild test` on the Grove scheme) was removed from CI
because `macos-latest` ships Xcode 16.2, which cannot build the iOS 26
deployment target. The xcconfig files are also gitignored, so credential
injection would fail on CI regardless. The equivalent coverage runs locally via
`make ios-test` (see pre-push checklist above).

**TODO(ci):** When `macos-latest` ships Xcode 26, re-add the full-app Grove job
as a required check. At that point a CI-safe xcconfig strategy (e.g. a committed
placeholder with empty credentials) will also be needed.

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
      GroveAPI  (Authorization: Bearer …)
```

**V1 note on bearer token storage:** As of #184, the bearer token is stored in
Keychain at runtime; xcconfig only seeds the first launch. `TODO(auth):` markers
in `Config.swift` and `GroveAPI.swift` mark the V2 Face/Touch ID gate.

---

## File layout

```
ios/
  Grove/
    GroveCore/                 ← local Swift Package (iOS 18 + macOS 15)
      Package.swift
      Sources/GroveCore/
        Config.swift           ← typed wrapper for build-settings values
        GroveAPI.swift        ← URLSession client, DTOs, Codable models
      Tests/GroveCoreTests/
        ConfigTests.swift      ← seed unit tests (Swift Testing)
        GroveAPITests.swift
        JSONCodingTests.swift
        Fixtures/
          capture_response.json
    Grove.xcodeproj/
      xcshareddata/xcschemes/Grove.xcscheme   ← committed; shared build scheme
      project.xcworkspace/contents.xcworkspacedata
      project.pbxproj
    Grove/
      GroveApp.swift           ← @main entry point
      Info.plist               ← references $(BASE_URL) and $(BEARER_TOKEN)
      Config.xcconfig.example  ← committed template; copy to the two below
      Config.debug.xcconfig    ← gitignored; fill in before building
      Config.release.xcconfig  ← gitignored; fill in before archiving
      Networking/
      Views/
      Assets.xcassets/
    GroveTests/                ← Xcode unit test target (@testable import Grove)
    GroveUITests/              ← Xcode UI test target (XCUITest placeholder)
  README.md                    ← this file
```
