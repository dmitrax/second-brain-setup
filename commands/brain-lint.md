# /brain-lint

Vault health check: find issues, decide what to do about them, update cross-project
connections.

## Scope
Default: current project only. Read CLAUDE.md in current directory → find line `Project:`
→ that is `$PROJECT`.
With argument `--all`: entire vault.

Vault: `~/Workspace/second-brain-vault/`

```bash
VAULT="$HOME/Workspace/second-brain-vault"
BRAIN="$HOME/.claude/skills/second-brain/lib/brain.sh"
```

**The mechanical checks are code, in `lib/brain.sh`. This file decides what to do with
what they find, and does not re-implement them.** They lived here as prose for four
versions, which meant every session wrote them again from scratch and got its own set of
false positives: measured 2026-08-04, one such re-implementation of the decision-reference
check produced 11 findings, all 11 false. A step whose output differs by who ran it gives
the delta below nothing to compare.

## Step 0: Sync the vault before auditing it

```bash
bash "$BRAIN" vault-sync "$VAULT"; rc=$?
```

- **0** → synced, or skipped on purpose (a local-only vault is supported). Proceed.
- **2** → remote unreachable. Say so in one line, and label the report as covering a
  possibly stale checkout — the findings are still worth having, the claim of
  completeness is not.
- **3** → rebase conflict, vault is mid-rebase. **Stop.** Fix nothing: this command edits
  what it finds, and edits on top of a half-finished rebase are unreviewable.

Unlike the other commands, `/brain-lint` needs this for **reading**, not only for its own
writes. Every verdict below is a claim about the whole vault; run on a checkout a week
behind, it reports a clean bill of health for a state that no longer exists, and does it
silently — the files are all there and read fine. A false green here is worse than a
missed finding, because it is trusted.

## Step 0c: Is this checkout complete?

A sync makes the checkout *current*. It does not make it *whole*.

```bash
sparse=$(git -C "$VAULT" config core.sparseCheckout 2>/dev/null)
hidden=$(git -C "$VAULT" ls-files -v | grep '^S' | sed 's/^S //')
if [ "$sparse" = "true" ] || [ -n "$hidden" ]; then
  roots=$(printf '%s\n' "$hidden" | sed 's|/.*||' | sort -u | tr '\n' ' ')
  echo "PARTIAL: $(printf '%s\n' "$hidden" | grep -c .) tracked files absent, under: $roots"
fi
```

If it reports PARTIAL, the run is still worth doing — but every claim of completeness in
it is false, so say so where it would be read as fact:

- Name the excluded paths in the report header and drop `--all`'s "entire vault" wording
  for "everything except <paths>".
- **The ambiguous-link finding becomes advisory.** Basename uniqueness is a property of
  the whole vault, so a sweep that cannot see part of it produces only a *lower* bound.
  Report it as "no duplicates among the visible files", never as "no ambiguous links".
- **Do not `--seal`.** The baseline lives in the vault and is shared across machines while
  what is visible is per-machine: sealing here drops every finding belonging to a hidden
  path, so the next run on the machine that *can* see it reports them as NEW while this
  run reported them as GONE — twice wrong, in opposite directions, nobody having fixed
  anything. Either carry those baseline lines forward verbatim or skip `--seal` and say why.

Measured 2026-08-04 on a machine excluding one directory: `obsidian unresolved` reported
93 broken links of which 91 pointed at files correct on the other machine, and three
baseline findings had gone GONE with nobody fixing them. A check cannot tell "absent" from
"not checked out" on its own — only this step can.

## Step 1: Run the checks

```bash
bash "$BRAIN" catalog "$VAULT"                                    # or --project "$PROJECT"
bash "$BRAIN" lint-collect "$VAULT" > /tmp/lint-findings.txt      # or --project "$PROJECT"
```

The catalogue runs **first and unconditionally**, and its output belongs in the report as
the audit's inventory: how many notes and decisions each project holds, how many decisions
are still in force, how many retired, and the newest date. Findings tell you what is
broken; this tells you what is *there*, which is the fact an audit is otherwise silent
about — and a lint that names its scope is a rule this package already carries.

Read two numbers off it before going further. A project whose **retired** count is high
relative to its decisions has churn worth a look; a project whose **newest** date is far
behind its own last session is the `stale-project` case seen from the other side. Neither
is a finding on its own — do not turn them into one, there is deliberately no threshold
here.

Why this call sits in a command rather than in prose: `catalog` shipped 2026-08-17 with no
call site at all, reachable only if a session happened to remember it. That is the third
failure mode this project keeps re-learning — the step exists, it is executable, and it
runs never. Checked by preflight 47.

One finding per line, `key<TAB>detail`. It **fails** rather than printing an empty result
when its input is empty — "found nothing" and "never looked" are different facts and only
one deserves a green. If it exits non-zero, report that and stop; do not fall back to
hand-written greps, which is exactly the habit that produced divergent results.

`--project P` scopes every check to that project — **except exactly two, both by
construction**, and they are named here so the exception stays a decision rather than an
oversight:

- `ambiguous-link` — a bare `[[link]]` breaks when *another* project reuses a basename,
  so a project-scoped view of it yields only a lower bound;
- `project-unregistered` / `registry-stale` — a registry-versus-filesystem disagreement
  is a vault-level fact with no owning project.

Everything else scopes. It did not until 2026-08-04: `--project nf-content` returned 16
findings of which 12 belonged to seven other projects, because the scope reached the
per-project loop and not the file sweeps. A report whose header does not match its body
teaches the reader to skim it. A `--project` matching nothing now fails rather than
returning quietly — otherwise a typo reads as a clean project.

What the keys mean and what each is worth:

| Key | What to do |
|---|---|
| `current-state:<project>` | `## Current state` over ~30 lines. Status and open blockers only — look for paragraphs restating a wiki note that already exists and collapse each to one line + `[[wikilink]]`. **Replaced the summed `prose-budget` on 2026-08-16:** that one added three sections, two of which already carry their own limits, so a project was penalised twice for one thing and the only unregulated section got whatever remained. It fired in 66 of 96 revisions on `goprofi-voronka` and 11 of 14 on `_arch/dimarch` — a warning that frequent stops being read. |
| `session-list:<project>` | More than ~5 entries in `Last session` / `Последняя сессия` (one section, matched under both spellings). Drop the oldest — but open each first and check it carries a `[[sessions/...]]` link to a file that exists, because that is what makes deletion safe. Counted in **entries**, not lines: the same five entries span 5 lines in one project and 26 in another. |
| `ffc-budget:<project>` | `## For future Claude` over ~20 lines. Same fix; this section has no template default anywhere, so it drifts furthest unnoticed. |
| `taskboard-done:<project>` | `brain.sh archive <taskboard> <archive-note> --before <YYYY-MM-DD> --apply` — moves dated Done entries into the archive note. Both flags are part of the call: without `--before` it exits 1, without `--apply` it is a dry run that exits 0 having moved nothing. Never retype entries by hand. The detail names how many of them are dated: when that number is far below the total, `archive` cannot clear the threshold and running it again will not help — the entries were closed without a date, and a top-level entry carries `YYYY-MM-DD` from the moment it is closed. When that number is 0 the advice to archive is unactionable, and `prose-budget` says so in place of it: recover the dates with `brain.sh backfill-dates <taskboard> --apply`, which gives each undated entry the date of the first commit showing it closed (dry-run by default; it refuses outside git and on entries it cannot tell apart). A closed sub-item is not an archivable entry and is not counted as one. |
| `taskboard-inprogress:<project>` | Counted in **open top-level items**, not lines — a board that requires each task to carry its measurement was reading 1148/300 with 64 genuinely open tasks, punishing the format instead of measuring the debt. `brain.sh sweep-closed` first: it moves closed top-level items out of In progress into Done, which is where the weight usually is. Then `archive` on what landed there, with both flags as above. If it still exceeds, the rest is genuinely open work — say so and leave it as a task rather than trimming live content. |
| `stale-project:<project>` | A session log exists that `_PROJECT.md` does not reflect — the save skipped Step 0b, or the file was edited by hand. Stamp it: `brain.sh stamp-field <_PROJECT.md> updated <the session's date>`, after checking the section text actually covers that session. **It no longer measures the calendar.** Until 2026-08-16 it fired at 14 days since `updated:`, which reports how recently the owner chose to work on a project, not whether anything is wrong: 7 findings on the live vault, all noise, every one of those projects having `updated:` exactly equal to its own last session. |
| `scope-note:not-active` | Not a finding — the list of projects whose freshness checks were skipped because `status:` is not `active` (`reference`, `paused`, `archived`). Read it as the coverage statement it is: if a project you expect to be watched appears here, its status is wrong. Content checks still apply to those projects; only staleness is exempt. |
| `stale-draft:<path>` | `status: draft` over 14 days → promote to stable or delete. |
| `map-stale:<project>` | Architecture map older than the last session that touched code. |
| `key-uniformity:<project>/<kind>` | A local frontmatter convention eroding. **Report, never auto-fill:** the key carries over, the value is a judgement per entry — a copied value is silently wrong, which is worse than a missing field. |
| `ambiguous-link:<path>` | Bare `[[name]]` where the basename is no longer unique. Replace with an explicit path. Never rewrite `sessions/` or `archive-*` — history stands. |
| `wiki-no-links:<project>` | Terminal notes: reachable, but reading them ends the trail. **The finding to act on.** |
| `wiki-no-backlink:<project>` | Missing the `[[../_PROJECT]]` backlink. A real violation, one line to fix — but fix it on the next edit of each note, not as one sweep of unrelated vault writes. |
| `wiki-no-sibling:<project>` | Only the backlink. **Advisory, never a defect on its own** — a note first on its topic has nothing honest to link to. Report the count; never add a link to clear the line. |
| `decision-schema/-ref/-legacy:<path>` | Off-schema `status:`, a reference to a note that does not exist, or the legacy one-line supersession form (invalid YAML — Obsidian drops that note from every property query). Fix on sight. |
| `frontmatter:<path>` | Unterminated frontmatter block. Fix it before anything else touches the file: `stamp-field` refuses such a file outright, and until 2026-08-19 it did not — it rewrote every body line beginning with the key instead. |
| `missing-updated:<project>` | `_PROJECT.md` carries no `updated:` field, so nothing can compare the record against the work. Stamp it with `brain.sh stamp-field <_PROJECT.md> updated <date>`. |
| `project-missing:<project>` | A directory that looks like a project has no `_PROJECT.md`. Either it is not a project (move it out of the vault root) or the manifest was never written. |
| `retelling-no-source:<project>` | A bullet of three or more lines carrying no `[[link]]` — an account with no owner elsewhere. Either the full version exists in a note and this should be one line plus a link, or it exists nowhere and needs a note. |
| `scope-note:lifecycle-docs` | Not a finding — the inventory of documents that have a state (briefs, audit requests, verification plans) with the state each carries. Verify each against the work, not against its age: a brief legitimately stays open for weeks, which is why there is no threshold here. A final one takes `closed: <date>` next to its status. |
| `project-unregistered:<project>` / `registry-stale:<entry>` | The registry `00-system/index.md` and the filesystem disagree. Both directions matter: a project no per-project check knows about, or an entry pointing at nothing. |

## Step 2: What only the Obsidian CLI can see

```bash
bash "$BRAIN" obsidian-available "$VAULT"   # exit 0 = GUI up AND this vault active
```

Use it as the condition of every CLI branch: `if bash "$BRAIN" obsidian-available "$VAULT";
then … else <skip> fi`. Non-zero → skip. Do not retry, do not wait longer, never call
`obsidian` outside the branch, and never diagnose the guard by splitting its conditions
into separate commands — they are chained on `&&` precisely so the CLI is not touched
until the cheap checks pass, and run apart the last one cold-starts the GUI.

```bash
obsidian orphans      # notes with no incoming [[wikilinks]]
obsidian unresolved   # links pointing at files that do not exist
obsidian deadends     # notes with no outgoing links at all
```

Read `orphans` against `wiki/` only — session logs are chronology and nothing is expected
to link to them. For `unresolved`, check where each name is referenced before calling it
broken: a link inside `sessions/` or `archive-*` naming a note renamed later is history,
not a defect.

Address files by `path=<project>/<name>.md`, never `file=<name>` — `file=` resolves by
name like a wikilink, takes the first shortest-path match vault-wide, and for mutating
commands writes there silently with exit 0. Never use `obsidian property:set` at all: it
re-serializes the whole frontmatter block, stripping quotes, expanding inline lists and
reinterpreting numeric-looking values. Edit frontmatter directly.

## Step 3: Contradictions

Not mechanical — this is the part that needs reading. Find notes in scope whose statements
contradict each other:

- the same fact stated differently in two notes;
- a decision note contradicting practice described in a synthesis note;
- `## For future Claude` older than 30 days while the status reads stable — verify.

Report and suggest a resolution. A decision note is never edited in place: supersede it
(`status: superseded` **plus** `superseded-by:`, two fields), or, when the decision still
holds and only one supporting fact was disproved, mark it `corrected-by:` and leave
`status` and body alone — `superseded` would falsely retire a rule still in force.

## Step 4: _PROJECT.md, taskboard, connections

- `_PROJECT.md`: is `Current state` actually current, is `Last session` / `Последняя сессия` one line
  per session, is `updated:` present? Sizes are already measured in Step 1 — here judge the
  *content* those numbers point at.
- taskboard: tasks in progress with no movement for 14+ days → move to stalled with a
  reason. Stalled for 30+ days → ask the user: still relevant?
- `00-system/connections.md`: add connections this run revealed with
  `brain.sh connections-add <file> <YYYY-MM-DD>` (entry on stdin — it puts the entry at
  the top of the knowledge-transfers section; never edit the file to append, that is how
  89 entries ended up under a heading dated weeks earlier). Drop the ones no longer true
  — **being wrong is what retires an entry, never being old**: there is no age window and
  no size threshold here on purpose, because these entries are techniques and a technique
  does not spoil with age. Update `## Last updated: [TODAY] lint`. Only if something
  actually changed — an unchanged file is a legitimate outcome, not a missed step.

## Step 5: Report the delta, not the backlog

**Re-collect first.** Steps 3-4 edit what they find, and the file from Step 1 is a snapshot
taken before any of that — diffing it reports findings this run has already fixed, and
`--seal` writes them back into the baseline, so the next run shows them GONE with nobody
having touched anything. A fabricated delta, produced by the run that did the work:

```bash
bash "$BRAIN" lint-collect "$VAULT" > /tmp/lint-findings.txt      # or --project "$PROJECT"
```

Then diff. **A scoped run must say so**, or the baseline pays for it — see below:

```bash
# whole vault (--all):
bash "$BRAIN" lint-diff "$VAULT/00-system/lint-baseline.txt" < /tmp/lint-findings.txt
# one project (the default scope):
bash "$BRAIN" lint-diff "$VAULT/00-system/lint-baseline.txt" --scope "$PROJECT" < /tmp/lint-findings.txt
```

**`--scope` is not optional on a project run.** The baseline is one file for the whole
vault; a scoped run without it reports every OTHER project's finding as GONE — which the
report calls "fixed, confirm it was deliberate" — and a `--seal` then erases them from a
file committed to the vault and read on every machine, after which the next full run calls
them NEW. With `--scope` the comparison and the seal touch only the keys belonging to that
project, out-of-scope baseline lines are carried through untouched, and any out-of-scope
finding the run does produce (two sweeps stay vault-wide by design) is listed separately as
reported-but-not-compared.

Report in this order: **NEW first** — this session's regression and the only part that
usually needs action; then GONE (something was fixed — confirm it was deliberate); then
the count of unchanged, which is parked debt and needs no re-litigation.

`--seal` rewrites the baseline, so pass it only on a run whose findings you have actually
reported to the user, and never from a partial checkout (Step 0c). A sealed baseline is
"known" for every future run — sealing a run nobody read is how a finding disappears
without ever being seen.

**A changed key set produces fake deltas, and they are recognisable.** Adding, renaming or
dropping a check shows up as a NEW and a GONE for what is one unchanged finding. The tell
is a GONE nobody remembers fixing, often paired with a suspiciously similar NEW. When the
set of checks changes, say so explicitly and re-seal deliberately — never let the reader
believe debt was cleared. Corollary: a finding that stops being *produced* is
indistinguishable from one that was *fixed*, so dropping a check silently retires every
finding it owned.

## Result

```
✓ Lint complete: $PROJECT
Coverage:              entire vault / everything except [paths] (partial checkout)

NEW since last lint:   [N] ← this session's regression, act on these
GONE since last lint:  [N] ← fixed; confirm it was deliberate
Known, unchanged:      [N] ← parked debt, listed in the baseline, do not re-litigate

Contradictions:        [M] (list — the part no script can find)
Broken links (CLI):    [N] (list) / n/a (Obsidian not running)
Connections.md:        updated / no changes

Recommendations:
[specific actions, NEW first]

Run /brain-save to persist any wiki changes made during lint.
```
The labels above are written in English here because this file is; **print them in the
vault's working language** (`brain.sh vault-language`), and leave every identifier —
finding keys, paths, section and command names — exactly as it is. See `SKILL.md`,
"Language of everything you say to the user".

