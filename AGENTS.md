# Working with the team

Grove is built by a small team of specialised Claude subagents coordinated
by an orchestrator session. The roster is **role-based**: one implementer
covers the whole codebase, with dedicated test, review, and reporting roles
around it. You invoke any agent by role ("have the reviewer look at this")
or describe the work and let the orchestrator route it.

## Repository shape

Single mono-repo. Backend (`server/`) and iOS client (`ios/`) live
side-by-side because the API contract is the interface between them and most
non-trivial tickets touch both. Splitting would force every cross-cutting
change into two coordinated PRs — not worth the cost at this scale. Docs
(`docs/`), ops (`ops/`), and team config (`.claude/agents/`, `AGENTS.md`)
live at the root.

## The team

| Role | Model | Effort | Access | When it runs |
|---|---|---|---|---|
| **Implementer** | Sonnet 5 (→ Opus 4.8 for the hard ~20%) | high | mutation | Writes production code + proving tests for a ticket, and applies review fixes. Language-agnostic: `server/` Python and `ios/` Swift. |
| **Test Writer** | Sonnet 5 | low | mutation (test files only) | Hardens the implementation with edge cases and negative paths after it lands. Never edits production code. |
| **Reviewer** | Opus 4.8 | high | read-only | Inspects the diff for regressions, security, contracts, concurrency, and test quality. Returns structured findings. Never edits, never merges. |
| **Reporter** | Haiku 4.5 | medium | read-only + `gh` | Records the system-of-record ledger entry on the ticket when the work lands. |

Definitions live in `.claude/agents/{implementer,test-writer,reviewer,reporter}.md`
— committed so any collaborator gets the same team. The Implementer defaults
to Sonnet 5; the orchestrator escalates it to Opus 4.8 (via the dispatch-time
`model` override) for complex, high-risk, or design-heavy tickets.

**Planning is a foreground pre-flight**, not a workflow role. Before
dispatching, the orchestrator (or the built-in Plan agent) produces and
approves the scope + acceptance criteria on **Opus 4.8**. Workflow roles
execute an approved plan; they do not re-plan it.

**Merging is an orchestrator action.** No workflow role merges — the
Reviewer approves, and the orchestrator performs the squash-merge.

## Tickets are the unit of work

**No work without a ticket.** GitHub Issues is the source of truth. The
orchestrator refuses to delegate freeform work; file a ticket first, then
delegate by ticket number.

A well-formed ticket has a clear title, an "Acceptance criteria" section
listing what done looks like, and any relevant context (links to PRD
section, prior tickets). If the request is vague, the orchestrator pushes
back before opening the ticket — vague tickets produce vague work.

### Required labels

| Label | Meaning |
|---|---|
| `bug` / `feature` / `chore` / `docs` | Type. Pick one when filing a normal ticket. |
| `regression` | A review finding where existing behaviour used to work and is now broken. Jumps the queue — dispatched as soon as it lands. |
| `enhancement` | A review finding that is a drive-by improvement (never worked / could be tidier). Held in the backlog for weekly review. |
| `in progress` | Optional. Set by the Implementer when picked up; cleared at merge. |

The `regression` vs `enhancement` split lives at file-time. The judgment is
"did this used to work?" — if yes `regression`, if no `enhancement`. Default
to `enhancement` when unsure and flag the doubt in the issue body. Create a
missing label via `gh label create`.

## PR scope

PRs stay small enough that a reviewer can load the diff in one sitting and a
tester can exercise it without juggling unrelated concerns.

1. **Keep PRs small** — smaller diffs surface bugs earlier, keep CI focused,
   and make `git bisect` useful later.
2. **Do not group related work for velocity** — folding a refactor + a fix +
   a feature into one PR because they share an area makes each harder to
   review and lets one bad change block the rest.

A ticket may produce **more than one PR**. Interim PRs reference the ticket
as `Refs #N`; only the final PR that completes the acceptance criteria uses
`Closes #N`.

## The lifecycle

Planning happens first, in the foreground, on Opus 4.8: the orchestrator
produces and approves the scope + acceptance criteria before any dispatch.
Then, for every ticket that requires implementation work:

1. **Triage (orchestrator).**
   - **Pre-flight:** confirm the working copy is on `develop`,
     fast-forwarded (`git pull --ff-only origin develop`), and clean
     (`git status --short` shows only known untracked paths).
   - Confirm the ticket is well-formed and its acceptance criteria are
     explicit. Decide whether it's routine (Implementer on Sonnet 5) or
     complex (escalate to Opus 4.8).

2. **Implementing (Implementer).**
   - Reads the issue (`gh issue view <N>`), and `docs/grove-prd.md` +
     `docs/grove-implementation-plan.md` if not already in context (PRD
     constrains intent, plan constrains stack).
   - Branches off `develop`: `git checkout develop && git pull && git
     checkout -b <N>-<short-slug>`. Sets `in progress` and self-assigns.
   - Implements the approved scope: production code, the tests needed to
     prove it works, and **any docs that go stale** (`docs/grove-implementation-plan.md`,
     `ops/RUNBOOK.md`, inline docs). Doc drift is a must-fix in review —
     handle it up front.
   - Commits conventional-commit style, ticket number leading
     (`#42 feat: add capture endpoint`), grouped by concern.
   - **Runs tests + lint/format locally, green before pushing — a hard gate.**
     Server: `make test`; `ruff format .` + `ruff check --fix .`. iOS:
     `make ios-test`. **Run test commands in the FOREGROUND** (`Bash` with
     `run_in_background: false`); **never Monitor a background test process**
     — a silent crash leaves Monitor watching forever and hangs the turn.
   - **Verified push:** `git push -u origin <branch>` and read the FULL
     output (no `tail`/`head`). If ambiguous, `git ls-remote origin
     <branch>` and confirm the remote SHA equals local HEAD before handoff.
     An unverified push was a likely cause of the #131 squash-loss.
   - Opens a PR into `develop` (`Closes #N` on the final PR). Hands off.

3. **Testing (Test Writer).**
   - Inspects the implementation and adds focused, behaviour-pinning tests
     and the edge/negative cases the happy-path work missed. Owns only test
     files it creates or first changes; does not touch production code.
     Implementation defects found here are reported back to the orchestrator
     for the Implementer, not fixed in place.
   - Same local-green + foreground-test + verified-push gates as above.
   - For a small or self-evidently-covered ticket the orchestrator may skip
     this stage; note the skip on the PR.

4. **Reviewing (Reviewer).**
   - Reads the diff and full files where context demands, runs non-mutating
     checks, and confirms **CI is green on the head SHA** (`gh pr checks <PR>`).
   - Returns structured JSON findings, each in one category: `must_fix`,
     `quick_fix` (≤5 min), `follow_up` (a new ticket — mark `regression` or
     `enhancement`), `advisory`, or `approved`. Cheap drive-by fixes to files
     already in the diff ride along as `must_fix`/`quick_fix`; anything that
     would expand scope becomes a `follow_up` ticket. Emits `approved` only
     when no blocking finding remains.
   - Runs in parallel with the CI watcher. Never edits code; when a fix is
     obvious it writes the diff into the finding for the Implementer.

5. **Fixing (Implementer).** If the Reviewer returns `must_fix`/`quick_fix`,
   the Implementer addresses them on the same branch with new commits (no
   rebase/force-push) and hands back for a round-2 review. Unresolved review
   cycles block the ticket after 3 rounds by default.

6. **Merge (orchestrator).** On `approved` + green CI:
   - `gh pr merge <PR> --squash --delete-branch --subject "#<N> <type>: <title>"
     --body "<clean one-line summary>"`.
     Always pass `--subject` — branches carry multiple commits and the
     default drifts to the last one. `<type>` is derived from the ticket
     (a functionality ticket squashes `feat:` even if its last commit was
     `test:`/`fix:`).
   - **Always pass an explicit clean `--body`.** The harness auto-appends
     `Co-Authored-By: Claude` / `Claude-Session:` trailers to agent commits;
     `gh`'s default squash body is the concatenated branch commit messages,
     so relying on it leaks those forbidden trailers onto `develop` (this
     happened on #524 and #520). A short authored `--body` keeps `develop`
     clean regardless of what the branch commits contain.
   - Reset to a clean `develop`: `git checkout develop && git pull --ff-only
     origin develop`.

7. **Reporting (Reporter).** Posts a concise ledger comment on the ticket:
   work completed, important findings, and follow-ups (especially Reviewer
   `follow_up` items) — explicitly stating when there are none. Files the
   `follow_up` tickets the Reviewer flagged.

The Implementer and Test Writer never merge. The Reviewer never edits code.
The orchestrator merges. The user can intervene at any step.

## Concurrency

Default is **serial**: one ticket in flight at a time on the shared working
copy, from `git checkout -b` through the orchestrator's merge and the
post-merge reset. This is the safe default and needs no worktrees.

**Parallel dispatch** is allowed when tickets are independent, with two
rules:

1. **Worktree isolation is mandatory for parallel implementers.** Every
   parallel Implementer dispatch uses `isolation: "worktree"` so no two
   agents share the orchestrator's working copy. Brief with **repo-relative
   paths only** (`server/grove/api/captures.py`) — absolute paths under
   `/Users/mark/Projects/grove/...` send the agent back to the main checkout
   and defeat isolation. *(Known failure mode: stale `worktree-agent-*`
   branches based on the repo's root commit can poison a new worktree —
   prune them if a worktree comes up on the wrong base.)*
2. **Merges to `develop` stay strictly one-at-a-time**, squash only. Confirm
   the first landed and the second is rebased on the new tip before the
   second merge — otherwise a squash can drop commits (#131).

## Branch and commit conventions

- Default branch: **`develop`**. `main` is reserved for tagged releases.
- Branch names: `<issue-number>-<short-slug>`, lower-case, hyphen-separated.
- Conventional-commit prefixes (`feat:`/`fix:`/`chore:`/`docs:`/`refactor:`/`test:`),
  ticket number leading: `#42 feat: add capture endpoint`.
- One concept per commit. Squash-merge into `develop` so history reads as a
  clean ledger of tickets.
- Never use a `Co-Authored-By: Claude` or `Claude-Session:` trailer. The
  harness adds these automatically; strip them from commit messages, and the
  orchestrator's clean `--body` at squash-merge is the backstop that keeps
  them off `develop` (see the merge step above). Never bypass hooks
  (`--no-verify`). Never force-push to `develop` or `main`.

## When *not* to delegate

- One-line typo fixes, doc tweaks, dependency bumps with no test surface —
  orchestrator handles directly. File a ticket if non-obvious; skip it only
  for trivial, self-evident edits.
- **Repo-shape / team-config changes** (top-level layout, `.gitignore`,
  `Makefile`, `docker-compose.yml`, `.claude/`, `AGENTS.md`) — orchestrator
  owns these; they aren't in any role's lane. Doc-only changes open a PR,
  wait for green CI, and the orchestrator merges without a review round.
- Cross-cutting work that needs both halves changed in lockstep — split into
  two tickets and serialise (server first) rather than reaching across the
  boundary in one dispatch.
