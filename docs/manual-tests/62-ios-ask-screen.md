# Manual tests — iOS Ask screen (#62)

End-to-end verification of the Ask flow: type a query, tap Ask, see ranked memory snippets from POST /v1/queries. Unit tests in `OracleCoreTests/JSONCodingTests.swift` cover encoding/decoding; this doc covers the live round-trip the simulator can't fake.

Run on **the Mac** (server stack + simulator, OR Xcode → physical iPhone over Tailscale).

## Prerequisites

- [ ] On the PR branch: `git fetch && git checkout 62-ios-ask-screen`
- [ ] Server stack up: `make up` (confirm `docker compose ps` shows `app`, `apache`, `postgres` healthy)
- [ ] Tailscale TLS ingress smoke-passes: `make smoke-ingress`
- [ ] `ios/Oracle/Oracle/Config.debug.xcconfig` populated (same as for #61):
  ```bash
  grep -E '^(BASE_URL|BEARER_TOKEN)' ios/Oracle/Oracle/Config.debug.xcconfig
  ```
- [ ] Open `ios/Oracle/Oracle.xcodeproj` in Xcode, select **Oracle** scheme + **iPhone 17** simulator, `Cmd+B` clean build succeeds.
- [ ] The `memories` table has rows with embeddings (297 rows at the time of writing — confirm with `make psql` then `SELECT COUNT(*) FROM memories WHERE embedding IS NOT NULL;`).

## 1. App launches without crashing

- [ ] `Cmd+R`. App lands on the Save (Capture) tab.
- [ ] Tap the **Ask** tab. The Ask screen renders: a query text field, an Ask button, and an empty body below.
- [ ] The Ask button is **disabled** when the field is empty.

## 2. Empty/whitespace guard — simulator

- [ ] Tap the text field. Type only spaces. Ask button stays **disabled**.
- [ ] Type a real character. Ask button enables.
- [ ] Delete the character. Ask button disables again.
- [ ] `.onSubmit` check: focus the field, type a query, tap the keyboard's Search key. Verify the query fires (spinner appears) — same as tapping Ask.

## 3. Golden path — live query against dev server

- [ ] Type a query that should match your captures, e.g. `SwiftData` or `offline capture`.
- [ ] Tap **Ask**. Button disables, spinner replaces the result list.
- [ ] After ~1 s, results appear as a scrollable list.
- [ ] Each result row shows:
  - A text snippet (up to ~3 lines before truncating).
  - A small grey percentage similarity (e.g. `91%`).
  - A small grey relative date (e.g. `2 days ago`).
  - For chunk-matched results: a small `[chunk N]` badge.
  - For whole-matched results: no badge (or subtle dot — check against the design).
- [ ] Scroll the list — at least a few results should be visible.
- [ ] Tapping a result row does **nothing** (no navigation). This is correct for V1.

## 4. No-matches path

- [ ] Clear the query field. Type a nonsensical query unlikely to match anything, e.g. `xyzzy quux frobble`.
- [ ] Tap Ask. After a moment, the result area shows **"No matches"** in secondary foreground colour.
- [ ] No crash.

## 5. Error preservation

- [ ] Stop the server (`docker compose stop app` or disconnect Tailscale).
- [ ] Type any query and tap Ask.
- [ ] An Alert appears with an error message. Tap **OK** to dismiss.
- [ ] The query text field retains its value — user can retry without retyping.
- [ ] The Ask button re-enables after dismissing the alert.

## 6. In-flight cancel-and-resend behaviour (#91)

**Background:** The Ask button stays enabled while a query is in flight. Tapping it (or hitting the return key) cancels the current request and fires a new one with whatever text is in the field at that moment. This is intentional — it lets the user revise mid-query without waiting.

- [ ] With the server running, type a slow query (e.g. one that produces many results). Tap Ask.
- [ ] While the spinner is visible, immediately type a new character and tap Ask again (or hit the return key). Verify:
  - The spinner clears for a moment (cancelled request drops), then reappears briefly as the new request fires.
  - No error alert pops up — cancellation is silent.
  - The results that eventually appear are from the **second** query, not the first.
- [ ] Repeat but do NOT modify the text field — tap Ask while the spinner is showing. The same query re-fires. No alert; spinner resets and results load again.
- [ ] If prior results were showing before the first tap: confirm those results are still visible in the brief moment between the cancel and the new spinner appearing (the list is not blanked to "nothing").
- [ ] **Empty field + in-flight:** while the spinner is running, clear the text field completely. Confirm Ask button **disables** — an empty query cannot cancel-and-resend.
- [ ] **Return key:** focus the field, type a query, tap Ask; then while loading, tap the field, change the text slightly, and hit the keyboard return key. Confirm the same cancel-and-resend cycle occurs (no duplicate in-flight requests).

## 7. Dynamic Type and VoiceOver smoke

- [ ] In the Simulator, Settings → Accessibility → Display & Text Size → Larger Text: drag to the largest accessibility size. Return to the app. Query field and result rows should reflow gracefully; no truncated labels or overlapping text.
- [ ] Simulator → I/O → Accessibility Inspector: enable VoiceOver. Swipe through the Ask screen. Verify:
  - Query field announces "Query field" / "Type a question to search your memories".
  - Ask button announces "Ask" / "Submit query to search your memories".
  - Result rows are grouped as a single element and read the snippet, similarity, and date.
  - `[chunk N]` badge announces as "Chunk N".

## 8. Latency sanity check

- [ ] Run a query. The round-trip (embed + two cosine searches) should complete in under ~1.5 s from tap to results. If it consistently takes longer, note it.

## Sign-off

All checkboxes above: [ ] pass / [ ] notes below.

Notes:
