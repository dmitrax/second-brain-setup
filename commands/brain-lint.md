# /brain-lint

Vault health check: find issues, update cross-project connections.

## Scope
Default: current project only. Read CLAUDE.md in current directory → find line `Project:` → that is `$PROJECT`.
With argument `--all`: entire vault.

Vault: `~/Workspace/second-brain-vault/`

## Step 0: Sync the vault before auditing it

```bash
VAULT="$HOME/Workspace/second-brain-vault"
BRAIN="$HOME/.claude/skills/second-brain/lib/brain.sh"
bash "$BRAIN" vault-sync "$VAULT"; rc=$?
```

- **0** → synced, or skipped on purpose (local-only vault is supported). Proceed.
- **2** → remote unreachable. Say so in one line, and label the report as covering a
  possibly stale checkout — the findings are still worth having, the claim of
  completeness is not.
- **3** → rebase conflict, vault is mid-rebase. **Stop.** Fix nothing: this command
  edits what it finds, and edits on top of a half-finished rebase are unreviewable.

Unlike the other commands, `/brain-lint` needs this for **reading**, not only for its
own writes. It reports what the vault does *not* contain — orphans, unresolved links,
stale projects — and every one of those verdicts is a claim about the whole vault. Run
on a checkout that is a week behind, it reports a clean bill of health for a state that
no longer exists, and does it silently: the files are all there, they read fine, nothing
looks wrong. A false green here is worse than a missed finding, because it is trusted.

## Step 0c: Is this checkout complete?

A sync makes the checkout *current*. It does not make it *whole*: `git sparse-checkout`
leaves tracked paths out of the working tree entirely, and every check below then measures
a subset while the report keeps claiming the vault.

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
- **Step 4b becomes advisory.** Basename uniqueness is a property of the whole vault, so
  a sweep that cannot see part of it can only ever produce a *lower* bound — a hidden
  project's `_PROJECT.md` or `architecture-map.md` makes existing links ambiguous with no
  edit anywhere, which is the entire reason that step exists. Report it as "no duplicates
  among the visible files", never as "no ambiguous links".
- **Do not `--seal`.** The baseline lives in the vault and is shared across machines,
  while what is visible is per-machine: sealing here drops every finding that belongs to
  a hidden path, so the next run on the machine that *can* see it reports the same
  findings as NEW, and this run reported them as GONE — twice wrong, in opposite
  directions, with nobody having fixed anything. Either carry those baseline lines
  forward verbatim into the findings you seal, or skip `--seal` and say why.

Measured 2026-08-04 on the Mac, whose vault excluded `/_arch` (228 tracked files, ~4% of
a 37 MB checkout — and no confidentiality either, since the objects sit in `.git` and
`git cat-file` reads them): `obsidian unresolved` reported 93 broken links, of which 91
pointed at files that exist and are correct on the other machine. Removing the exclusion
dropped it to 1. Three baseline findings had also gone GONE without anyone fixing them.
A check cannot tell "absent" from "not checked out" on its own — only this step can.

## Guard

```bash
bash "$BRAIN" obsidian-available "$VAULT"   # exit 0 = GUI up AND this vault active
```

Use it as the condition of every CLI branch below: `if bash "$BRAIN" obsidian-available
"$VAULT"; then … else <filesystem fallback> fi`. If it exits non-zero, fall back — do not
retry, do not wait longer, and never call `obsidian` outside the branch.

The guard is **code in `lib/brain.sh`**, not a snippet to re-enact here. It lived as a
fenced block in this file for four versions, while `SKILL.md` and `/brain-init` referred
to it as if it were a library function they had — so `/brain-init` prescribed a mutating
`obsidian move` under a guard that did not exist in its context. One copy, called by
everyone, is the fix; `preflight` runs it in both states rather than grepping for its
shape.

Never diagnose this guard by splitting its conditions into separate commands: they are
chained on `&&` precisely so the CLI is never touched until the cheap checks pass. Run
apart, the third condition executes unconditionally and cold-starts the GUI — that
happened on 2026-07-22 while debugging by hand. The logic was innocent; the diagnosis
was not.

## Step 1: Orphan notes

```bash
if bash "$BRAIN" obsidian-available "$VAULT"; then
  obsidian orphans  # returns notes with no incoming [[wikilinks]]
else
  # filesystem fallback, per note: grep -rlF "[[<basename>]]" "$VAULT" — no hits = orphan.
  # -F is mandatory. Without it the brackets read as a character class, almost every
  # file "matches", and the step reports zero orphans — a false green, not an error.
fi
```

For each orphan note:
- Suggest: link it from an existing note OR add a reference from _PROJECT.md
- Do NOT delete automatically — suggest only

## Step 1b: Broken links (CLI only)

```bash
if bash "$BRAIN" obsidian-available "$VAULT"; then
  obsidian unresolved  # [[wikilinks]] pointing to non-existent files
  obsidian deadends    # notes with no outgoing links at all
fi
# Fallback: skip this step — no reliable filesystem equivalent
```

## Step 2: Contradictions

Find notes in `$PROJECT/wiki/` where statements contradict each other.

Contradiction signals:
- Same fact stated differently in two notes
- `## For future Claude` date older than 30 days + status stable → needs verification
- A decision note contradicts practice described in a synthesis note

For each contradiction — report to user and suggest resolution.

## Step 3: Stale notes

Find notes where:
- `status: draft` and date older than 14 days → suggest promote to stable or delete
- `date:` older than 60 days with no updates → flag for review

## Step 4: Missing pages

Find [[wikilinks]] in note bodies pointing to non-existent files.
For each — suggest creating the page or fixing the link.

## Step 4b: Ambiguous links (bare [[name]] where the name is not unique)

A `[[wikilink]]` that names a file whose basename exists more than once in the vault
resolves to the first shortest-path match — silently, and to a file in whatever project
Obsidian picked. Every such link needs an explicit path instead
(`[[project/wiki/note|note]]`, `[[../_PROJECT|_PROJECT]]`).

Run over the whole vault regardless of scope. A link is broken by the *existence of a
duplicate name anywhere*, so a project-scoped run cannot see its own breakage:

```bash
cd "$VAULT" || exit 1
find . -name '*.md' -not -path './.git/*' | sed 's|.*/||; s|\.md$||' | sort | uniq -d |
while read -r name; do
  grep -rnF --include='*.md' "[[$name]]" . |
    grep -v '/sessions/' | grep -v '/archive-'
done
```

`-F` is mandatory — the pattern is full of brackets. `sessions/` and `archive-*` are
history and are not rewritten. Report every hit; do not auto-fix.

**This check exists because the class recurs without anyone writing a bad link.** A name
is unique when the link is written and stops being unique later, the moment a second
project creates a file with the same basename — at which point already-correct links in
the *older* project become ambiguous, with no edit to them and no signal anywhere.
Measured 2026-08-03: five `puzzlebot-voronka` notes written 2026-06-28…07-04 carried 33
correct bare links until `goprofi-voronka` was created 2026-07-29 reusing those five
filenames. The vault had been linted clean of this class three days earlier. So the
trigger is not authoring discipline and cannot be caught at write time by review — only a
vault-wide sweep that re-asks "is this name still unique" finds it. Run it on every lint,
not only when a project is new.

False positives are notes that *document* this bug and quote the bare form as an example,
inside backticks or a fenced block. Exclude those by filename; never relax the grep to
skip lines containing a backtick — a real bare link and an unrelated backtick share a line
often enough (confirmed live in `goprofi-voronka/_PROJECT.md`).

## Step 4c: Wiki notes that lead nowhere

`SKILL.md` requires the `[[../_PROJECT|_PROJECT]]` backlink on every wiki note, plus a
link to a sibling note whenever a related one exists. This step measures both, over every
project in scope.

```bash
cd "$VAULT" || exit 1
strip_code() { awk '/^[[:space:]]*```/ { f = !f; next } !f' "$1" | sed 's/`[^`]*`//g'; }
INC=$(mktemp)                      # not $TMPDIR — unset on most Linux setups
find . -name '*.md' -not -path './.git/*' | while read -r p; do strip_code "$p"; done |
  grep -oE '\[\[[^]|]+' | sed 's/^\[\[//; s|.*/||' | sort | uniq -c > "$INC"
find . -path '*/wiki/*.md' -not -path './.git/*' | sort | while read -r p; do
  base=$(basename "$p" .md)
  case "$base" in archive-*) continue ;; esac
  tg=$(strip_code "$p" | grep -oE '\[\[[^]|]+' | sed 's/^\[\[//')
  sib=$(printf '%s\n' "$tg" | grep -v '_PROJECT$' | grep -c .)
  proj=$(printf '%s\n' "$tg" | grep -c '_PROJECT$')
  inc=$(awk -v b="$base" '$2 == b { print $1; exit }' "$INC")
  [ -n "$inc" ] || inc=0
  if [ "$sib" -eq 0 ] && [ "$proj" -eq 0 ]; then echo "NO-LINKS	${p#./}	in=$inc"
  elif [ "$sib" -eq 0 ]; then                    echo "no-sibling	${p#./}	in=$inc"
  elif [ "$proj" -eq 0 ]; then                   echo "no-backlink	${p#./}	in=$inc"
  fi
done
rm -f "$INC"
```

Stripping inline code and fenced blocks first is not optional. A raw grep for `[[`
counts every quoted example as a link, and this vault documents link bugs in prose — the
first hand count of this check, made without stripping, was wrong in both directions at
once (it passed notes whose only two "links" were backtick literals, and it ran on a
partial checkout, so it missed `_arch` entirely: 10 reported against 39 real).

How to read the three classes — measured 2026-08-04 over 383 wiki notes:
- `NO-LINKS` (3) — a terminal note: reachable, but reading it ends the trail. The finding
  to act on. Report it with its incoming count.
- `no-backlink` (29) — links to siblings but not up to `_PROJECT`. A real violation of the
  rule and one line to fix, but the least urgent of the three: every one of these had 3-26
  incoming links, so nobody is failing to reach them. Fix on the next edit of the note, or
  in one deliberate sweep — do not turn a lint run into 29 unrelated vault writes.
- `no-sibling` (7) — carries only the `_PROJECT` backlink. **Advisory, never a defect on
  its own**: a note first on its topic has nothing honest to link to. Report the count, do
  not chase it to zero, and never add a link to clear the line — see `SKILL.md`.

**Incoming links are part of the verdict.** Measured 2026-08-04: all 12 notes below the
old "minimum 2" floor had 3-15 incoming, i.e. not one was stranded, and the floor was
flagging notes whose only fault was being early. Report `in=` on every finding so the
reader can tell an isolated note from a well-linked leaf.

## Step 5: Cross-project connections (update connections.md)

Read wiki/ of all projects (if `--all`) or current project.

Find:
- Notes in current project that reference concepts from other projects
- Decisions that may be applicable in other projects

Update `$VAULT/00-system/connections.md`:
- Add new connections
- Remove connections that are no longer relevant
- Update timestamp: `## Last updated: [TODAY] lint`

## Step 6: Check _PROJECT.md

- Is the status block current?
- Is the last-session block up to date?
- Does the `updated:` frontmatter field exist? If missing — add it, set to today.
- If not current — suggest updating

## Step 7: Check project taskboard

Read `$VAULT/$PROJECT/taskboard.md`.

Flag stale items:
- Task in active/in-progress with no updates for 14+ days
  → suggest moving to stalled with reason
- Task in stalled with no update for 30+ days
  → ask user: still relevant? close / delete / keep with new date?

Note: especially useful with `--all` flag — catches stale tasks
in projects that haven't been opened recently.

## Step 8: Stale project detector

Read `updated:` from frontmatter of `_PROJECT.md` for each project in scope.

If `updated:` is more than 14 days old:
- Flag: "Project [name] — no vault update in N days. Still active, on pause, or close?"

If `updated:` field is missing from frontmatter — flag: "Project [name] — missing
`updated:` field in _PROJECT.md. Add it and set to the date of the last session."

## Step 9: Size check

Read `$VAULT/$PROJECT/_PROJECT.md` and `$VAULT/$PROJECT/taskboard.md`.

Flag if:
- `_PROJECT.md`'s **prose sections** together exceed ~60 lines → suggest moving stale
  detail into wiki/ notes. Count only `## Current state` (or `## Статус`),
  `## Последняя сессия` and `## For future Claude`; skip blank lines. Do **not** count
  link-list sections (`## Key decisions` / `## Ключевые решения`, `## Source projects`,
  `## Рабочие файлы`) — those grow linearly with the project's decision count and
  violate no rule, so folding them into a total-size threshold makes a well-kept large
  project look like a violator. Measured 2026-07-22: `dimarch` carries 36 lines of
  legitimate decision links against 65 wiki notes, while its actual defect sits in
  `## Current state` (141 lines of prose). Total file size is not the signal — prose is
- Taskboard health — count it, do not eyeball it, and count **both** markers:

  ```bash
  tb="$VAULT/$PROJECT/taskboard.md"
  # Count closed entries INSIDE the Done section only — a closed sub-item under an
  # open task is not an archivable entry, and counting the whole file mixes two
  # different populations (measured 2026-08-03: 65 file-wide against 5 in Done).
  done_n=$(awk '/^## / { d = ($0 ~ /^## (Done|Завершено)/); next }
                d && /^[[:space:]]*-[[:space:]]*(\[x\]|✅)/ { n++ }
                END { print n + 0 }' "$tb")
  total=$(grep -c . "$tb")
  # size of ## In progress: from its heading to the next ## heading
  prog=$(awk '/^## /{p = ($0 ~ /In progress|В работе/)} p' "$tb" | grep -c .)
  echo "done=$done_n total=$total in-progress=$prog"
  ```

  Flag if `done_n` exceeds ~20 → archive old entries to `wiki/archive-YYYY.md`.
  Flag if `prog` exceeds ~300 lines. Flag if `total` exceeds ~600 lines.

  **Both markers are required.** Projects use `- [x]` and `- ✅` interchangeably, and a
  check that knows only one silently reports zero for a project using the other —
  `cadrika` carried 16 closed items invisible to the count, and the threshold would not
  have fired at 100.

  **Done alone is the wrong measure.** A taskboard is unhealthy when it is unreadable,
  and closed items are only one way to get there. Measured 2026-08-03:
  `goprofi-voronka` passed as healthy on Done while running 2199 lines, 1091 of them in
  `## In progress` — a section no session can hold in context, so new tasks get appended
  blind and duplicates accumulate. Same distortion that was fixed for `_PROJECT.md`,
  where total size was replaced by a prose budget: measure the part that hurts.
- `## Current state` (or `## Статус` in older projects — same section) contains
  multi-sentence paragraphs that restate facts a linked (or linkable) wiki/decision
  note already covers → flag as duplication, suggest collapsing the paragraph to
  one line + `[[wikilink]]`
- `## Последняя сессия` entries run longer than 1-2 lines, or the section is
  missing while `## Current state` reads like a session-by-session log (several
  dated paragraphs) → flag: session recaps are accumulating in the wrong
  section; suggest adding a proper `## Последняя сессия` and moving narrative
  out to wiki/ or the session log. This check catches the disease independent
  of size — it triggers well before the ~60-line prose budget does.
- `_PROJECT.md`'s own `## For future Claude` exceeds ~20 lines, or contains
  multi-sentence entries that restate a linked (or linkable) wiki/decision
  note's mechanism/investigation rather than just its one-line consequence →
  flag as duplication, same fix as "Current state". This section has no
  template default and no size guard elsewhere, so it tends to drift furthest
  unnoticed — confirmed live in `dimarch` (149 lines before a fix was applied).

## Step 10: Decision consistency

Find all notes in `wiki/` whose filename starts with `decision-`.

Check:
- Any decision note with `status: superseded` still referenced as active in
  `_PROJECT.md` "Key decisions" section → flag the stale link, suggest updating
- Any decision note with `status: deprecated` still referenced anywhere → same
- `supersedes:` / `superseded-by:` points to a note that does not exist → flag
  broken reference
- Any note still carrying the legacy one-line `status: superseded-by: x` form →
  flag it: that is invalid YAML (double colon = nested mapping in compact form),
  so Obsidian cannot parse the frontmatter at all and the note silently drops out
  of every property query. Fix by splitting into `status: superseded` +
  `superseded-by: x`
- `status:` holding any value other than `accepted` / `superseded` / `deprecated` →
  flag it, whatever the value — most likely a hedge like `partially-superseded-by
  <note>` invented to avoid picking `superseded`. `status` is invisible to every
  property query once it holds an off-schema value, same failure shape as the legacy
  form above. Fix: `status: superseded` + `superseded-by:` on the old note, and move
  the nuance of what changed into the *new* note's body — restating the parts of the
  old scope that still hold, not just the delta, so the new note alone is enough for
  current policy. Found live 2026-07-22 in `puzzlebot-voronka`
  (`decision-replace-o-biznese-videos-with-faceless-formats-because-no-production-resource-yet`
  carried `status: partially-superseded-by decision-restore-video-...`); fixed on sight
- `corrected-by:` points to a note that does not exist → flag broken reference
- A note that declares itself a correction of record for another note (its body says
  so, or it is the target of a `corrected-by:`) while the corrected note carries no
  `corrected-by:` field → flag the missing marker. The correction is then visible
  only from the new note, which leaves the stale fact unmarked for anyone reading
  the old one — the exact failure the field exists to prevent
- `corrected-by:` on a note whose `status:` is `superseded` → flag as redundant:
  a superseded note is already retired wholesale, the finer-grained marker adds
  nothing and suggests one of the two fields was set by mistake

## Step 10b: Frontmatter key consistency within a project

A project may require keys this package knows nothing about — `goprofi-voronka` puts
`zone:` on session logs and decision notes because that repo is split into zones. Nothing
enforces such a local convention, so it erodes silently: the `/brain-save` template shows
its own keys and reads as exhaustive at the moment of writing.

The set of frontmatter keys must be uniform inside a project. A key carried by most
earlier entries but absent from a newer one is a finding:

```bash
cd "$VAULT/$PROJECT/sessions" 2>/dev/null || exit 0
keys() { awk '/^---$/ {c++; next} c==1 && /^[A-Za-z_-]+:/ {sub(/:.*/,""); print}' "$1" | sort -u; }
n=$(ls -1 *.md 2>/dev/null | wc -l)
[ "$n" -lt 3 ] && exit 0          # too few entries to call anything a convention
conv=$(mktemp)                    # not $TMPDIR — unset on most Linux setups
for f in *.md; do keys "$f"; done | sort | uniq -c |
  awk -v n="$n" '$1 > n * 0.6 {print $2}' > "$conv"
for f in *.md; do
  have=$(keys "$f")
  while read -r k; do
    printf '%s\n' "$have" | grep -qxF "$k" || echo "$f: missing '$k'"
  done < "$conv"
done
rm -f "$conv"
```

Run the same over `wiki/decision-*.md`, which carry their own convention separately.

Report; do not auto-fill. The **key** is mechanical, the **value** is a judgement that
has to be made per entry — the session that surfaced this wrote a log tagged
`zone: root` (it crossed both zones) and, minutes later, a decision note tagged
`zone: backend` (it was about delivery). Copying a value from the previous entry would
be silently wrong, which is worse than the missing field.

The 60% threshold treats a key as a convention only when most entries carry it, so a
one-off experimental key never becomes a rule. Measured 2026-08-03: `goprofi-voronka`
had 4 logs of 55 and 2 decision notes of 100 missing `zone:`, the most recent two on
2026-08-01 — the same day, twice. Every other project came back uniform on
`date/project/tags`.

## Step 11: Architecture map freshness (code / mixed projects only)

If `architecture-map.md` exists in the project root:
- Read its `updated:` frontmatter field
- Read the date of the most recent session log in `sessions/`
- If the session log is newer than `architecture-map.md` updated date AND that session
  touched code (check session log "What we did" for code-related activity) →
  flag: "architecture-map.md may be stale — last session was [date], map was updated [date]"

```bash
if bash "$BRAIN" obsidian-available "$VAULT"; then
  # path= (exact), not file= — file= resolves by name like a wikilink and would
  # hit the first architecture-map.md in the vault, i.e. another project's
  obsidian links path=$PROJECT/architecture-map.md   # list all [[wikilinks]] in the map
  obsidian unresolved                     # which of those are broken
fi
```

If this is a code or mixed project and `architecture-map.md` does NOT exist:
- Suggest creating it: "No architecture-map.md found. Create one to improve
  code-session continuity."

Skip Steps 11 for content and config projects.

## Step 12: Diff the findings against the previous lint

Run **every** check above in full, every time. Do not narrow them to changed files:
measured 2026-08-03, a full YAML pass over 646 frontmatter blocks costs 0.19s and the
ambiguous-link sweep 0.1s. The machine half of a lint is free, and skipping files is how
a check starts reporting a clean vault it never looked at.

What is expensive is *this session* re-reading and re-judging findings that have been
parked since July. So the incremental part is here, at the end: collect every finding as
one line, `key<TAB>detail`, and diff it against the previous run.

```bash
BRAIN="$HOME/.claude/skills/second-brain/lib/brain.sh"
BASE="$VAULT/00-system/lint-baseline.txt"
# ... produce findings on stdout, one per line ...
printf '%s\n' "$FINDINGS" | bash "$BRAIN" lint-diff "$BASE" --seal
```

Keys must be **stable and free of changing numbers** — `prose-budget<TAB>goprofi-voronka`,
not `prose-budget-154`. The number belongs in the detail, which is displayed but not
compared; put it in the key and a known problem re-reports as new every time it moves.
Suggested keys: `prose-budget|<project>`, `ffc-budget|<project>`, `taskboard-size|<project>`,
`taskboard-done|<project>`, `map-stale|<project>`, `stale-draft|<path>`, `orphan|<path>`,
`unresolved|<path>`, `ambiguous-link|<path>`, `zone-missing|<project>`, `decision-schema|<path>`.

Report in this order: **NEW first** — that is this session's regression and the only part
that usually needs action; then GONE (something was fixed, confirm it was deliberate);
then the count of unchanged, which is parked debt and needs no re-litigation.

`--seal` rewrites the baseline, so pass it only on a run whose findings you have actually
reported to the user. A sealed baseline silently becomes "known" for every future run —
sealing a run nobody read is how a finding disappears without ever being seen.

**A changed key set produces fake deltas, and they are recognisable.** The baseline
compares keys, so renaming a check's key — or adding and dropping checks between runs —
shows up as a NEW and a GONE for what is one unchanged finding. Measured 2026-08-03 on
the first real run: three GONE entries (`zone-missing`, `stalled-task`, `vault-junk`) were
not fixed at all; one had been renamed to `key-uniformity` and two came from checks the
run did not perform. The tell is a GONE with no memory of anyone fixing it, often paired
with a suspiciously similar NEW. When the check set changes, say so explicitly in the
report and re-seal deliberately — never let the reader believe debt was cleared.

Corollary: a finding that stops being *produced* is indistinguishable from one that was
*fixed*. So dropping a check silently retires every finding it owned. If a check is
removed on purpose, say which findings leave with it.

The baseline lives in the vault, so a lint on one machine informs the next lint on the
other. Full re-litigation of everything is still available: delete the baseline, or read
it directly — it is a plain text file.

## Result

```
✓ Lint complete: $PROJECT
Coverage:              entire vault / everything except [paths] (partial checkout)

NEW since last lint:   [N] ← this session's regression, act on these
GONE since last lint:  [N] ← fixed; confirm it was deliberate
Known, unchanged:      [N] ← parked debt, listed in the baseline, do not re-litigate

Orphan notes:          [N] (list)
Contradictions:        [M] (list)
Stale notes:           [K] (list)
Missing link targets:  [L] (list)
Stale projects:        [N] (list with days since update)
Size warnings:         [N] (list)
Decision issues:       [N] (list)
Architecture map:      ok / stale / missing / not applicable
Broken links (CLI):    [N] (list) / n/a (Obsidian не запущен)
Taskboard:             [N] stale tasks flagged
Connections.md:        updated / no changes

Recommendations:
[list of specific actions]

Run /brain-save to persist any wiki changes made during lint.
```
