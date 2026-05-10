# Manual tests — iOS Save screen (#61, PR #80)

End-to-end verification of the Save flow added in PR #80: type a thought, tap Save, watch it land in the server's `captures` table over the bearer-auth Tailscale path. The unit tests in `OracleCoreTests/OracleAPITests.swift` cover encoding correctness; this doc covers the live round-trip the simulator can't fake.

Run on **the Mac** (server stack + simulator, OR Xcode → physical iPhone over Tailscale). Annotated where it matters.

## Prerequisites — on the Mac

- [ ] On the PR branch: `git checkout 61-ios-save-screen && git pull`
- [ ] Server stack up: `make up` (or confirm `docker compose ps` shows `app`, `apache`, `postgres` healthy)
- [ ] Tailscale TLS ingress smoke-passes: `make smoke-ingress` — if that fails, fix the ingress before testing the iOS app
- [ ] `ios/Oracle/Oracle/Config/Debug.xcconfig` populated with real values:
  ```bash
  grep -E '^(BASE_URL|BEARER_TOKEN)' ios/Oracle/Oracle/Config/Debug.xcconfig
  ```
  `BASE_URL` should point at `https://$TAILSCALE_HOSTNAME` (the Apache TLS endpoint, not localhost). `BEARER_TOKEN` must match the server's `.env` value.
- [ ] Open `ios/Oracle/Oracle.xcodeproj` in Xcode, select the **Oracle** scheme + **iPhone 17** simulator (or your device), `Cmd+B` clean build succeeds.

## 1. App launches without crashing — simulator

- [ ] `Cmd+R` to run. App lands on the Capture screen.
- [ ] No `fatalError` from `Config.shared` (this would manifest as the simulator app dying immediately on launch).
- [ ] The capture text area is visible, the **Save** button is below it, and the Save button is **disabled** while the text area is empty.

## 2. Empty-content guard — simulator

- [ ] Tap the text area. Type only spaces and newlines. Save button stays disabled (whitespace doesn't count as content).
- [ ] Type a real character. Save button enables.
- [ ] Delete the character (backspace). Save button disables again.

## 3. Golden path — Save lands in the database — simulator + Mac terminal

- [ ] Type something memorable: e.g., `Manual test ping at <current time>`.
- [ ] Tap **Save**. Expected sequence:
  - Save button disables, spinner appears in the status area below.
  - Within ~1–2 s (OpenAI embedding latency), spinner replaced by a green "Saved" checkmark.
  - Text area clears.
  - "Saved" indicator dismisses after ~1.5 s.
- [ ] On the Mac, query the database:
  ```bash
  docker compose exec -T postgres psql -U postgres -d oracle \
    -c "SELECT id, client_id, content, source_modality, source_device, language, captured_at FROM captures ORDER BY captured_at DESC LIMIT 1;"
  ```
  Expect a row with:
  - `content` = your typed text (trailing whitespace trimmed)
  - `source_modality` = `text`
  - `source_device` = `iphone`
  - `language` = `en`
  - `captured_at` ≈ now, with timezone

## 4. Idempotency on retry — simulator

The server uses `client_id` as an idempotency key. The current UI generates a fresh UUID per Save tap, so this isn't user-reachable from the screen — but worth verifying the encoder includes it.

- [ ] In the row from step 3, confirm `client_id` is a valid UUID string (not null, not empty, lowercase).

## 5. Network failure preserves content — simulator + Mac terminal

- [ ] On the Mac, stop the app container: `docker compose stop app`. (Apache stays up; this gives a 502 from upstream, which the iOS app treats as a network failure.)
- [ ] In the simulator, type a different memorable string.
- [ ] Tap **Save**. Expected:
  - Spinner shows briefly.
  - An alert appears with an error message (server's `detail` field if present, otherwise a generic "Could not save" message).
  - Dismiss the alert. **The text area still contains your input** (this is the key behavior — losing typed content on failure would be bad).
- [ ] Restart the app: `docker compose start app`.
- [ ] Wait ~5 s for the app to be ready, then tap **Save** again on the same content. Should succeed (golden path from step 3 repeats).

## 6. Authorization failure — simulator + Mac terminal

- [ ] On the Mac, temporarily change `BEARER_TOKEN` in `.env` to something wrong, then `make up` to restart with the new token.
- [ ] In the simulator (which still has the old token in xcconfig), tap **Save** with any content.
- [ ] Expected: alert shows a 401-shaped error (server's `detail` like `"Invalid bearer token"`).
- [ ] Restore the original `BEARER_TOKEN` in `.env`, `make up`, and confirm Save works again.

## 7. Spinner-during-flight disables Save — simulator

Hard to catch this manually if the request is fast. Instead:

- [ ] On the Mac, add latency to the app: `docker compose exec app bash -c "tc qdisc add dev eth0 root netem delay 3000ms"` (or just stop and start `app` and tap Save during the brief unavailable window).
- [ ] In the simulator, type content and tap **Save**. While the spinner is visible:
  - The Save button is greyed out / non-tappable.
  - The text area still accepts input (you can type more, that's fine — you're queuing up the next thought).
- [ ] After completion, remove the latency: `docker compose exec app bash -c "tc qdisc del dev eth0 root netem"` (or just stop+start the container). 

## Sign-off

- [ ] All sections passed → comment "Manual test passed" on PR #80 and unblock Theo for review/merge.
- [ ] Anything failed → comment the specific failure on PR #80 and route back to Kai.

## Out of scope for this ticket (future markers)

- Offline queue / retry on reconnect (`// TODO(offline):` in `CaptureViewModel.swift`) — V2.
- Voice / Whisper input (`source_modality=voice`) — separate ticket.
- Multi-device disambiguation via `identifierForVendor` — separate ticket.
