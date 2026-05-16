# Working with the team

The Oracle is built by a small team of specialised Claude subagents
coordinated by an orchestrator session. You can invoke any agent by
name ("ask Margot to…", "have Theo review this"), or describe the work
and let the orchestrator route it.

## Repository shape

Single mono-repo. Backend (`server/`) and iOS client (`ios/`) live
side-by-side because the API contract is the interface between them
and most non-trivial tickets touch both. Splitting would force every
cross-cutting change into two coordinated PRs — not worth the cost at
this scale. Docs (`docs/`), ops (`ops/`), and team config
(`.claude/agents/`, `AGENTS.md`) live at the root.

## The team

| Agent | Role | When to invoke |
|---|---|---|
| **Margot** | Senior Python engineer | Tickets in `server/`: FastAPI, SQLAlchemy, Alembic, enrichment, embedding/LLM clients, pytest. |
| **Kai** | Senior iOS engineer | Tickets in `ios/`: SwiftUI, SwiftData, URLSession background, Speech, Action Button / Shortcuts, XCTest. |
| **Theo** | Code reviewer + merger | Every non-trivial ticket after the implementer finishes. Reviews, triages, and on approval merges to `develop` and closes the ticket. |

Definitions: `.claude/agents/{margot,kai,theo}.md` — committed so any
collaborator gets the same team.

## Tickets are the unit of work

**No work without a ticket.** GitHub Issues is the source of truth.
The orchestrator should refuse to delegate freeform work; instead,
file a ticket first, then delegate by ticket number.

A well-formed ticket has:

- A clear title.
- An "Acceptance criteria" section listing what done looks like.
- Any relevant context (links to PRD section, prior tickets, etc.).

If the request is vague, the orchestrator pushes back before opening
the ticket — vague tickets produce vague work.

### Required labels

| Label | Meaning |
|---|---|
| `bug` / `feature` / `chore` / `docs` | Type. Pick one when filing a normal ticket. |
| `regression` | Set by Theo on review findings where existing behaviour used to work and is now broken. Jumps the queue — dispatched as soon as it lands, not held for weekly review. |
| `enhancement` | Set by Theo on review findings that are drive-by improvements (never worked / could be tidier / refactor opportunity). Held in the backlog and dispositioned in weekly review. |
| `in progress` | Optional. Set by the implementing agent when picked up; cleared at merge. |

The `regression` vs `enhancement` split lives at file-time so the queue stays scannable as it grows. The judgment is "did this used to work?" — if yes, `regression`; if no, `enhancement`. When unsure, default to `enhancement` and flag the doubt in the issue body.

If a label doesn't exist yet, the agent that needs it creates it via
`gh label create`.

## PR scope

PRs should stay reasonably small — small enough that a reviewer can
load the diff into their head in one sitting and a tester can exercise
the change without juggling unrelated concerns. Two rules:

1. **Keep PRs small to make them easier to test and review.** Smaller
   diffs surface bugs earlier, keep CI signal focused, and make
   `git bisect` useful when something regresses later.
2. **Do not group related work in the interest of higher velocity.**
   It is tempting to fold a refactor, a bug fix, and a feature into one
   PR because they live in the same area. Don't. Each piece becomes
   harder to review, and a single bad change blocks the rest.

A ticket may produce **more than one PR** in service of these rules.
Split when the work naturally divides (e.g., a schema migration PR,
then a feature PR that uses the new column; or a server PR followed by
the iOS PR that consumes the new endpoint within the same ticket).
Interim PRs reference the ticket in their body as `Refs #N`. Only the
final PR that completes the ticket's acceptance criteria uses
`Closes #N` so GitHub auto-closes on merge.

## The lifecycle

For every ticket that requires implementation work:

1. **Triage in the orchestrator session.**
   - **Pre-flight check (required before touching any ticket).**
     Confirm the working copy is on `develop`, fast-forwarded to the
     latest merge (`git pull --ff-only origin develop`), and clean
     (`git status --short` is empty). If a previous ticket's PR is
     open, in CI, under review, or merged-by-Theo-but-not-yet-pulled
     locally, the previous ticket completes first — see the
     Concurrency section for the strict pipeline rule. The only
     exception is a dependency-resolution ticket whose sole purpose is
     to unblock a parked PR.
   - Confirm the ticket is well-formed. Pick the right specialist
     (Margot or Kai). Margot handles `server/`-only and ops-adjacent
     Python work; Kai handles `ios/`-only work. Cross-cutting tickets
     that touch both halves are split into two tickets and worked
     sequentially, server first by default so the iOS side can
     integrate against a real endpoint.

2. **Specialist picks up the ticket.**
   - Reads the issue: `gh issue view <N>`.
   - Reads `docs/the-oracle-prd.md` and
     `docs/the-oracle-implementation-plan.md` if not already in
     context. The PRD constrains intent; the plan constrains stack.
   - Branches off `develop`: `git checkout develop && git pull && git
     checkout -b <N>-<short-slug>` (e.g. `42-capture-endpoint`).
   - Sets the `in progress` label and assigns themselves on the
     issue.

3. **Implements to completion on the branch.**
   - Code, tests, and **any documentation that goes stale because of
     this change** (RUNBOOK, implementation plan, inline docs). Doc
     drift is a must-fix issue if Theo catches it later, so handle it
     up front.
   - **Red → green ordering (TDD).** For any ticket whose acceptance
     criteria can be expressed as machine-checkable assertions, the
     failing test(s) land in their **own commit** before the
     implementation commit(s). Push the red commit, confirm it fails
     for the *expected* reason (a wrong-failure-mode red is the same
     as no test), then commit and push the green. The red commit MUST
     precede the green commit in the branch history; Theo verifies the
     ordering during review.
     - **Applies to:** pure-logic features and refactors (parsers,
       classifiers, ranking changes, state machines, anything with a
       deterministic input → output contract) and all bug fixes (this
       extends the existing regression-test-for-every-fix rule by
       moving the test to the front).
     - **Does not apply to:** UI / visual work (SwiftUI layout,
       animations, look-and-feel polish); prompt engineering
       (classifier / synthesis / intent-router prompts — quality is
       judged manually via untracked manual-test docs); schema-only
       migrations without behaviour changes; one-line typo fixes,
       dependency bumps, and docs; glue / integration code whose
       value is entirely in the wiring (Caddy, systemd, cron) — smoke
       tests still apply where reasonable, but a red→green ceremony
       is overkill.
     - When the judgment is ambiguous, the implementer notes the call
       in the PR body — `TDD applied` or `TDD skipped because <reason>`
       — and Theo confirms it during review.
   - **Test quality bar.** Tests should match the cost of the change —
     a one-line bug fix earns one focused regression test, not a
     suite. The bar is "would a future regression in this area be
     caught," not coverage percentage. Within that frame:
     - Bug fixes include a regression test that fails on the pre-fix
       code (revert the production change locally and confirm red
       before claiming green).
     - Before claiming any new test passes, confirm it fails when the
       production change is reverted. Honour-system but worth naming.
     - Tests must be deterministic — no wall-clock `sleep` /
       `Task.sleep` / `DispatchQueue.asyncAfter` for synchronisation.
       Use continuations, expectations, or injected clocks. Sleeps
       are allowed only to simulate real user wait time, never to
       wait for an async operation to finish.
     - Shared test fixtures (URL protocols, factories, stubs) live in
       one place — don't duplicate across test targets.
     - **Completeness is reviewed.** Theo checks the test set against
       the ticket's acceptance criteria for assertion strength (prefer
       value equality over `is not None` / truthiness when possible),
       coverage of the obvious edge cases, and at least one negative /
       failure path where the contract has one. Aim for that bar at
       handoff rather than discovering it in round 2.
   - Commits in the project's conventional-commit style, ticket
     number leading: `#42 feat: add capture endpoint`. Group commits
     by concern.
   - **iOS pre-push gate (Kai only).** Before pushing any iOS PR, run
     `make ios-test` from the repo root. This runs three steps in
     sequence: `ios-test-core` (SPM path), `ios-lint-pbxproj` (wiring
     check), and `ios-test-app` (xcodebuild). The `ios-lint-pbxproj`
     step fails fast if a new `*Tests.swift` file under `GroveTests/`
     is not referenced in `project.pbxproj` — fix by opening
     `Grove.xcodeproj` in Xcode, selecting the file, and ticking the
     GroveTests checkbox under Target Membership.
   - **Pushes the branch and verifies the push landed.** Run
     `git push -u origin <branch>` (or `git push --force-with-lease`
     after a rebase) and **read the full output** — do not pipe through
     `tail`, `head`, or otherwise truncate it, since a failure line
     can sit anywhere in the output. If the result is ambiguous, run
     `git ls-remote origin <branch>` and confirm the SHA matches local
     `HEAD`. The remote tip must equal the implementer's last commit
     before the handoff is safe. This rule exists because an
     unverified push was a likely cause of the #131 squash-loss
     regression.
   - Opens a PR into `develop`: `gh pr create --base develop`. Per
     the PR scope section above, a ticket may produce more than one
     PR. The PR body uses `Closes #42` only when this PR completes the
     ticket's acceptance criteria; interim PRs use `Refs #42` so the
     ticket stays open until the final PR merges.
   - Hands off to Theo and stops touching the branch.

4. **Theo reviews (round 1).**
   - Reads the diff against `develop` and the full files where
     context demands it.
   - Categorises findings:
     - **Must-fix** — correctness bugs, security issues, regressions,
       missing tests for new behaviour, missing regression tests on
       bug fixes, **incomplete test sets** (weak assertions, missing
       edge cases from the acceptance criteria, no negative path where
       the contract has one — completeness is its own named concern,
       not folded into "missing tests"), **red commit out of order on
       a TDD-eligible ticket** (the failing test must precede the
       implementation in branch history; a single "everything together"
       commit fails this check even if the tests pass), **tests that
       re-encode the implementation rather than pinning the
       invariant** (passes green but catches nothing), tests that use
       `sleep` / `Task.sleep` / `DispatchQueue.asyncAfter` as
       synchronisation primitives, duplicated test fixtures that should
       be unified, broken doc references, plus
       *cheap drive-by improvements to files already in the diff*
       (rename a confusingly-named local, fix an obvious typo in a
       changed comment, etc.). These ride along — they don't get
       their own ticket.
     - **Non-blocking** — anything else: drive-by improvements that
       would expand scope, refactor opportunities, observations about
       adjacent code that wasn't touched. Theo files each as a new
       GitHub issue with a short description and either `regression`
       (used to work, now broken — jumps the queue) or `enhancement`
       (never worked / could be tidier — backlog). Default to
       `enhancement` when unsure. Theo does not block merge on either.
   - Posts a review comment on the PR summarising findings. If
     there are no must-fix issues, skip to step 6.
   - **Informational metadata (not a gate).** CI posts a comment on
     every PR with line coverage (per target) and the top-5 functions
     by cyclomatic complexity, flagged ★ if the PR touched their
     file. These numbers are surfaced for trend visibility; Theo does
     not block merge on them. A coverage regression or a function
     creeping high on the worst-list is a normal candidate for a
     non-blocking follow-up issue under step 4 above.

5. **Implementer addresses must-fix issues.** Same agent as step 3.
   New commits on the same branch. When done, hand back to Theo.

6. **Theo's final pass.**
   - Re-reviews the latest diff.
   - Runs the relevant test suite locally to confirm green
     (`make test` for server work; `xcodebuild test` for iOS once
     scaffolded).
   - **Confirms CI is green on the head commit.** `gh pr checks <PR>`
     must report every required check (`Lint`, `Test`, `Migrations`
     for server PRs) as `pass` on the latest SHA. If any check is
     failing, pending, or stale, do not merge — comment on the PR
     and hand back to the implementer. Local-green is not a substitute
     for CI-green; both gate the merge.
   - **Merges.** `gh pr merge --squash --delete-branch <PR>`. Squash
     because one ticket = one commit on `develop`. The squash commit
     subject is `#<N> <type>: <title>` matching the project's commit
     conventions.
   - The merge action pushes to `origin/develop` automatically.
   - Adds a completion comment on the issue summarising what shipped
     and any follow-up tickets he filed during review. (GitHub
     auto-closes the issue from `Closes #<N>` in the PR body.)
   - Removes the `in progress` label if it was set.
   - **Resets the working copy to a clean `develop`:** `git checkout
     develop && git pull --ff-only origin develop`. The
     `--delete-branch` flag on the merge removes the remote branch but
     the local feature branch lingers, and all agents share one working
     copy. The next agent should inherit a workspace already on
     `develop` with the latest merge pulled.

The implementer never merges. Theo never edits code. The user can
intervene at any step.

## Concurrency

Agents work **in serial on a single working copy** — no worktrees, no
parallel branches.

The serial discipline applies to two things, not just one:

1. **Working-copy access.** Whichever agent currently holds the ticket
   has exclusive control over the repo state. The orchestrator enforces
   this by not invoking another agent until the current one returns.

2. **Ticket pipeline.** A ticket is *in flight* from `git checkout -b`
   through Theo's merge commit on `develop` and the post-merge reset to
   a clean working copy. The orchestrator must not dispatch a new
   ticket — to any agent, in any background, foreground or otherwise —
   while another ticket is in flight. The pipeline is strict:

   `implement → push (verified) → PR → CI → review → merge → reset to clean develop → next ticket`

   This rule exists because skipping it once already cost the team a
   regression: a fix commit was lost in a squash merge (see #131 — the
   originating ticket whose squash dropped the fix), which then took
   follow-up tickets #135 and #137 to clean up.

**Dependency-resolution exception.** A ticket whose sole purpose is to
unblock a parked PR (e.g., #137 unblocking #136) is *not* parallel
work — it is the next step in a strictly sequential dependency chain.
Pick it up as the new "current ticket," let the original PR sit, and
return to the original PR only after the unblocker has merged and the
working copy is back on a clean `develop`.

## Branch and commit conventions

- Default branch: **`develop`**. `main` is reserved for tagged
  releases (eventual; not used in V1).
- Branch names: `<issue-number>-<short-slug>`, all lower-case, hyphen
  separated. e.g. `42-capture-endpoint`, `47-fix-sync-retry`.
- Commits use conventional-commit prefixes (`feat:`, `fix:`, `chore:`,
  `docs:`, `refactor:`, `test:`).
- Commit subjects lead with the ticket number:
  `#42 feat: add capture endpoint`. GitHub auto-links the reference.
- Group commits by concern. One concept per commit.
- Squash-merge into `develop`. The squash subject mirrors a single
  conventional commit so `develop` history reads as a clean ledger of
  tickets.
- Never use a `Co-Authored-By: Claude` trailer.
- Never bypass commit hooks (`--no-verify`).
- Never force-push to `develop` or `main`.

## When *not* to delegate

- One-line typo fixes, doc tweaks, dependency bumps with no test
  surface — orchestrator handles these directly. Still file a ticket
  if the change is non-obvious; skip the ticket only for trivial,
  self-evident edits.
- Repo-shape changes (top-level layout, `.gitignore`, `.editorconfig`,
  `Makefile`, `docker-compose.yml`, `.claude/`, `AGENTS.md`) —
  orchestrator owns these because they aren't squarely in any
  specialist's lane.
- Cross-cutting work that genuinely needs both halves changed in
  lockstep — split into two tickets and serialise (server first, iOS
  second) rather than letting one agent reach across the boundary.
