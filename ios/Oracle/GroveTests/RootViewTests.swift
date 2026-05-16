import Testing
import SwiftUI
@testable import Grove

/// Tests for `RootView.colorScheme(for:)` — the pure helper that maps a
/// persisted appearance-preference string to `ColorScheme?`.
///
/// Lives in `GroveTests` (app test bundle) because the helper is iOS-specific
/// and must `@testable import Grove`.  Run locally via `make ios-test-app`.
@Suite("RootView.colorScheme(for:)")
struct RootViewTests {

  @Test("'light' maps to .light")
  func lightMapsToLight() {
    #expect(RootView.colorScheme(for: "light") == .light)
  }

  @Test("'dark' maps to .dark")
  func darkMapsToDark() {
    #expect(RootView.colorScheme(for: "dark") == .dark)
  }

  @Test("'system' maps to nil")
  func systemMapsToNil() {
    #expect(RootView.colorScheme(for: "system") == nil)
  }

  @Test("unrecognised value maps to nil")
  func unrecognisedMapsToNil() {
    #expect(RootView.colorScheme(for: "auto") == nil)
  }
}
