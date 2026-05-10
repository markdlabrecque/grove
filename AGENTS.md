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
| `bug` / `feature` / `chore` / `docs` | Type. Pick one when filing. |
| `Needs triage` | Set by Theo on non-blocking findings discovered during review. The user dispositions these in weekly review. |
| `in progress` | Optional. Set by the implementing agent when picked up; cleared at merge. |

If a label doesn't exist yet, the agent that needs it creates it via
`gh label create`.

## The lifecycle

For every ticket that requires implementation work:

1. **Triage in the orchestrator session.** Confirm the ticket is
   well-formed. Pick the right specialist (Margot or Kai). Margot
   handles `server/`-only and ops-adjacent Python work; Kai handles
   `ios/`-only work. Cross-cutting tickets that touch both halves are
   split into two tickets and worked sequentially, server first by
   default so the iOS side can integrate against a real endpoint.

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
   - Commits in the project's conventional-commit style, ticket
     number leading: `#42 feat: add capture endpoint`. Group commits
     by concern.
   - Pushes the branch: `git push -u origin <branch>`.
   - Opens a PR into `develop`: `gh pr create --base develop`. The PR
     body includes `Closes #42` so GitHub auto-closes on merge.
   - Hands off to Theo and stops touching the branch.

4. **Theo reviews (round 1).**
   - Reads the diff against `develop` and the full files where
     context demands it.
   - Categorises findings:
     - **Must-fix** — correctness bugs, security issues, regressions,
       missing tests for new behaviour, broken doc references, plus
       *cheap drive-by improvements to files already in the diff*
       (rename a confusingly-named local, fix an obvious typo in a
       changed comment, etc.). These ride along — they don't get
       their own ticket.
     - **Non-blocking** — anything else: drive-by improvements that
       would expand scope, refactor opportunities, observations about
       adjacent code that wasn't touched. Theo files each as a new
       GitHub issue with the `Needs triage` label and a short
       description; he does not block merge on them.
   - Posts a review comment on the PR summarising findings. If
     there are no must-fix issues, skip to step 6.

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

The implementer never merges. Theo never edits code. The user can
intervene at any step.

## Concurrency

Agents work **in serial on a single working copy** — no worktrees, no
parallel branches. Whichever agent currently holds the ticket has
exclusive control over the repo state. The orchestrator enforces this
by not invoking another agent until the current one returns.

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
