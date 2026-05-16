import Testing
import Foundation
import SwiftData
@testable import Grove

// MARK: - MigrationPlanTests

/// Tests that the `VersionedSchema` + `SchemaMigrationPlan` scaffolding compiles
/// and that a `ModelContainer` opened with the production init path is functional.
///
/// # What this tests
///
/// This is a "scaffolding compiles and behaves" test, NOT a true migration test.
/// A real migration test (V1 → V2) requires an existing on-disk V1 store to open
/// against. That store doesn't exist until V2 ships. When V2 lands, add a test
/// here that serialises a V1 store to a temp file and confirms the migration plan
/// opens it cleanly.
///
/// # What this does NOT test
///
/// - Any V1 → V2 migration (no V2 exists yet).
/// - The production disk-backed store (tests always use `isStoredInMemoryOnly: true`).
@Suite("MigrationPlan")
struct MigrationPlanTests {

  // MARK: - Helpers

  /// Build an in-memory `ModelContainer` using the same schema + migration plan
  /// the production `GroveApp.modelContainer` static uses. The only difference
  /// is `isStoredInMemoryOnly: true` so tests never touch disk state.
  private func makeContainer() throws -> ModelContainer {
    let schema = Schema(QueuedCaptureSchemaV1.models)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(
      for: schema,
      migrationPlan: QueuedCaptureMigrationPlan.self,
      configurations: [config]
    )
  }

  // MARK: - containerOpensWithMigrationPlan

  /// Verifies the `ModelContainer` opens without throwing when the
  /// `VersionedSchema` + `SchemaMigrationPlan` are in place.
  @Test("ModelContainer opens with QueuedCaptureMigrationPlan")
  func containerOpensWithMigrationPlan() throws {
    // Throws on failure — test fails if container cannot be created.
    _ = try makeContainer()
  }

  // MARK: - insertFetchDeleteRoundtrip

  /// Verifies that `QueuedCapture` rows can be inserted, fetched, and deleted
  /// normally after the migration plan is applied. Guards against a scenario
  /// where the schema wrapping causes the model to be unreachable.
  @Test("QueuedCapture insert/fetch/delete round-trip via migration-plan container")
  func insertFetchDeleteRoundtrip() throws {
    let container = try makeContainer()
    let context = ModelContext(container)

    let clientID = UUID().uuidString
    let payload = Data("test-payload".utf8)

    // Insert
    let capture = QueuedCapture(clientID: clientID, payload: payload)
    context.insert(capture)
    try context.save()

    // Fetch
    let rows = try context.fetch(FetchDescriptor<QueuedCapture>())
    #expect(rows.count == 1)
    let fetched = try #require(rows.first)
    #expect(fetched.clientID == clientID)
    #expect(fetched.payload == payload)
    #expect(fetched.attemptCount == 0)
    #expect(fetched.lastError == nil)

    // Delete
    context.delete(fetched)
    try context.save()

    let afterDelete = try context.fetch(FetchDescriptor<QueuedCapture>())
    #expect(afterDelete.isEmpty)
  }

  // MARK: - schemaVersionIdentifier

  /// Verifies that `QueuedCaptureSchemaV1.versionIdentifier` is (1, 0, 0).
  /// This is a guard against accidentally bumping the version in a patch without
  /// the corresponding migration-plan work.
  @Test("QueuedCaptureSchemaV1 version is 1.0.0")
  func schemaVersionIdentifier() {
    let v = QueuedCaptureSchemaV1.versionIdentifier
    #expect(v == Schema.Version(1, 0, 0))
  }

  // MARK: - migrationPlanHasNoStagesYet

  /// Verifies that `QueuedCaptureMigrationPlan.stages` is empty for V1.
  /// The first migration step belongs in the PR that introduces V2 — having an
  /// empty stages array here is the correct state.
  @Test("QueuedCaptureMigrationPlan has zero stages for V1 baseline")
  func migrationPlanHasNoStagesYet() {
    #expect(QueuedCaptureMigrationPlan.stages.isEmpty)
  }
}
