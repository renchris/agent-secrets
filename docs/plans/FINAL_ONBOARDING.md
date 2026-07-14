# Final Release — Complete Onboarding (v0.1.1)

## Phase 0 — Orchestration: SINGLE LEAD (Agent Teams deliberately NOT used)

**Decision: single-agent, sequential — NOT Agent Teams.** This is the correct call per
`~/.claude/rules/agent-teams.md`'s own decision rule ("domains that require all agents to share the
same context … are not a good fit for multi-agent systems; coding tasks are named a poor fit").

Evidence: the change set is **tightly coupled on a few shared files** — `cmd/setup.sh` receives 6
edits, `cmd/doctor.sh` 4, `lib/common.sh` 2, `lib/help.sh` 3. Parallel teammates in worktrees would
all mutate the same files → guaranteed same-hunk conflicts, forcing sequential cherry-pick anyway,
with each teammate needing the same deep context on this security-sensitive store. A single lead
holding full context is both **safer** (names-only invariant, reversible-manifest correctness) and
**faster** here than fan-out + reconcile. Research/read phase is already complete (done inline).

**Actuation:** lead implements file-by-file in the dependency order below, running `bats tests/` +
`shellcheck` after each cohesive change; commits atomically per feedback item.

---

**Scope (frozen):** Implement the net-positive subset of `ONE_COMMAND_INSTALL_FEEDBACK_FINAL.md`
(P0-1…P1-5 + P2 doc items) using engineering judgment — declining fragile/low-value parts — plus
tightly-related DRY/correctness improvements, to reach a true one-command onboarding UX. Every change
reversible, names-only, fully tested (bats green + shellcheck clean). No new CLI verbs, no vendored
gh/az (P2 says document-not-bundle).

## Judgment calls (implement vs decline — the "only if net-positive" gate)

| Item | Decision | Rationale |
|------|----------|-----------|
| P0-1 `docs/POST_INSTALL.md` gh/az/anthropic recipes | **DO** | Pure docs; solves real brew-less pain |
| P0-1 doctor `onboarding` category | **DECLINE** | Permanent gh/az "absent" attn = the exact noise P1-2 fixes; gh/az are optional |
| P0-1 `help onboarding` topic | **DO** | In-terminal pointer; no dispatcher edit (help.sh branch) |
| P0-1 Next-steps pointer (done screen + install deferral) | **DO** | Cheap, surfaces POST_INSTALL at the right moment |
| P0-2 pbcopy Cursor rules at setup end | **DO** | Real convenience; pbcopy mocked; guarded |
| P0-2 README "who reads what" table | **DO** | Removes the exact ambiguity the user hit |
| P0-2 Cursor state-DB file write | **DECLINE** | No stable/documented global path; SQLite write is fragile + not cleanly reversible. Feedback itself hedges "if unstable, do not write files" |
| P0-2 doctor "cursor user rules" row | **DECLINE** | Unverifiable → permanently "unknown" = noise, no signal |
| P0-3 store_add empty-stdin error hint | **DO** | Directly addresses the `$YOUR_REAL_…` confusion |
| P0-3 doctor placeholder detection | **DO** (in doctor, not just done screen) | Fixes false-healthy apiKeyHelper; mirrors canary pattern; durable catch |
| P0-3 done-screen placeholder nudge | **DECLINE** | Interactive setup never stores a placeholder; doctor covers the durable case |
| P0-3 doc examples (interactive primary) | **DO** | Root-cause fix for copy-paste-as-var |
| P0-4 keychain populate after ceremony | **DO** (unify flow) | Real Sequoia pain; DRY the ceremony + `--keychain` into one verified helper |
| P1-1 preflight ladder | **DO** | Core stance; a few ui_say lines |
| P1-2 `doctor --summary` + row tiers | **DO** | The "feels broken" fix; target ≤3 attn |
| P1-3 cleanupPeriodDays on create | **DO** (two-marker reversible) | Only when WE create settings.json; record 2 edit markers so rollback stays total |
| P1-4 canary "(optional)" detail | **DO** | Honest, reduces alarm |
| P1-4 done-screen canary line | **DECLINE** | Redundant — `_arm_canary` + doctor already cover it |
| P1-5 backup gh dependency hint | **DO** | doctor backup row + backup.sh gh-missing message |
| P2 `print-discovery` verb | **DECLINE** | New CLI surface (breaks 11-cmd test, needs dispatcher edit); centralize in lib fn instead |
| P2 Copilot per-repo doc | **DO** | One README line |
| Extra: de-magic placeholder constant → common.sh | **DO** | Removes a magic string shared by setup+doctor |
| Extra: centralize agent-rules → `agsec_agent_rules()` | **DO** | DRY the done-screen rules + clipboard source |

## Implementation order (dependency-aware)
1. `lib/common.sh` — `AGENT_SECRETS_UNATTENDED_PLACEHOLDER` const + `agsec_agent_rules()`
2. `lib/store.sh` — store_add empty error hint
3. `cmd/doctor.sh` — `--summary` + tiers; placeholder check; canary "(optional)"; backup gh hint
4. `cmd/setup.sh` — const use; preflight ladder; unified `_kc_populate`; cleanupPeriodDays; step-6 --summary; done-screen clipboard + next-steps
5. `lib/help.sh` — `onboarding` topic; doctor `--summary` flag; add examples
6. `cmd/backup.sh` — gh-missing message
7. `docs/POST_INSTALL.md` — new
8. `README.md` — who-reads-what table + Copilot note
9. `AGENTS.md` — interactive add primary
10. `install.sh` — POST_INSTALL pointer in deferral
11. Tests — `tests/onboarding.bats` + doctor/flows/help updates

## Gate: `bats tests/` green + `shellcheck bin/* cmd/*.sh lib/*.sh install.sh` clean.
