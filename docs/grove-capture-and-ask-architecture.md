# Grove — Capture and Ask architecture (V2)

**Status:** Decided architecture
**Author:** mark@affinitybridge.com (with Claude)
**Date:** 2026-05-17
**Supersedes (capture/ask surface decisions only):** the analysis in `docs/grove-surface-comparison.md`, which remains valid as decision-tree history.

## 1. Summary

Grove's user-facing surface architecture is being restructured around two principles:

- **Capture happens through Apple Notes**, dictated on any Apple device, synced via iCloud to the Mac Mini, ingested server-side by an AppleScript-driven job.
- **Ask happens via two complementary surfaces**: an iOS Shortcut bound to a convenient action (Action Button or equivalent) for fast voice queries, and a web UI on `grove.mark.io` for deep-dive use cases.

There is **no native iOS app** in the V2 architecture. The existing app will be retired. There is no Apple Developer Program membership required. There is no Matrix homeserver. All client-facing functionality runs over standard iOS Shortcuts, Apple Notes' built-in iCloud sync, and a web UI.

Acronym key:
- **STT** — Speech-to-Text
- **TTS** — Text-to-Speech
- **LLM** — Large Language Model
- **TCC** — Transparency, Consent, and Control (Apple's privacy permission framework)
- **MCP** — Model Context Protocol (Anthropic's open standard for AI tool integration)

## 2. Architecture overview

```
┌──────────────────────────────────────────────────────────────┐
│  CAPTURE PATH                                                 │
│                                                                │
│  iPhone / Watch / Mac / iPad (Apple Notes app)                │
│      │                                                         │
│      │  user dictates into "Grove Inbox" folder               │
│      ▼                                                         │
│  iCloud sync                                                   │
│      │                                                         │
│      ▼                                                         │
│  Mac Mini (Apple Notes app, signed into same iCloud)          │
│      │                                                         │
│      │  AppleScript ingester polls every ~5 min               │
│      ▼                                                         │
│  Grove server (FastAPI + Postgres + pgvector)                 │
│      │                                                         │
│      ▼                                                         │
│  AppleScript moves note to "Grove Archive" (V1)               │
│      or deletes it after grace period (post-V1)               │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  ASK PATH                                                      │
│                                                                │
│  Quick voice ask:                                              │
│      iOS Shortcut → dictate → POST /queries → speak result    │
│                                                                │
│  Deep-dive ask:                                                │
│      Web UI (grove.mark.io) → chat-style interface →          │
│      POST /queries → render answer + sources + history        │
└──────────────────────────────────────────────────────────────┘
```

Both ask surfaces hit the same `/queries` endpoint on the Grove server. The web UI uses the richer response (sources, history) more fully than the Shortcut.

## 3. Decisions made

The following are decided and not under negotiation in V2:

| Decision | Choice |
|---|---|
| Primary capture surface | Apple Notes (via iCloud sync to Mac Mini) |
| Primary ask surface (fast/voice) | iOS Shortcut over HTTPS |
| Primary ask surface (deep) | Web UI on `grove.mark.io` |
| Native iOS app | **Retired.** No Swift code in the V2 architecture. |
| Apple Developer Program membership | Not required and not paid for |
| Matrix / Element homeserver | Not deployed |
| Server location | Mac Mini, unchanged |
| Server stack | FastAPI + Postgres + pgvector, unchanged |
| Cross-device capture coverage | Inherited from Apple Notes' iCloud sync (iPhone / iPad / Mac / Watch) |
| Voice transcription on capture | Apple's on-device dictation in Notes |
| Document corpus integration | Per `docs/grove-document-corpus-spec.md` — additive, unaffected by this decision |

## 4. Rationale

### Why Apple Notes for capture

- **Universal Apple-device coverage** for zero engineering cost. Every device the user owns already has Notes.
- **Voice dictation is native** and high-quality without any STT work on Grove's side.
- **Offline capture is built in.** Notes queues offline and syncs when connectivity returns. Grove inherits this for free.
- **No Apple Developer Program required.** Saves the $99/yr permanent line item that the iOS-app path would impose.
- **Apple Watch capture works** out of the box via the system Notes app — no separate watchOS target to build or maintain.
- **Acceptable latency tradeoff.** iCloud sync is typically seconds-to-minutes for short text. For Grove's "capture a thought" use case (not "fire-and-forget transactional record"), this latency is tolerable.

### Why Shortcut + Web UI for ask

- **Shortcut covers the fast/voice path** with latency on par with a native app (no app launch overhead).
- **Web UI covers the deep-dive path** — long-form answer reading, history, future multi-turn — with significantly less maintenance burden than SwiftUI.
- **Single backend** serves both: `POST /queries` is unchanged from the current iOS app's contract.
- **Multi-turn conversation is net-new on any surface.** The current iOS app's Ask is single-turn. Building chat-style Ask in a web UI is cheaper and faster than rebuilding it in SwiftUI.
- **Web UI is needed regardless** for browsing memories, viewing source documents, and admin tasks. The Ask integration is incremental work on top of that surface.

### Why retire the iOS app

- **It does not justify the $99/yr Apple Developer Program** at one-user scale once capture moves to Apple Notes and Ask moves to Shortcut + Web UI.
- **The app's value proposition was the native capture flow.** With capture now flowing through Notes, the app's primary purpose is gone.
- **Ongoing maintenance burden** (TestFlight resigns, iOS version compatibility, Swift evolution, dependency updates) is removed entirely.
- **The app is not a sunk cost worth preserving** if it isn't paying for its maintenance overhead. V1 shipped; the codebase lives in git history if ever needed.

## 5. V1 scope

What ships in the V2-architecture V1:

- **Apple Notes ingester:** AppleScript-driven Python module on the Grove server, invoked every 5 minutes by an extension to the existing `grove-enrichment` LaunchAgent. Reads notes from a dedicated "Grove Inbox" folder, ingests new ones as memories, moves successfully-ingested notes to a "Grove Archive" folder.
- **`processed_apple_notes` tracking table:** stores ingested note IDs to make the ingester idempotent. Schema: `(note_id, ingested_at, memory_id)`.
- **Ask Shortcut:** dictate → POST `/queries` → speak the answer via system TTS. Single Shortcut, installable via Files / Share. Bound to a convenient invocation surface (Home Screen widget, Control Center, or Siri).
- **Web UI V1:** single-page app served by Grove on `grove.mark.io`. Capabilities:
  - Sign-in (existing bearer-token auth)
  - Memory list view with pagination, basic search, tag filtering
  - Ask interface (single-turn for V1, structured for future multi-turn)
  - Source-attribution rendering (memory excerpts inline with answers)
  - Ask history (last N queries with their answers, persisted server-side)
- **iOS app retirement:** the existing app stays installed on the user's phone for a transition period (up to 30 days), then is deleted. The TestFlight build is allowed to expire without re-upload. The `ios/` directory in the repo is preserved in git history but development on it stops.

## 6. Out of scope for V1

- **Direct iOS-app deprecation announcements / migration tooling.** One-user transition; no external users to migrate.
- **Multi-turn conversation in Ask.** Single-turn only in V1, both via Shortcut and Web UI. Add later if desired.
- **Shortcut on Apple Watch.** The Shortcut works on iOS; watchOS Shortcut support is a polish add-on, not V1.
- **Action Button binding decision.** The Action Button on iPhone 15+ can be bound to either the Notes-capture path or the Ask Shortcut, but not both natively. Decision deferred to user preference; either is supported by the architecture.
- **Push notifications.** Not needed in V2; reminders are out of scope (`docs/archive/grove-reminders-spec.md`).
- **MCP exposure of Grove tools.** Useful long-term for Claude Desktop integration; not V1.
- **Mac menu-bar app, CLI, or other surfaces.** Possible additions later, all flowing through the same `/queries` and `/capture` endpoints. None required for V1.
- **Telegram / Slack bot integration.** Considered and rejected — not needed once Apple Notes covers cross-device capture.
- **Hardening of delete-after-ingest.** V1 uses move-to-archive (safer); switching to delete-with-grace-period happens post-V1 after pipeline confidence is established.

## 7. Build effort

Rolling up the work to land V2:

| Component | Hours | Notes |
|---|---|---|
| Apple Notes ingester (AppleScript + Python wrapper) | 4–6 | TCC permission setup is a one-time chore |
| `processed_apple_notes` migration + tracking | 1–2 | Small migration |
| LaunchAgent extension for ingester polling | 1–2 | Reuse existing `grove-enrichment` pattern |
| Move-to-archive AppleScript path | 1–2 | Single AppleScript verb |
| Ask Shortcut authoring | 1–2 | Manual via Shortcuts app; document the steps |
| Web UI V1 (sign-in, memory list, ask, history) | 12–20 | Largest single item |
| Web UI deployment + reverse proxy | 2–3 | Same domain, behind existing TLS |
| iOS app retirement (uninstall, repo flag) | <1 | Mostly removing dev-time references |
| Documentation + RUNBOOK updates | 2–3 | TCC setup instructions, Shortcut import, web UI URL |
| **Total** | **~24–40 hours** | Roughly 5–8 tickets |

About a long weekend or two of focused work. Significantly less than continuing iOS-app development (estimated 40–80 hours just for parity ask UI + ongoing).

## 8. Risks

### Apple Notes sync latency (medium risk, high frequency)

iCloud sync is typically seconds for short text but can stretch to several minutes under poor connectivity, when Photos is syncing aggressively, or when Apple is throttling. **Mitigation:** acceptable for Grove's "capture a thought, no urgency" use case. If a user wants to verify capture arrival quickly, they can glance at the Notes app on any Apple device (synced state visible across all signed-in devices).

### TCC permission revocation (low risk, recoverable)

macOS occasionally prompts for re-confirmation of Automation permissions, particularly after OS upgrades. If permission is revoked, the ingester silently fails until re-granted. **Mitigation:** add a health check to Grove's web UI showing "last successful Apple Notes poll at T, N notes ingested." Manual re-grant takes seconds.

### iCloud reauth (medium risk, infrequent)

Apple occasionally requires iCloud reauthentication on the Mac Mini. While reauth is pending, no notes sync. **Mitigation:** same health check as above. Reauth is a manual step but rare (months between).

### AppleScript dictionary changes between macOS versions (low risk, possible disruption)

macOS updates have historically changed AppleScript dictionaries for first-party apps. A Notes dictionary change could break the ingester. **Mitigation:** the ingester is small (~50 lines of AppleScript); updates are tractable. Worth pinning the macOS version on the Mini for a few weeks after each major release before upgrading.

### Web UI as the only deep-dive surface (medium risk, UX-dependent)

If the user finds the web UI consistently awkward on mobile (e.g., when browsing memories on the phone), the "no native app" decision starts to feel limiting. **Mitigation:** invest in genuinely mobile-responsive web design from V1; revisit if the experience proves consistently frustrating. The architecture leaves the door open to a native mobile UI in the future without disrupting capture/ask.

### Disappearing-notes UX (low risk, easily mitigated)

If notes vanish from the inbox folder immediately on ingestion, the user may find it disorienting. **Mitigation:** V1 moves to archive instead of deleting; the note is still visible, just in a different folder. Switch to delete-with-grace-period later if the archive folder becomes cluttered.

## 9. Open questions

1. **Action Button binding.** Bind to direct Notes capture (single-press → dictate into Grove Inbox) or to the Ask Shortcut? Or to a custom Shortcut that branches? User preference; either fits the architecture.
2. **Ask entry points beyond Action Button.** Home Screen widget, Control Center button, Siri Shortcut ("Hey Siri, ask Grove…"), Apple Watch action — which to set up in V1?
3. **Web UI framework choice.** SvelteKit, Next.js, Astro, plain HTML+HTMX, FastAPI server-rendered templates? Affects effort estimate above (the 12–20 hours assumes a lightweight choice).
4. **Web UI authentication model.** Reuse the bearer token from the existing iOS app, or switch to session cookies, or both? Different operational properties.
5. **Apple Notes folder name.** "Grove Inbox" is the working name; alternatives include "Grove Capture," a sentinel emoji prefix, or a deeper nested folder.
6. **Polling cadence.** 5 minutes is the proposed default; 2 minutes is more responsive at modest extra cost. Worth deciding once usage cadence is known.
7. **iOS app code preservation.** Keep `ios/` in the repo for posterity, or delete it cleanly with the V2-architecture commit? Either is defensible.
8. **LLM hosting strategy.** Independent of this architecture but a parallel open decision: full cloud, hybrid, or local. The capture/ask surface choice is unaffected.

## 10. Success criteria

V2 ships when:

- A new dictation in Apple Notes (in the Grove Inbox folder) on any Apple device appears as a memory in Grove within 10 minutes of dictation.
- The note is moved to the Grove Archive folder after ingestion succeeds.
- A user can invoke the Ask Shortcut, speak a question, and hear the answer read aloud — end-to-end working without any iOS app installed.
- The web UI loads at `grove.mark.io`, authenticates the user, lists memories, and supports asking a question with rendered answer + sources.
- A user has not installed the Grove iOS app in 14+ days without missing any functionality.
- The Grove server runs the ingester continuously for 7 days without TCC, sync, or AppleScript failures.

---

## Appendix A — Rejected paths

The following architectures were considered in earlier design conversations and rejected for V2. They are preserved here as decision-context rather than re-litigated.

### A.1 Continuing the custom iOS app (rejected)

**The path:** Keep building on the V1 iOS app (`ios/Grove/`). Add Ask UI, polish, future features in Swift.

**Why rejected:**
- Locks in $99/yr Apple Developer Program for the indefinite life of Grove.
- TestFlight rebuild every 90 days as ongoing chore.
- High ongoing maintenance against Swift/iOS evolution.
- No corresponding value once capture moves to Apple Notes — the app's primary purpose evaporates.
- Effort to reach feature parity (Ask UI + ongoing) estimated at 40–80 hours vs. ~24–40 for the V2 path.

**When this would be reconsidered:**
- If Apple Notes' capture path proves unreliable in practice.
- If voice-quality, review-before-save, or other native-only UX patterns become must-haves.
- If the user wants to ship Grove publicly (App Store presence is then the rationale, separate from cost optimization).

### A.2 Matrix / Element bridge as primary surface (rejected)

**The path:** Self-hosted Conduit homeserver on the Mac Mini. Grove bot in a private Matrix room. Element clients as the capture and ask surfaces. Optional bridges (mautrix-slack, mautrix-telegram, etc.) for additional input.

**Why rejected:**
- Higher capture friction than Action Button or Apple Notes (open Element → navigate → hold-to-record).
- Adds a Matrix homeserver process to maintain alongside Grove.
- Bridge fragility for third-party app integrations.
- Apple Notes covers cross-device capture without any of this complexity.
- The chat metaphor is genuinely good for Ask but the web UI achieves the same outcome with less infrastructure.

**When this would be reconsidered:**
- If cross-device capture from non-Apple platforms (Linux, Windows) ever matters.
- If the user wants Grove to integrate with chat-tool workflows (Slack at work, Telegram, Discord).
- For its own sake as a learning project around the Matrix protocol.

### A.3 Reminders as a Grove-native feature (rejected)

**The path:** Build time-based reminders into Grove with iOS notifications via `UNUserNotificationCenter`.

**Why rejected:**
- 64-pending-notification cap on third-party iOS apps would force a soft cap or rolling-window scheduler.
- Apple Reminders has no equivalent cap, plus free iCloud sync across all Apple devices, plus Siri integration.
- The data-sovereignty argument is weak for ephemeral nudges compared to durable memories.
- Out of scope per `docs/archive/grove-reminders-spec.md`.

**When this would be reconsidered:**
- Probably not. Apple Reminders is the right answer for "ping me at 3pm" data.

### A.4 Push notifications via Apple Push Notification service (rejected)

**The path:** Server-driven push notifications via APNs (Apple Push Notification service) for any future feature requiring out-of-band alerts.

**Why rejected:**
- Requires the $99/yr Apple Developer Program — defeats the cost-optimization goal of V2.
- Requires an iOS app, which V2 is retiring.
- No Grove use case yet justifies the cost.

**When this would be reconsidered:**
- Only if a specific Grove feature emerges that genuinely requires push (none currently).

### A.5 Markdown-as-source-of-truth for memories (rejected for V1)

**The path:** Write every Grove capture as a markdown file in a git repo (Obsidian vault). Postgres becomes a rebuildable index.

**Why rejected (for V1):**
- Captures need to be fast and durable in milliseconds; file I/O + git + iCloud sync is seconds.
- Concurrency hazards between Grove's enrichment writes and user edits in Obsidian.
- Enrichment write-back requires sidecar files, which is half a step away from just using a database.
- Apple Notes capture + Postgres storage gives most of the portability story (via document corpus integration on a separate Obsidian vault) without the costs.

**When this would be reconsidered:**
- If the user's workflow shifts to "Obsidian as the primary authoring surface" with Grove as an enhancement layer rather than a capture surface.

### A.6 Apple Notes ingestion for the document corpus (rejected for V1)

**The path:** Index Apple Notes content into Grove's document corpus alongside the Obsidian vault.

**Why rejected (for V1):**
- Notes content is messier than curated Obsidian (screenshots, mixed lists, attachments) — signal-to-noise hurts retrieval quality.
- Obsidian alone covers the document corpus use case for V1.
- The schema is designed to accept additional `source` types later if Notes ingestion becomes valuable.

**Note:** This is **different** from using Apple Notes as a capture surface (which is the V2 decision). Capture data is meant to be messy and short-form. Document corpus data is meant to be curated and long-form. Notes is a poor fit for the latter, a great fit for the former.

**When this would be reconsidered:**
- If a specific class of content lives only in Notes and would meaningfully improve answers.

### A.7 Server-coupled iOS app with APNs push notifications (rejected)

**The path:** Keep the iOS app for capture, add server-side push via APNs, build a full notification-driven feature surface.

**Why rejected:**
- Requires the $99/yr Apple Developer Program permanently.
- All the costs of A.1 (iOS-app continuation) plus the additional complexity of an APNs integration on the server.
- No notification feature in V2 scope justifies this.

**When this would be reconsidered:**
- Only if Grove genuinely needs server-driven push to the user's phone. Not foreseen.

### A.8 Local frontier-quality LLM on a high-tier Mac Mini (deferred, not rejected)

**The path:** Buy an M4 Pro Mac Mini with 48–64 GB RAM. Run a 32B–70B local LLM via Ollama / MLX. All Grove inference happens locally.

**Why deferred for V2:**
- Hardware premium ($1,200–1,500 over base) doesn't pay back versus cloud LLM costs at one-user scale until ~5–7 years.
- Quality of locally-runnable models still trails frontier cloud models on Grove's hardest tasks (multi-hop ask, nuanced enrichment).
- This decision is **orthogonal** to the capture/ask surface decision. The architecture in this doc works equally well with cloud, hybrid, or local LLM hosting; the choice can be made independently and revisited later.

**When this would be reconsidered:**
- Cloud LLM pricing changes meaningfully (significant price hikes from major providers).
- Locally-runnable open models reach frontier quality.
- Data-sovereignty concerns become more pressing than they currently are.

---

## Appendix B — References

- `docs/grove-surface-comparison.md` — original three-option decision tree (preserved as history).
- `docs/grove-document-corpus-spec.md` — document corpus (Obsidian) integration spec (additive, unaffected by this decision).
- `docs/archive/grove-reminders-spec.md` — archived reminders spec (feature out of scope).
- Memory: `project_reminders_out_of_scope.md` — durable record of the reminders decision.
