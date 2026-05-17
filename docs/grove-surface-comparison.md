# Grove — User-surface comparison

**Status:** Decision-support doc
**Author:** mark@affinitybridge.com (with Claude)
**Date:** 2026-05-17

## Purpose

Compare the three frontrunner architectures for how Grove's primary user surfaces (capture and ask) reach the user. Intended to support an architectural decision, not to recommend a single winner.

> **Scope note:** Data sovereignty (where memories physically reside, who can see them) is intentionally **excluded** from this comparison. The author has decided that the cost of preserving full sovereignty — primarily the hardware tier required to run local frontier models — is not justified for personal use. All three options assume server-on-Mac-Mini with cloud LLM access where useful.

Acronym key (used throughout):
- **LLM** — Large Language Model
- **API** — Application Programming Interface (HTTP surface)
- **MCP** — Model Context Protocol (Anthropic's open standard for AI clients to call tools)
- **STT** — Speech-to-Text
- **TCO** — Total Cost of Ownership

## The three options

### Option 1 — Continue the custom iOS app

Keep the existing native iOS app as Grove's primary surface. Continue adding features (ask UI, polish, future capabilities) on top of the V1 foundation that shipped 2026-05-15.

**What's already in place:**
- Native capture with Action Button + AppIntent voice dictation
- Auth via Keychain
- Upload queue with offline support
- SwiftData persistence
- Settings, appearance, basic browse

**What's still to build for a complete product:**
- Ask / query UI
- Memory browse / search
- Likely some form of long-content capture (paste from share sheet, etc.)
- Continued maintenance against iOS / Swift evolution

### Option 2 — Matrix / Element bridge

Stand up a self-hosted Matrix homeserver on the Mac Mini. Build a Matrix bot that listens for messages in a private room, routes them to Grove's server via natural-language intent routing, and replies in-channel. Element clients (iOS, macOS, watchOS, web) become the primary capture/query surface.

**What's involved:**
- Matrix homeserver (Conduit recommended for personal scale — single Rust binary, ~200 MB RAM)
- Custom Grove bot using `matrix-nio` Python library
- Local Whisper for voice notes received as Matrix audio attachments
- LLM-based intent router (cloud or local) for natural-language dispatch
- Element client configuration per device
- Optional Slack / Telegram bridge for additional input surfaces

### Option 3 — Shortcuts + Model Context Protocol (MCP) / HTTP to server

No iOS app at all. The Action Button on iPhone runs a Shortcut that captures voice via on-device dictation, posts to Grove's HTTP API, and reads back any response. A separate Shortcut handles ask queries. Browse / manage flows go through a lightweight web UI served by the Grove server. Optionally, expose Grove's API as an MCP server so Claude Desktop and other AI clients can call its tools directly.

**What's involved:**
- One Shortcut for "save" (voice → POST `/capture`)
- One Shortcut for "ask" (voice → POST `/ask` → speak result)
- Minimal web UI for memory browse / management
- Optional MCP server shim translating MCP tool calls to existing HTTP endpoints
- No iOS / Swift code at all; the existing iOS app is retired

The Grove server itself (FastAPI, Postgres, the hourly enrichment LaunchAgent, optional local Whisper) still runs on the Mac Mini under all three options — this option just doesn't add anything *new* on the server side beyond what Grove already requires.

## At-a-glance comparison

| Dimension | iOS app | Matrix bridge | Shortcuts + MCP/HTTP |
|---|---|---|---|
| **Remaining build effort** | ~40–80 hrs (ask UI + ongoing) | ~22–32 hrs (homeserver + bot + bridges) | ~10–15 hrs (Shortcuts + small web UI) |
| **Recurring cost** | $99/yr Apple Developer + cloud LLM | Cloud LLM only | Cloud LLM only |
| **Capture friction (one-handed, walking)** | ★★★★★ Best — Action Button + dictation in one tap | ★★★ Decent — open Element, hold to record | ★★★★★ Best — Action Button + dictation in one tap |
| **Cross-device support** | iOS only (without building Mac/Watch apps) | Excellent — Element on iOS, macOS, watchOS, web, Linux | Good — Shortcuts on iOS / macOS / watchOS; web for desktop browsers |
| **Voice support (server-side STT)** | Native iOS dictation (free, fast) | Voice notes as audio attachments → Whisper | Native iOS dictation (free, fast) |
| **Ask / query UX** | Native UI, single-turn (no conversation today) | Chat-style affordance, but multi-turn would still need server-side session support | Spoken response via Shortcut, or visit web UI |
| **Browse / search UX** | Native UI, swipeable lists, search bar | Search inside Matrix room (limited); supplement with web UI | Web UI only |
| **Maintenance burden** | High — iOS SDK churn, TestFlight resigns every 90 days, dependency updates | Medium — Conduit updates, bridge updates, occasional federation tweaks | Low — Shortcuts rarely break; server is the main thing to maintain |
| **Latency (server local)** | <100 ms perceived | ~200–500 ms (homeserver hop) | <100 ms perceived |
| **Future surface flexibility** | Low — each new platform = new app | High — add Slack / Discord / Telegram via bridges | High — any HTTP-capable client works; MCP unlocks Claude Desktop |
| **Vendor risk** | Apple developer policies + pricing | Matrix protocol evolution (low risk) | Apple Shortcuts API (very stable) |
| **Personal investment / learning value** | Swift + iOS ecosystem | Matrix protocol + self-hosting | Lighter — mostly Shortcuts and server work |

## Option 1 — Custom iOS app

### Pros

- **Best-in-class capture friction.** Action Button → AppIntent → dictation works without unlocking the phone, in under two seconds. No round-trip through any third-party service.
- **Native UI polish.** Full control over typography, animation, accessibility, dark mode, haptics. Capture review-before-save, live transcripts, custom waveforms — all possible.
- **Offline queue.** Existing SwiftData-backed upload queue handles network outages gracefully. The user can capture in the subway; the message uploads when connectivity returns.
- **Existing investment.** V1 already shipped. The hard parts (auth, upload queue, AppIntent wiring) are done.
- **Push notifications available** (with Apple Developer fee) if any future feature needs them.

### Cons

- **$99/yr Apple Developer Program forever.** Not a one-time cost; the app stops working if the membership lapses (certificates expire, TestFlight builds become unsignable).
- **TestFlight rebuild cadence.** Every 90 days you must re-upload a build to extend the expiry on installed copies. ~5 minutes of chore work per quarter.
- **iOS-only.** Capture from a Mac means switching to a different surface. Capture from a Watch means building a separate watchOS target.
- **High maintenance burden.** Swift evolution, iOS deprecations, Xcode upgrades, SwiftUI behavior changes, dependency updates, App Store Connect process.
- **Ongoing build effort.** Ask UI and other features still to build; each one is a Swift project of its own.
- **Single point of failure for capture.** If the app has a bug or the auth flow breaks, capture stops — no alternate path.

### When this option makes sense

If polished mobile capture is the highest-value feature of the entire product, and the user genuinely wants to invest in iOS development as a craft, the native app is best-in-class on that single axis. The $99/yr is a small line item if the result is "the best personal capture app on iOS."

## Option 2 — Matrix / Element bridge

### Pros

- **Cross-device for free.** Element clients exist for iOS, macOS, watchOS, Linux, Windows, web. One bot serves all of them.
- **No Apple Developer fee.** No signed iOS app means no $99/yr, no TestFlight cadence, no App Store policies.
- **Multi-input surfaces via bridges.** mautrix-slack, mautrix-telegram, mautrix-discord, mautrix-signal are all mature. Bridge your work Slack, your personal Telegram, etc. — all of them become capture inputs.
- **Natural-language interaction model.** Chat is the right metaphor for "I want to save this thought" and "what did I think about X." Element provides it for free.
- **Voice notes are first-class** in Element. Hold-to-record is a familiar gesture.
- **Searchable history per room.** Element's built-in search supplements Grove's own retrieval — you can find captures by scrolling.
- **Learning value.** Matrix is a credible open standard; self-hosting it builds useful general infra knowledge.

### Cons

- **Higher capture friction than Action Button.** Opening Element, navigating to the room, and holding to record takes 3–5 seconds longer than a Shortcut bound to the Action Button. For "in-the-moment" capture this gap matters.
- **Element is the UI, not Grove.** You don't control the look-and-feel of capture. Matrix-flavored chat aesthetic, not bespoke design.
- **Homeserver to maintain.** Conduit is low-effort but non-zero. Updates, occasional federation issues, key/secret rotation.
- **Bridge fragility.** Slack/Telegram bridges rely on third-party APIs that change. Periodic maintenance work.
- **Browse experience is limited.** Element's room search works for recent items; finding old captures via Grove-specific structure (tags, semantic search) requires a separate web UI.
- **Build effort upfront.** Homeserver + bot + intent router + bridge config is meaningful work before the system is usable.

### When this option makes sense

If multi-device input is important (you frequently want to capture from a Mac, a Linux box, a Watch, or from inside another chat app like Slack), Matrix is the cheapest path to universal capture coverage. The chat metaphor also suits people who already think conversationally about their notes.

## Option 3 — Shortcuts + MCP / HTTP

### Pros

- **Lowest ongoing cost.** No Apple Developer Program ($99/yr saved). No homeserver. The only recurring cost is cloud LLM usage.
- **Lowest build effort.** Two Shortcuts and a small web UI is roughly a weekend of focused work, vs. weeks of ongoing iOS development or homeserver + bot wiring.
- **Best capture friction tied with iOS app.** Action Button → Shortcut → dictation → POST is functionally identical in feel to the native AppIntent flow.
- **Lowest maintenance.** Shortcuts almost never break across iOS versions. The server is the only meaningful thing to keep working.
- **MCP unlock.** Exposing Grove as an MCP server lets Claude Desktop (and any future MCP-aware AI client) call Grove's tools natively. "Hey Claude, save this to Grove" works without Grove being a separate app.
- **Latency parity with native app.** Direct HTTPS, no intermediary hops.
- **CLI / scripting friendly.** The same HTTP API the Shortcuts use can be called by `curl`, by a future Mac menu-bar app, by anything that speaks HTTP.

### Cons

- **No native mobile UI.** Browse, search, and any rich interaction goes through the web UI — adequate on desktop, less great on phone unless the web UI is genuinely mobile-optimized (which is real work).
- **Capture is one-shot.** No review-before-save, no edit-the-transcript flow, no live waveform. The Shortcut fires and you trust the result. (Could be mitigated by a Shortcut that confirms the transcript before submitting, but that adds friction.)
- **No offline queue.** If the server is unreachable when the Action Button fires, the capture fails. The Shortcut could be made to retry, but it's not as robust as a SwiftData-backed queue.
- **Voice review feels different.** "Hear answer spoken aloud" is satisfying but harder to share or copy than text on screen. For ask flows you'd often want the result visible.
- **Web UI is the weakest surface.** It works, but it doesn't get the same polish budget as a native app would. Browsing 1000+ memories on a phone web view is genuinely worse than a native list.
- **No push notifications.** If a future feature ever wants to ping the user (Grove-side notifications are out of scope already, but if any hypothetical use case emerged), there's no path without an app.

### When this option makes sense

If Grove's value is primarily the **server-side intelligence** (semantic search, enrichment, ask quality) and the client is a thin pipe, this option matches that reality. It also makes sense if the user wants to minimize ongoing platform commitments and maintenance burden — focus engineering on the server, not on clients.

## The decision frame

The three options optimize for different things:

| If you most want… | Pick |
|---|---|
| Best-in-class mobile UX and you enjoy iOS development | **iOS app** |
| Universal multi-device capture with minimal client work | **Matrix bridge** |
| Lowest ongoing cost and maintenance, willing to live with a web UI for browse | **Shortcuts + MCP/HTTP** |

A few useful observations across the three:

1. **Capture friction on iPhone is a tie** between the iOS app and Shortcuts. The Action Button can drive either with equivalent UX. Matrix is meaningfully worse on this single axis.

2. **Cross-device capture is best in Matrix**, where every Element client is a capture surface. iOS-app and Shortcuts both require additional surfaces to be built (Mac app, Watch app) or the web UI to be the desktop entry point.

3. **Maintenance burden is highest with the iOS app** because of Apple's ecosystem cadence. Matrix is medium. Shortcuts is lowest.

4. **Build effort is highest for the iOS app** in the long tail (every new feature is Swift work). Matrix has a meaningful one-time cost but lower marginal cost per feature (bot logic in Python). Shortcuts has the lowest both up-front and marginal.

5. **All three can coexist.** Nothing prevents running the iOS app *and* exposing the same API to Shortcuts and Matrix bots. The question is whether the cost of maintaining all three exceeds the value of having multiple surfaces.

6. **Multi-turn / conversational Ask is not a current feature.** The existing iOS app's Ask flow is single-turn: each query is independent, with no session state carried between asks. A "Recent Queries" chip strip lets you re-run past queries but doesn't thread them. Adding multi-turn would be net-new work on whichever surface — and arguably easier in a web UI (chat-style is a well-trod web pattern) than in SwiftUI. This row in the comparison table should not be read as "the iOS app gives you conversation today and Shortcuts loses it."

## Hybrid possibilities worth considering

Two combinations stand out as not-purely-one-of-the-three:

### Hybrid A: Shortcuts (capture) + Web UI (browse) + MCP (Claude Desktop integration)

The "lightest possible" Grove. Capture via Action Button → Shortcut → server. Browse/manage via web. Ask via Claude Desktop pointed at Grove's MCP server, or via Shortcut for voice queries. No iOS app, and no additional server-side software beyond what Grove already needs (FastAPI + Postgres + enrichment LaunchAgent on the Mac Mini). The Mac Mini is still the single source of truth.

### Hybrid B: Shortcuts (mobile capture) + Matrix (desktop / multi-device) + web UI (browse)

Use Shortcuts for the speed-optimized mobile capture path, Matrix as the "everywhere else" capture surface (Mac, Watch via Element, Slack via bridge). Best of both: low-friction iPhone capture and universal multi-device coverage. Web UI for memory browse. No iOS app.

Hybrid B is probably the strongest all-around if cross-device capture is genuinely important. It costs slightly more in setup (homeserver + bot + Shortcuts) but pays off in surface coverage.

## Cost summary (TCO over 5 years)

Assumes base Mac Mini ($599) common across all three; cloud LLM spend roughly $5–10/month optimized.

| Option | Hardware | Apple Dev | Cloud LLM | 5-yr total |
|---|---|---|---|---|
| iOS app | $599 | $495 | $300–600 | $1,394–1,694 |
| Matrix bridge | $599 | $0 | $300–600 | $899–1,199 |
| Shortcuts + MCP/HTTP | $599 | $0 | $300–600 | $899–1,199 |

The $495 Apple Developer Program premium over 5 years is the main TCO differentiator. Whether it's worth it is a function of how much the native UI matters to the user.

## What's not in this comparison (and why)

- **Data sovereignty** — excluded by user instruction; the cost to preserve full local control is not justified for this personal-use case.
- **Specific LLM provider choice** — independent of surface; covered in the LLM-routing discussion separately.
- **Reminders / notifications** — out of scope (see `docs/archive/grove-reminders-spec.md`).
- **Voice-cloning / personalized TTS** — not a current feature consideration.

## Next steps after a decision

Whichever option lands:

1. File a tracking ticket / epic capturing the chosen surface architecture.
2. Update `docs/grove-prd.md` to reflect the chosen surface (if the chosen path differs materially from the existing PRD).
3. If retiring the iOS app, file a separate decommission ticket — the existing `ios/` directory and TestFlight build need explicit retirement steps.
4. If adopting Matrix, file an epic with at minimum: homeserver setup, bot implementation, Element client configuration, initial bridge (if any).
5. If adopting Shortcuts + MCP, file an epic with: capture Shortcut, ask Shortcut, web UI MVP, optional MCP server shim.
