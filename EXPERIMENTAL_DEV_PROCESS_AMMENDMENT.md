# Experimental development process amendment

**Status:** Experimental, adopted 2026-05-14. The trial runs through the
Phase 4 classifier + writers tickets (#177–#180). After those merge, we
decide one of:

- **Keep** — fold the rule into `AGENTS.md` proper and delete this file.
- **Drop** — remove the `@EXPERIMENTAL_DEV_PROCESS_AMMENDMENT.md`
  reference from `AGENTS.md` and delete this file.
- **Iterate** — edit this file in place and extend the trial.

The reference in `AGENTS.md` is the switch — if this file is gone and
the reference is gone, the amendment is gone.

## Test-driven development for non-trivial implementation work

For tickets whose acceptance criteria can be expressed as
machine-checkable assertions, the implementer follows a red → green
cycle on the branch:

1. **Red commit.** Write the failing test(s) first, in their own
   commit. Push the branch. Confirm via CI (or local run, captured in
   the PR body) that the test fails for the *expected* reason — a
   wrong-failure-mode red is the same as no test.
2. **Green commit.** Implement until the test passes, in one or more
   separate commits grouped by concern per the project's commit
   conventions.
3. Hand off to Theo as usual.

The red commit MUST precede the green commit in the branch's history.
Theo verifies the ordering during review.

## When the rule applies

- Pure-logic features and refactors — parsers, classifiers, ranking
  changes, state machines, anything with a deterministic input → output
  contract.
- Bug fixes. This extends the existing `AGENTS.md` step-3 rule that
  bug fixes ship with a regression test; TDD just moves the test to
  the front.

## When the rule does not apply

- **UI / visual work** — SwiftUI layout, animations, look-and-feel
  polish.
- **Prompt engineering** — classifier prompts, synthesis prompts,
  intent-router prompts. Quality is judged manually via the untracked
  manual-test docs.
- **Schema-only migrations** without behaviour changes.
- **One-line typo fixes, dependency bumps, and docs.**
- **Glue / integration code** whose value is entirely in the wiring
  (Caddy config, systemd units, cron). Smoke tests still apply where
  reasonable, but a red→green ceremony is overkill.

When the judgment is ambiguous, the implementer notes the call in the
PR body — `TDD applied` or `TDD skipped because <reason>` — and Theo
confirms it during review.

## What Theo additionally checks

On top of the normal review categories, Theo verifies for TDD-eligible
tickets:

1. **Does the test pin the right invariant**, not just the
   implementation? A test that re-encodes the implementation passes
   green but catches nothing.
2. **Did the red commit actually precede the green commit?** A single
   "everything together" commit fails this check even if the tests pass.
3. **Is the test set complete enough for the change?** Assertion
   strength (prefer value equality over `is not None` / truthiness when
   a value comparison is possible), coverage of the obvious edge cases
   stated in or implied by the ticket's acceptance criteria, and at
   least one negative / failure path where the contract has one. The
   bar is still "would a future regression in this area be caught," not
   coverage percentage — but a one-assertion happy-path test on a
   classifier with five branches does not clear it. Several round-2
   reviews during the trial window have been "your red commit was too
   thin"; naming completeness as a separate concern keeps it from
   slipping between rules 1 and 2.

Failures on any of the three checks are must-fix in Theo's first-pass
review.

## Cost of the experiment

This amendment trades implementation-review time for test-review +
commit-ordering review time. If those extra checks turn into busywork
rather than catching real issues during the trial window, the
experiment has failed — drop it per the exit criteria above.
