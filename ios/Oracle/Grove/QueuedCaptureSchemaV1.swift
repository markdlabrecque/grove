import Foundation
import SwiftData

// MARK: - QueuedCaptureSchemaV1

/// The first versioned schema for the `QueuedCapture` SwiftData model.
///
/// # Why VersionedSchema?
///
/// SwiftData's default lightweight migration handles additive changes (new optional
/// properties) automatically, but it will throw at container-open time if a schema
/// change is destructive: removing a property, changing a non-optional to required,
/// or renaming a property without a migration mapping. Wrapping `QueuedCapture` in a
/// `VersionedSchema` gives us a safe evolution path.
///
/// # Future changes
///
/// Before making *any* destructive schema change (remove property, add non-optional
/// property with no default, rename a property), you MUST:
///
/// 1. Define a new `QueuedCaptureSchemaV2` (copy V1 structure, apply the change).
/// 2. Add a `MigrationStage` entry to `QueuedCaptureMigrationPlan.stages`
///    (`.lightweight` if no data transformation needed; `.custom` otherwise).
/// 3. Update the `Schema(...)` call in `GroveApp.modelContainer` to pass
///    `QueuedCaptureSchemaV2.models` as the schema's models array.
/// 4. Run the manual test from `docs/manual-tests/123-versionedschema-migration.md`
///    against an existing V1 store on-device before merging.
///
/// # Additive-only changes
///
/// Adding a new *optional* property (or one with a Swift default) does not require a
/// new schema version — SwiftData's lightweight migration handles it. That said,
/// adding it to V1 here and documenting it keeps the model history legible.
enum QueuedCaptureSchemaV1: VersionedSchema {

  static var versionIdentifier: Schema.Version {
    Schema.Version(1, 0, 0)
  }

  static var models: [any PersistentModel.Type] {
    [QueuedCapture.self]
  }
}

// MARK: - QueuedCaptureMigrationPlan

/// The migration plan for `QueuedCapture`. Lists every schema version the app has
/// ever shipped, oldest first.
///
/// There are no migration stages yet — V1 is the first version and there is nothing
/// to migrate *from*. The first migration step (V1 → V2) will be added in the ticket
/// that introduces `QueuedCaptureSchemaV2`.
enum QueuedCaptureMigrationPlan: SchemaMigrationPlan {

  static var schemas: [any VersionedSchema.Type] {
    [QueuedCaptureSchemaV1.self]
  }

  /// No stages yet. V1 is the baseline. Add entries here when V2 ships.
  static var stages: [MigrationStage] {
    []
  }
}
