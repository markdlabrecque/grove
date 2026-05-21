import Foundation

// MARK: - PendingReminderEntry

/// A lightweight value type mapping a local capture identifier to the
/// `calendarItemIdentifier` of the Apple Reminder created for it at save time.
///
/// The `memoryID` is initially the capture's `clientID` UUID (available
/// immediately at save time). After the upload confirms and the server assigns
/// a permanent memory UUID, the reconciler matches on `clientID` via the
/// capture response's `client_id` field — the mapping key does not change.
///
/// Serialised to UserDefaults as JSON; survives app restarts because the
/// upload → enrichment → reconciliation window can be minutes.
public struct PendingReminderEntry: Codable, Equatable, Sendable {
  /// The capture's `clientID` UUID (generated at save time).
  public let memoryID: UUID
  /// The `calendarItemIdentifier` returned by `EKReminder` after save.
  public let calendarItemIdentifier: String

  public init(memoryID: UUID, calendarItemIdentifier: String) {
    self.memoryID = memoryID
    self.calendarItemIdentifier = calendarItemIdentifier
  }
}

// MARK: - PendingReminderStoring

/// Abstracts the persistence boundary for `PendingReminderEntry` values.
///
/// Production code uses `UserDefaultsPendingReminderStore`.
/// Tests may inject `InMemoryPendingReminderStore` defined alongside the
/// test suite.
@MainActor
public protocol PendingReminderStoring: AnyObject {
  /// Persist a new mapping entry. Replaces any existing entry for the same `memoryID`.
  func store(memoryID: UUID, calendarItemIdentifier: String)

  /// Retrieve the entry for the given `memoryID`, or nil if none exists.
  func entry(for memoryID: UUID) -> PendingReminderEntry?

  /// Remove the entry for the given `memoryID` if it exists.
  func remove(memoryID: UUID)

  /// Return all stored entries. Used for reconciliation sweeps.
  func all() -> [PendingReminderEntry]
}

// MARK: - UserDefaultsPendingReminderStore

/// A `PendingReminderStoring` implementation backed by `UserDefaults`.
///
/// Entries are stored as a JSON-encoded array under a single key. The list
/// is expected to be small (one entry per in-flight task-tagged capture)
/// so a full-array read/write on each mutation is acceptable.
///
/// UserDefaults is appropriate here because:
/// - The data is not sensitive (no bearer token, no content).
/// - The schema is additive and does not require migration.
/// - It survives app restarts, which is the key requirement.
/// - SwiftData would require adding `PendingReminderEntry` to the app's
///   model container, adding migration ceremony for a transient queue.
@MainActor
public final class UserDefaultsPendingReminderStore: PendingReminderStoring {

  // MARK: - Singleton

  public static let shared = UserDefaultsPendingReminderStore()

  // MARK: - Storage key

  private static let defaultsKey = "com.markdlabrecque.grove.pendingReminderEntries"

  // MARK: - In-memory cache (avoids repeated JSON decode on reads)

  private var cache: [PendingReminderEntry]

  // MARK: - UserDefaults backing store

  private let defaults: UserDefaults

  // MARK: - NotificationCenter

  private let notificationCenter: NotificationCenter

  // MARK: - Init

  public init(notificationCenter: NotificationCenter = .default) {
    self.defaults = .standard
    self.notificationCenter = notificationCenter
    // Populate cache from UserDefaults on first access.
    if let data = defaults.data(forKey: Self.defaultsKey),
       let entries = try? JSONDecoder().decode([PendingReminderEntry].self, from: data) {
      cache = entries
    } else {
      cache = []
    }

    // Observe successful capture uploads so we can remap pending-reminder
    // entries from clientID keys to server-assigned memoryID keys.
    // The notification fires from UploadQueue.drainRow after a 200 response.
    Task { @MainActor [weak self] in
      guard let self else { return }
      for await notification in self.notificationCenter.notifications(
        named: .captureUploadedNotification
      ) {
        guard let clientIDStr = notification.userInfo?["clientID"] as? String,
              let serverIDStr = notification.userInfo?["serverMemoryID"] as? String,
              let clientID = UUID(uuidString: clientIDStr),
              let serverMemoryID = UUID(uuidString: serverIDStr)
        else { continue }

        self.remap(clientID: clientID, to: serverMemoryID)
      }
    }
  }

  /// Initialises the store with an explicit `UserDefaults` suite and
  /// `NotificationCenter`.
  ///
  /// Use this in tests to back the store with hermetic, isolated instances:
  /// ```swift
  /// let suite = UserDefaults(suiteName: UUID().uuidString)!
  /// let center = NotificationCenter()
  /// let store = UserDefaultsPendingReminderStore(defaults: suite, notificationCenter: center)
  /// ```
  public init(defaults: UserDefaults, notificationCenter: NotificationCenter = .default) {
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    if let data = defaults.data(forKey: Self.defaultsKey),
       let entries = try? JSONDecoder().decode([PendingReminderEntry].self, from: data) {
      cache = entries
    } else {
      cache = []
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      for await notification in self.notificationCenter.notifications(
        named: .captureUploadedNotification
      ) {
        guard let clientIDStr = notification.userInfo?["clientID"] as? String,
              let serverIDStr = notification.userInfo?["serverMemoryID"] as? String,
              let clientID = UUID(uuidString: clientIDStr),
              let serverMemoryID = UUID(uuidString: serverIDStr)
        else { continue }

        self.remap(clientID: clientID, to: serverMemoryID)
      }
    }
  }

  /// Remap a pending-reminder entry's key from `clientID` to `serverMemoryID`.
  ///
  /// Called when the upload queue confirms a capture with the server UUID.
  /// No-op when there is no entry for `clientID`.
  func remap(clientID: UUID, to serverMemoryID: UUID) {
    guard let existing = cache.first(where: { $0.memoryID == clientID }) else {
      return  // No pending entry for this clientID — nothing to remap.
    }
    cache.removeAll { $0.memoryID == clientID }
    cache.append(PendingReminderEntry(
      memoryID: serverMemoryID,
      calendarItemIdentifier: existing.calendarItemIdentifier
    ))
    persist()
    print("[PendingReminderStore] remapped clientID=\(clientID) → serverMemoryID=\(serverMemoryID)")
  }

  // MARK: - PendingReminderStoring

  public func store(memoryID: UUID, calendarItemIdentifier: String) {
    // Remove any stale entry for this memoryID before inserting the new one.
    cache.removeAll { $0.memoryID == memoryID }
    cache.append(PendingReminderEntry(
      memoryID: memoryID,
      calendarItemIdentifier: calendarItemIdentifier
    ))
    persist()
  }

  public func entry(for memoryID: UUID) -> PendingReminderEntry? {
    cache.first { $0.memoryID == memoryID }
  }

  public func remove(memoryID: UUID) {
    cache.removeAll { $0.memoryID == memoryID }
    persist()
  }

  public func all() -> [PendingReminderEntry] {
    cache
  }

  // MARK: - Private

  private func persist() {
    guard let data = try? JSONEncoder().encode(cache) else {
      print("[PendingReminderStore] failed to encode entries — store not updated")
      return
    }
    defaults.set(data, forKey: Self.defaultsKey)
  }
}

// MARK: - Notification.Name

public extension Notification.Name {
  /// Posted by `UploadQueue.drainRow` after a successful capture upload.
  ///
  /// `userInfo` contains:
  ///   - `"clientID"` (`String`) — the `clientID` UUID string of the capture.
  ///   - `"serverMemoryID"` (`String`) — the server-assigned memory UUID string.
  ///
  /// Observers (e.g. `UserDefaultsPendingReminderStore`) use this to remap
  /// pending-reminder entries from client-side `clientID` keys to
  /// server-assigned `memory_id` keys, enabling reconciliation with `TaskDTO`.
  static let captureUploadedNotification = Notification.Name(
    "com.markdlabrecque.grove.upload-queue.capture-uploaded"
  )
}
