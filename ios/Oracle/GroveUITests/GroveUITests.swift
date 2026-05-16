import XCTest

/// UI test seed — target compiles and runs; no real UI to drive yet.
///
/// Real UI test coverage for the Save and Ask flows belongs in tickets that
/// follow #61 and #62, once those screens have stable layouts.
///
/// TODO(snapshot): Add swift-snapshot-testing (the one third-party SPM dep
/// we'd seriously consider) for SwiftUI view regression tests once #61/#62
/// have settled layouts. See ios/README.md §Testing for the rationale.
final class GroveUITests: XCTestCase {

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// Placeholder — confirms the UI test target links and runs.
  ///
  /// Remove this test (or replace it with a real interaction) once #61/#62
  /// land actual screens to drive.
  func testPlaceholder() throws {
    // No UI to drive yet. This test exists only to confirm the target
    // compiles and is included in the scheme's Test action.
    XCTAssertTrue(true, "GroveUITests target is wired correctly.")
  }
}
