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

1. Open `ios/Oracle/Oracle.xcodeproj` in Xcode 16.
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
    Oracle.xcodeproj/
      xcshareddata/xcschemes/Oracle.xcscheme   ← committed; shared build scheme
      project.xcworkspace/contents.xcworkspacedata
      project.pbxproj
    Oracle/
      OracleApp.swift          ← @main entry point
      Config.swift             ← typed wrapper for Info.plist build settings
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
  README.md                    ← this file
```
