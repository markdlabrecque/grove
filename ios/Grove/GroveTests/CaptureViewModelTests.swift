import Testing
import Foundation
import GroveCore
@testable import Grove

// MARK: - SweepOrphanedTempFilesTests

/// Integration test: verifies that stale `*.upload-body` temp files are
/// removed by `sweepOrphanedTempFiles()`.
///
/// This test drops a pre-aged file into `FileManager.temporaryDirectory`,
/// calls the sweep, and asserts the file is gone. It verifies the function
/// correctly identifies and removes files past the one-hour cutoff.
///
/// # Note
///
/// This suite does not use `StubURLProtocol` and does not need to be serialized
/// against the `StubNetwork` suites. It is kept in its own file for clarity.
/// The `CaptureViewModel` and `UploadQueue` stub-network tests live in
/// `StubNetworkTests.swift` under a shared `@Suite(.serialized)` parent that
/// prevents cross-suite `StubURLProtocol` races (see #228).
@Suite("sweepOrphanedTempFiles")
struct SweepOrphanedTempFilesTests {

  @Test("removes *.upload-body files older than one hour")
  func removesStaleFile() async throws {
    let tmp = FileManager.default.temporaryDirectory
    let staleURL = tmp.appendingPathComponent("stale-test-\(UUID().uuidString).upload-body")

    // Write the file.
    try Data("stale body".utf8).write(to: staleURL)

    // Back-date its creation by manipulating attributes (two hours ago).
    let twoHoursAgo = Date().addingTimeInterval(-7200)
    try FileManager.default.setAttributes(
      [.creationDate: twoHoursAgo],
      ofItemAtPath: staleURL.path
    )

    #expect(FileManager.default.fileExists(atPath: staleURL.path), "Pre-condition: file exists")

    // Run the sweep — actor-isolated so requires await.
    await GroveAPI.shared.sweepOrphanedTempFiles()

    #expect(
      !FileManager.default.fileExists(atPath: staleURL.path),
      "Stale file should have been removed"
    )
  }

  @Test("leaves *.upload-body files newer than one hour untouched")
  func preservesRecentFile() async throws {
    let tmp = FileManager.default.temporaryDirectory
    let recentURL = tmp.appendingPathComponent("recent-test-\(UUID().uuidString).upload-body")

    // Write a fresh file (creation date defaults to now).
    try Data("recent body".utf8).write(to: recentURL)
    defer { try? FileManager.default.removeItem(at: recentURL) }

    #expect(FileManager.default.fileExists(atPath: recentURL.path), "Pre-condition: file exists")

    await GroveAPI.shared.sweepOrphanedTempFiles()

    #expect(
      FileManager.default.fileExists(atPath: recentURL.path),
      "Recent file should NOT be removed"
    )
  }
}
