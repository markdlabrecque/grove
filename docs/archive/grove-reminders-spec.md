# Grove — Reminders feature spec

> **STATUS: OUT OF SCOPE (archived 2026-05-17).** Reminders are not a Grove feature. Time-based notifications are delegated to Apple Reminders (via EventKit if Grove ever needs to create them programmatically). Rationale: third-party iOS apps are capped at 64 pending `UNUserNotificationCenter` requests, while Apple Reminders has effectively unlimited capacity, free multi-device sync via iCloud, and built-in Watch/Siri/Mac integration — none of which Grove can replicate without significant additional work. This document is preserved for the analysis only.

**Status:** Archived — out of scope
**Original author:** mark@affinitybridge.com (with Claude)
**Original draft date:** 2026-05-16
**Archived:** 2026-05-17

## 1. Summary

Grove gains a **standalone reminder** capability on the iOS client. A reminder is a self-contained "nudge at a future time" — not tied to any captured memory, not synced to the server, not visible from any other device. It fires as an iOS local notification.

This is the minimum viable surface to scratch the "I want Grove to ping me about a thing tomorrow at 9am" itch without depending on server push, APNs, or cross-device sync.

## 2. Goals & non-goals

### Goals

- Create, edit, delete, complete, and snooze reminders entirely on-device.
- Fire a local iOS notification at the scheduled moment, even if the app has been force-quit (within iOS's stated guarantees for `UNCalendarNotificationTrigger`).
- Support one-shot reminders and common recurrence patterns (daily, weekly).
- Survive app upgrades, device reboots, time-zone changes, and DST transitions without re-prompting the user.
- Stay strictly inside the app target — no GroveCore changes, no server changes, no API contract additions.

### Non-goals (V1)

- Cross-device sync. A reminder created on phone A is invisible to phone B. Acknowledged limitation; if multi-device matters later, that's a server-backed redesign.
- Server-driven notifications (APNs). Out of scope for V1; revisit if we ever need server-triggered reminders.
- Attaching reminders to existing memories ("remind me about this thought next week"). Different mental model, different UX, different data model. Tracked as future state — see §17.
- Location-based reminders. iOS supports them via `UNLocationNotificationTrigger`; out of scope for V1.
- Natural-language entry ("tomorrow at 3"). V1 uses native date/time pickers only.

## 3. User stories

1. **One-shot nudge.** "Remind me to email Sarah at 9am tomorrow." → set title + date, hit save, get a notification at 9am.
2. **Daily habit.** "Every weekday at 7am, remind me to log yesterday's notes." → set title + time + recurrence (weekdays).
3. **Weekly cadence.** "Every Monday at 10am, remind me to review last week." → set title + time + recurrence (Mondays).
4. **Snooze.** Notification fires; user taps "Snooze 10 min" from the notification banner or the in-app list and the reminder re-fires after 10 minutes.
5. **Complete.** User dismisses the notification with "Done" and the reminder is marked complete (one-shots disappear from the active list; recurring reminders fire again at their next scheduled time).
6. **Edit / cancel.** User opens the reminders list, taps a row, edits the time or deletes it. Pending notifications are rescheduled accordingly.
7. **Permission first-run.** First time the user creates a reminder, Grove requests notification permission. If denied, the user can still save reminders but the app surfaces a non-blocking banner explaining they won't fire until permission is granted.

## 4. UX flows

### 4.1 Entry point

A new tab or top-level destination — TBD whether reminders gets its own tab in the existing TabView or lives behind a Settings-adjacent entry. **Recommendation:** dedicated tab. Reminders is a primary user surface in its own right; burying it under Settings devalues it.

### 4.2 List view

- Sectioned: "Active" (pending), "Today" (firing within next 24h), "Completed (last 7 days)".
- Each row: title, next-fire datetime (humanized: "Tomorrow 9:00 AM" / "Every weekday 7:00 AM"), recurrence chip if any, swipe actions (Complete, Delete).
- Empty state: explainer copy + "Create reminder" CTA.

### 4.3 Create / edit sheet

Fields:
- **Title** (required, single line, ~80 char soft cap)
- **Notes** (optional, multi-line, ~500 char soft cap)
- **Date & time** (native `DatePicker`, `.dateAndTime` style)
- **Recurrence** (segmented control: None / Daily / Weekdays / Weekly / Custom-weekly)
- **Custom-weekly** reveals a 7-day toggle row when selected.

Save button enabled when title is non-empty and date is in the future (or recurrence is set).

### 4.4 Notification interaction

Notification payload includes two custom actions:
- **Done** — marks complete (one-shot deletes; recurring fires again next cycle).
- **Snooze 10 min** — reschedules a one-off trigger 10 minutes from now.

Tapping the notification body opens the reminder detail in-app.

### 4.5 Permissions flow

- On first save attempt: call `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])`.
- If denied: save the reminder anyway; render a banner in the list view: "Notifications are off — reminders won't fire until you re-enable them in Settings." Tap → deep link to `UIApplication.openSettingsURLString`.
- Re-check authorization on every app foreground; clear the banner if the user enabled in Settings and re-schedule any reminders whose triggers were lost.

## 5. Data model

A single SwiftData `@Model` in the app target (not GroveCore), per the existing `QueuedCapture` precedent.

```swift
@Model
final class Reminder {
  /// Stable UUID, generated at creation. Used as the SwiftData identifier and the
  /// base for `UNNotificationRequest.identifier` (one request per scheduled fire;
  /// recurring reminders may have multiple pending requests — see §6.3).
  var id: UUID

  /// Required, non-empty.
  var title: String

  /// Optional free-form notes shown in the detail view.
  var notes: String?

  /// The first scheduled fire time. For recurring reminders this is the anchor —
  /// the first fire date; subsequent fires derive from `recurrence`.
  var firstFireAt: Date

  /// Encoded recurrence rule. nil = one-shot. See §6 for the enum shape and
  /// rationale for storing it as a raw value.
  var recurrenceRawValue: String?

  /// nil while pending. Set when the user marks complete (one-shot) OR records
  /// the most recent completion of a recurring instance (we only track the last).
  var lastCompletedAt: Date?

  /// nil while pending. Set if the user has snoozed the most recent fire; the
  /// snooze trigger is scheduled as a one-off `UNTimeIntervalNotificationTrigger`.
  var snoozedUntil: Date?

  /// Set at creation, immutable thereafter. Useful for debug / list sort fallback.
  var createdAt: Date

  init(...) { ... }
}
```

### 5.1 Recurrence representation

`Recurrence` is a Swift enum encoded to `recurrenceRawValue` as JSON (rather than separate fields) to keep future cases additive without schema migrations:

```swift
enum Recurrence: Codable, Hashable {
  case daily
  case weekdays                   // Mon-Fri
  case weeklyOn(Set<Weekday>)     // arbitrary subset
}
```

Encoding choice trade-off: a single JSON column is easier to extend (add `.monthly`, `.everyN(days:Int)`) without `VersionedSchema` bumps; the cost is non-queryable recurrence (we'd need to load all reminders to filter "show me daily ones"). At our scale (hundreds of reminders max) that's fine.

### 5.2 Schema versioning

Day-1 wrap in `ReminderSchemaV1: VersionedSchema` and `ReminderMigrationPlan: SchemaMigrationPlan` per the `QueuedCapture` pattern. Empty `stages` array at V1. The first destructive change will add a stage; additive optional properties don't need one.

### 5.3 ModelContainer wiring

`GroveApp.modelContainer` currently registers `QueuedCaptureSchemaV1.models`. Either:

- **Option A** — Register both schemas in a single container.
- **Option B** — Two separate containers (`QueuedCapture` in one, `Reminder` in another).

**Recommendation:** Option A. SwiftData supports multiple model types in one container, and there is no cross-model relationship to worry about. Simpler lifecycle, one migration plan to reason about.

## 6. Notification scheduling

### 6.1 Trigger types used

- **One-shot reminders** → `UNCalendarNotificationTrigger(dateMatching:repeats:false)` with `DateComponents` extracted from `firstFireAt`.
- **Recurring reminders** → see §6.3.
- **Snoozes** → `UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)`.

### 6.2 Request identifier scheme

- One-shot: `reminder-<uuid>`
- Recurring instances: `reminder-<uuid>-<weekday>` (one request per scheduled weekday for `.weeklyOn`, one for `.daily`, five for `.weekdays`).
- Snooze: `reminder-<uuid>-snooze`

Stable identifiers mean we can always cancel and re-add on edits without bookkeeping.

### 6.3 Recurring reminders — the 64-request limit

iOS caps an app at **64 pending local notification requests**. If we use one `repeats: true` `UNCalendarNotificationTrigger` per weekday-of-week, a single `.weekdays` reminder consumes 5 requests. 12 such reminders would exhaust the budget.

**Approach:** for each recurring reminder, schedule one `UNCalendarNotificationTrigger(repeats: true)` per selected weekday — iOS handles the weekly cadence internally, so we don't have to roll forward. Budget usage:

- `.daily` → 1 request (`DateComponents(hour:, minute:)`, `repeats: true`)
- `.weekdays` → 5 requests
- `.weeklyOn(days)` → `days.count` requests

Cap the user's total recurring-reminder count to keep us under the limit. **Recommendation:** soft-cap at 20 recurring reminders, with the math: worst case 20 × 7 = 140, so we'd need to either (a) hard-cap weekday-set size, (b) accept fewer reminders, or (c) implement a rolling-window scheduler that only registers the next N fires and re-tops-up on app launch / background fetch.

**V1 decision:** soft-cap total scheduled requests at 60 (leave 4 in reserve for snoozes / one-shots / system overhead). Validate at save time, show an error if the user is at the cap.

### 6.4 Background re-registration

On every app launch and every foreground transition:

1. Query `UNUserNotificationCenter.pendingNotificationRequests()`.
2. Cross-check against the SwiftData `Reminder` store.
3. Re-register any missing requests (covers: OS upgrades that clear pending requests, time-zone changes, DST, user toggling notification permission off then on).
4. Cancel any orphaned requests (covers: reminder deleted while app was in background — shouldn't happen since deletes cancel inline, but defensive).

### 6.5 Time zone & DST

`UNCalendarNotificationTrigger` honors the current device time zone at fire time. A reminder set for 9am will fire at 9am local time after a tz change. This is the desired behavior and matches Apple Reminders / Calendar.

### 6.6 Notification content

```swift
let content = UNMutableNotificationContent()
content.title = reminder.title
content.body = reminder.notes ?? ""
content.sound = .default
content.categoryIdentifier = "REMINDER"  // wires up Done / Snooze actions
content.userInfo = ["reminderID": reminder.id.uuidString]
```

Register the category once at app launch with the Done / Snooze action set.

## 7. Permissions

- Request lazily on first save attempt (not at app launch — better conversion rate, less hostile).
- Three possible authorization states to handle: `.notDetermined` (request), `.denied` (show banner + Settings deeplink), `.authorized` / `.provisional` (proceed).
- Recheck on `scenePhase == .active`; reconcile pending requests if state flipped from `.denied` to `.authorized`.

## 8. App lifecycle considerations

| Event | Behavior |
|---|---|
| App force-quit | Pending notifications still fire (iOS owns them). |
| Device reboot | iOS restores pending requests. |
| App reinstall | All pending requests cleared. On first launch after reinstall, re-register from SwiftData store. |
| OS upgrade | iOS *usually* preserves pending requests, but treat as best-effort; reconcile on launch. |
| User revokes permission | Pending requests are silently suppressed by iOS. Banner shows on next launch. |
| Time zone change | `UNCalendarNotificationTrigger` adjusts; no app action needed. |
| App language change | Re-rendered notification content uses current locale strings at fire time. |

## 9. Snooze semantics

- Snoozing a one-shot: original trigger fires once; snooze creates a 10-minute one-off trigger. After the snooze fires, the reminder is back in the "fired-but-unhandled" state. The user can snooze again or mark Done.
- Snoozing a recurring reminder: the current instance is snoozed (one-off 10-min trigger fires once); the recurring schedule continues unaffected.
- Configurable snooze interval is out of scope for V1 — fixed at 10 minutes. Add a setting later if asked.

## 10. Completion semantics

- One-shot: `lastCompletedAt = Date()`, row stays in store for 7 days under "Completed (last 7 days)" then auto-deletes on next app launch via a sweep.
- Recurring: `lastCompletedAt = Date()`, no notification cancellation needed — the recurring trigger keeps firing.

## 11. Accessibility

- All form controls labeled for VoiceOver.
- Notification content meets readability defaults (system body weight, no custom truncation).
- Dynamic Type supported in list and detail views (no fixed font sizes).
- The recurrence selector exposes all options to VoiceOver in a single rotor; the 7-day weekday selector reads as "Monday, toggle, off" etc.

## 12. Telemetry & debug

- A debug screen (gated behind the same affordance as the upload-queue debug screen) shows: list of `Reminder` rows, list of `UNUserNotificationCenter.pendingNotificationRequests()`, and a "Reconcile now" button.
- No analytics events fire to the server in V1 (no server endpoint).
- Log-level diagnostics via the existing logger; one event per create / edit / delete / fire / snooze / complete.

## 13. Testing strategy

### Unit tests (`GroveTests/`)

- `ReminderTests` — model invariants (title non-empty, future-fire validation), recurrence encode/decode round-trip.
- `ReminderSchedulerTests` — given a `Reminder` with each `Recurrence` case, scheduler produces the expected set of `UNNotificationRequest` identifiers and triggers (mock `UNUserNotificationCenter`).
- `ReminderReconcilerTests` — given a SwiftData store and a mock pending-requests list, reconciler emits the correct add/cancel diff.
- `ReminderViewModelTests` — save validation, snooze action, complete action.

### Manual tests (`docs/manual-tests/` — untracked per durable convention)

- Schema V1 → V2 migration (document the steps when V2 lands).
- Force-quit + scheduled fire still rings the device.
- Permission deny → save reminder → see banner → enable in Settings → return to app → banner clears, requests re-registered.
- Time-zone change while a reminder is pending.

### CI gap awareness

Per durable memory: CI runs `ios-test-core` (GroveCore SPM only). Reminders lives in the app target, so its tests are local-only. Briefing for whoever picks up the implementation must include "run `make ios-test-app` locally before pushing."

## 14. Phased rollout — suggested ticket split

Spec-everything-then-split was the requested approach. My suggested cuts, smallest to largest:

1. **#XXX — Data model + schema versioning.** Add `Reminder`, `ReminderSchemaV1`, `ReminderMigrationPlan`. Wire into `GroveApp.modelContainer`. No UI, no scheduling. Tests for encode/decode and schema registration.
2. **#XXX — Notification scheduler.** Pure-logic layer that takes a `Reminder` and produces `UNNotificationRequest`s. Mock-driven tests. No UI integration yet.
3. **#XXX — Notification category & action handling.** Register the REMINDER category at app launch; handle Done / Snooze actions in `UNUserNotificationCenterDelegate`.
4. **#XXX — List view + empty state.** Read-only list, no create flow yet. Establishes navigation + tab placement.
5. **#XXX — Create / edit sheet (one-shot only).** End-to-end: user can create a one-shot reminder and have it fire.
6. **#XXX — Recurrence support.** Add daily / weekdays / weekly-on UX + scheduling.
7. **#XXX — Snooze.** Both notification-action and in-app snooze paths.
8. **#XXX — Reconciler + lifecycle hardening.** Foreground reconciliation, post-upgrade re-registration, the 60-request soft cap.
9. **#XXX — Permission flow polish.** Banner, Settings deeplink, re-check on foreground.
10. **#XXX — Debug screen.** Local-only diagnostics view.
11. **#XXX — Completed-sweep + auto-delete.** 7-day cleanup of one-shots.

Each ticket is independently mergeable. Tickets 1–3 can land before any user-facing feature is visible (gated behind absence of UI). Tickets 4–5 deliver the V1 happy path. 6–11 round out the feature.

## 15. Open questions

1. **Tab vs. menu.** Does reminders deserve its own tab, or live under a "More" / Settings entry? Affects #4 above. Recommend tab; want a second opinion.
2. **Soft-cap UX.** When the user hits the 60-request budget, do we show a friendly error and refuse to save, or quietly degrade by scheduling fewer fires? Recommend refuse + explain.
3. **Notification sound.** System default, or a custom sound bundled with the app? V1 = default; ask if there's an opinion.
4. **Snooze duration.** Fixed 10 min for V1, or do we make it tappable (10 / 30 / 60 from the notification)? iOS supports up to 4 actions per category, so it's feasible — but adds polish complexity.
5. **Completed history retention.** 7 days is a guess; tunable in a constant.

## 16. Risks

- **64-request iOS budget.** Already mitigated by the soft cap, but recurring + heavy users is the failure mode. Worst case: reduce cap or implement rolling-window scheduler (post-V1).
- **No sync = no recovery.** If the user wipes the device, all reminders are gone. Acknowledged; revisit if a multi-device feature ever lands.
- **Permission denial is silent.** Some users will create reminders, never grant permission, and wonder why nothing fires. The banner + Settings deeplink mitigates but doesn't eliminate.

## 17. Out of scope / future state

The following are deliberately deferred. If any of them land later, they should be filed as separate tickets with the `future-state` label:

- Attach-reminder-to-memory (the original "remind me about this thought" pattern).
- Server-backed reminders / cross-device sync / APNs.
- Location-based triggers.
- Natural-language entry ("tomorrow at 3").
- Apple Watch complication / Live Activities.
- Siri Shortcuts integration (would slot in alongside `CaptureViaDictationIntent`).
- Custom snooze durations.
- Custom recurrence (`every N days`, monthly, yearly, end-date for recurrences).

## 18. Implementation notes — anchored to existing patterns

- **App target only** (per `QueuedCapture` precedent): `@Model` requires SwiftData macro infra; GroveCore stays SwiftData-free.
- **VersionedSchema from day 1** (per `QueuedCaptureSchemaV1` precedent): even though there's nothing to migrate yet, the wrapping gives us a safe path for future destructive changes.
- **No new server dependency**: every code path stays inside the app target. Server is unaware reminders exist.
- **Strict-serial tickets**: per durable convention, dispatch one of the §14 cuts at a time; wait for PR merge before queueing the next.
- **TDD red-before-green**: each ticket should land its failing tests in a commit that precedes the production code commit.

---

**Next action**: review this spec, decide which §14 cuts to file as tickets and in what order, and whether any §15 open questions need to be resolved before the first ticket lands.
