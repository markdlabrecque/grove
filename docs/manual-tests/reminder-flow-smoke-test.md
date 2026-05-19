# Reminder flow smoke test

**Purpose:** Verify end-to-end behaviour of the EventKit reminder pipeline before designing #404 (TaskReconciler foreground sweep). Determines which workflows actually depend on reconciliation vs. which already work today.

**Status:** Deferred (2026-05-18). This doc captures the test plan so it can be run later without re-deriving it.

**Related:**
- #391 — surface extracted tasks via EventKit tap-to-create
- #397 — track-as-task toggle + guaranteed enrichment + reminder reconciliation
- #404 — TaskReconciler view-appearance trigger (the ticket this test informs)
- Memory: `eventkit_integration_shipped`, `reminders_out_of_scope`

---

## What we're testing

The user's concern: "I don't want to have to visit a memory for the Reminder to work."

Reconciliation in the current architecture is the **client→server PATCH** that informs the server which Apple Reminder is linked to a given task row. It does NOT create the reminder — that happens locally at save time. The smoke test separates these two concerns so we know which (if either) is actually gated on visiting a memory.

---

## Pre-flight

1. Fresh state on the device/simulator:
   - Delete the Grove app (clears `PendingReminderStore` UserDefaults).
   - Delete any "Grove" or test reminders from Reminders.app.
   - Reinstall Grove from Xcode.
2. Server running locally (or pointing at the dev server — check `xcconfig`).
3. Open three terminal panes:
   - **Pane A** — server log tail: `cd ~/Projects/grove/server && uv run uvicorn grove.main:app --reload` (or whatever the dev command is), or `tail -f` the running server's log file.
   - **Pane B** — `watch -n 2 'direnv exec . curl -s "$GROVE_BASE_URL/v1/tasks" -H "Authorization: Bearer $GROVE_API_TOKEN" | jq "[.[] | {id, memory_id, eventkit_identifier, description}]"'` (adjust endpoint to whatever the actual list-tasks API is — check `server/grove/api/tasks.py`).
   - **Pane C** — simulator Reminders DB peek (optional, simulator only):
     - The simulator's Reminders store lives under `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Shared/SystemGroup/systemgroup.com.apple.reminders/`. Easier path: open Reminders.app on the simulator and visually confirm.

---

## Test 1 — Reminder creation at save time (does NOT depend on reconciliation)

**Goal:** Confirm the Apple Reminder appears in Reminders.app within seconds of save, without ever opening a Grove memory view.

1. Launch Grove on device.
2. New capture: type "Buy milk tomorrow at 5pm" (or any task-shaped text).
3. Toggle "Track as task" ON.
4. Tap Save.
5. **First time only:** grant EventKit permission when prompted.
6. **Without opening any Grove memory or task list view**, open Reminders.app.

**Pass:** Reminder titled "Buy milk" (or close) appears in the default list within ~5 seconds, with the due time set.

**Fail modes:**
- No reminder appears → bug is in `LiveEventKitProvider.save` or the `PendingReminderStore` save-time path, NOT reconciliation. #404 is the wrong ticket.
- Reminder appears only after opening Grove again → save-time creation is broken; the reminder is being deferred until something else triggers it.
- Permission prompt never appears → entitlement issue in Xcode project settings.

---

## Test 2 — Reminder fires on time without opening Grove

**Goal:** Confirm the local reminder notification fires regardless of Grove's state.

1. Set the capture's due time ~2 minutes out.
2. Force-quit Grove (swipe up from app switcher).
3. Wait for the due time.

**Pass:** iOS notification fires from Reminders.app at the due time.

**Fail:** This would be a real bug — but unlikely, since the reminder lives in EventKit and iOS handles notification scheduling.

---

## Test 3 — Server task row appears (enrichment)

**Goal:** Confirm the server creates a Task row from the capture.

1. After Test 1 save, watch Pane A (server log) for enrichment activity. With `client_intent="task"` the orchestrator force-creates a task even if classification returns none.
2. Watch Pane B (task list poll) — a new row should appear within ~30s with `description` populated and `eventkit_identifier=null`.

**Pass:** Task row appears with `eventkit_identifier` initially null.

**Fail:** Enrichment didn't run or didn't create a task → server-side bug, unrelated to #404.

---

## Test 4 — Reconciliation gap (the #404 question)

**Goal:** Determine whether `eventkit_identifier` on the server task row ever gets populated WITHOUT visiting a memory.

1. After Test 3 confirms the task row exists with `eventkit_identifier=null`, do NOT open Grove.
2. Leave the app backgrounded for 5+ minutes.
3. Foreground Grove but stay on the capture screen (no memory navigation).
4. Watch Pane B — does `eventkit_identifier` get set?

**Expected outcome (today, pre-#404):** `eventkit_identifier` stays null. `TaskRowView.onAppear` is the only reconciliation trigger and `TaskListView`/`TaskRowView` aren't wired to any user-facing surface, so it never fires.

**If it DOES get set:** something else is triggering reconciliation we don't know about — read code before designing #404.

---

## Test 5 — Server→Reminder sync (depends on reconciliation)

**Goal:** Identify which user-visible feature actually needs reconciliation to be reliable.

1. Pick the task from Test 3 (`eventkit_identifier=null`).
2. Mark it complete on the server (via web UI if it exists, or `curl PATCH /v1/tasks/{id} -d '{"completed_at": "..."}'`).
3. Wait. Does the Apple Reminder flip to "completed"?

**Expected outcome (today):** No, because the server doesn't know which reminder to flip.

**If reconciliation HAD run** (e.g. user had visited the memory once): server would know the `eventkit_identifier`, but there's still no mechanism for server→client reminder updates today. So even reconciled tasks don't sync server→client yet. That's a separate ticket beyond #404.

---

## Decision matrix after running the tests

| Test 1 result | Test 2 result | Test 4 result | What's broken | Right fix |
|---|---|---|---|---|
| Pass | Pass | Pass (null) | Nothing user-visible | Defer #404 — no urgent user impact |
| Pass | Pass | Fails (gets set) | Hidden trigger | Investigate before designing |
| Fail | — | — | Save-time reminder creation | New ticket, not #404 |
| Pass | Fail | — | Notification scheduling | iOS-side, not #404 |

#404's foreground sweep is only the right design if Test 1+2 pass AND we have a future workflow (Test 5 class) where the server needs to find the Reminder. The sweep alone doesn't deliver user-visible value until server→Reminder push exists.

---

## Notes

- This doc is intentionally **not committed** per `manual-test-docs-untracked` memory. Run, learn, throw away (or update in place).
- If results change the #404 scope, write the conclusions into the ticket comment, not this file.
