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
bash "$BRAIN" lint-collect "$VAULT" > /tmp/lint-findings.txt      # or --project "$PROJECT"
```

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
| `prose-budget:<project>` | `_PROJECT.md` prose over ~60 lines. Look for paragraphs restating a wiki note that already exists — collapse to one line + `[[wikilink]]`. Never fold link-list sections into this: they grow legitimately with a project's decision count. |
| `ffc-budget:<project>` | `## For future Claude` over ~20 lines. Same fix; this section has no template default anywhere, so it drifts furthest unnoticed. |
| `taskboard-done:<project>` | `brain.sh archive` — moves dated Done entries into the archive note. Never retype entries by hand. |
| `taskboard-inprogress/-size:<project>` | `brain.sh sweep-closed` first: it moves closed top-level items out of In progress into Done, which is where the weight usually is. Then `archive` on what landed there. If it still exceeds, the rest is genuinely open work — say so and leave it as a task rather than trimming live content. |
| `stale-project:<project>` | Ask: still active, on pause, or close? |
| `stale-draft:<path>` | `status: draft` over 14 days → promote to stable or delete. |
| `map-stale:<project>` | Architecture map older than the last session that touched code. |
| `key-uniformity:<project>/<kind>` | A local frontmatter convention eroding. **Report, never auto-fill:** the key carries over, the value is a judgement per entry — a copied value is silently wrong, which is worse than a missing field. |
| `ambiguous-link:<path>` | Bare `[[name]]` where the basename is no longer unique. Replace with an explicit path. Never rewrite `sessions/` or `archive-*` — history stands. |
| `wiki-no-links:<project>` | Terminal notes: reachable, but reading them ends the trail. **The finding to act on.** |
| `wiki-no-backlink:<project>` | Missing the `[[../_PROJECT]]` backlink. A real violation, one line to fix — but fix it on the next edit of each note, not as one sweep of unrelated vault writes. |
| `wiki-no-sibling:<project>` | Only the backlink. **Advisory, never a defect on its own** — a note first on its topic has nothing honest to link to. Report the count; never add a link to clear the line. |
| `decision-schema/-ref/-legacy:<path>` | Off-schema `status:`, a reference to a note that does not exist, or the legacy one-line supersession form (invalid YAML — Obsidian drops that note from every property query). Fix on sight. |
| `frontmatter:<path>` | Unterminated frontmatter block. |
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

- `_PROJECT.md`: is `Current state` actually current, is `Последняя сессия` one line per
  session, is `updated:` present? Sizes are already measured in Step 1 — here judge the
  *content* those numbers point at.
- taskboard: tasks in progress with no movement for 14+ days → move to stalled with a
  reason. Stalled for 30+ days → ask the user: still relevant?
- `00-system/connections.md`: add connections this run revealed, drop ones no longer true,
  update `## Last updated: [TODAY] lint`. Only if something actually changed — an
  unchanged file is a legitimate outcome, not a missed step.

## Step 5: Report the delta, not the backlog

```bash
bash "$BRAIN" lint-diff "$VAULT/00-system/lint-baseline.txt" < /tmp/lint-findings.txt
```

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
