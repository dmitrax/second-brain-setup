#!/usr/bin/env bash
# brain.sh — deterministic helpers for the second-brain commands.
#
# Why this file exists: everything here used to live as fenced code blocks inside
# SKILL.md and commands/*.md, where it looked like code but was never executed as
# code — not run, not tested, not even syntax-checked, only re-enacted by an LLM
# from memory. All four bugs in v1.4.3/v1.5.0 were in those blocks. A block also
# runs in the *session's* shell, which is zsh on macOS, where `[ a \< b ]` fails
# and unquoted word-splitting does not happen; this file has its own shebang and
# is always invoked as `bash .../brain.sh`, so its semantics are fixed.
#
# Scope rule: only what is deterministic belongs here. Judgement — what to write,
# which convention a project follows, whether a fact belongs in CLAUDE.md — stays
# in the prompts. See CLAUDE.md Block 2.
#
# bash 3.2 floor: macOS ships /bin/bash 3.2 and it is one of the two machines.
# No mapfile/readarray, no declare -A, no ${var^^}.
#
# Language: every message this file prints is English — the package is installed by
# people who may not read Russian, and the Russian documentation is separate
# (README_RU.md, WORKFLOW.md, ВТОРОЙ_МОЗГ_*.md). The Cyrillic that remains is NOT
# text: it is search patterns matching section names inside a user's vault
# ("Завершено", "В работе", "Статус", "Последняя сессия", "ЗАКРЫТО"). Translating
# those would stop the checks from seeing a Russian-language vault at all. Do not
# "finish the translation" here — add patterns for new languages instead.

set -u

usage() {
    cat <<'USAGE'
usage: brain.sh <command> [args]

  obsidian-available <vault>   exit 0 if the Obsidian GUI is up AND the active
                               vault is the one given; 1 otherwise. Never starts
                               the app, never blocks: every call is under timeout.
  vault-name                   print the active vault's name (empty if none).
  vault-sync <vault>           pull the vault before the first write.
                               exit 0 synced or skipped on purpose
                               exit 2 remote unreachable  -> warn, keep going
                               exit 3 rebase conflict     -> stop, write nothing
  stamp-field <file> <k> <v>   set one frontmatter key, touching that one line
                               and nothing else. Adds the key if absent.
  version                      print the installed version (from the VERSION file
                               written by install.sh/update.sh), or "unknown".
  archive <taskboard> <archive> --before <YYYY-MM-DD> [--apply]
                               move closed entries older than the date from the
                               taskboard's Done section into the archive note.
                               Dry-run unless --apply. Refuses on any imbalance.
  backfill-dates <taskboard> [--apply]
                               give every undated closed entry the date of the first
                               commit that shows it closed. archive can only move dated
                               entries, so an undated Done section is a threshold no
                               amount of archiving can satisfy. Refuses outside git and
                               on entries it cannot tell apart. Dry-run unless --apply;
                               the rewrite must differ from the original by dates alone.
  sweep-closed <taskboard> [--apply]
                               move closed top-level items, with their bodies, from
                               the In progress section into Done — the section the
                               threshold keeps firing on and `archive` never touched.
                               A closed sub-item never moves alone: its text explains
                               the open parent above it. Dry-run unless --apply, and
                               the result must be a permutation of the input.
  catalog <vault> [--project <name>]
                               print a GENERATED index of the vault's notes. Without
                               --project: one line per project — notes, decisions, how
                               many are still in force, how many retired, newest date.
                               With --project: one line per note, newest first, carrying
                               each decision's state (accepted / superseded→<note> /
                               +corrected). Never stored, so it cannot drift out of sync
                               with the notes; borrowed from nf-content's catalog-records,
                               where the same index is maintained by hand and may.
  connections-add <connections.md> <YYYY-MM-DD>
                               read one cross-project entry from stdin and insert it at
                               the TOP of the knowledge-transfers section. The address is
                               the point: Step 7 named the entry's format and not its
                               place, so sessions appended to the end of the file, which
                               sat inside a heading dated weeks earlier. Writes at once —
                               an append has nothing to preview, and a default no-op
                               would read as a recorded connection. Refuses an empty
                               entry, a missing section, a bad date and an exact
                               duplicate; verifies the count grew by exactly one.
  prose-budget <_PROJECT.md> [taskboard.md]
                               measure what /brain-lint measures, at the moment of
                               writing instead of a day later: the three prose sections
                               of _PROJECT.md and the three taskboard metrics.
                               exit 0 within budget · 2 over · 1 could not measure.
  claude-md-audit <CLAUDE.md>  report what a project CLAUDE.md holds that expires: a
                               state section, a copy of the stack inventory, a heading
                               led by a date. Size is deliberately not measured — rules
                               grow legitimately. Takes the path, never guesses it.
                               exit 0 clean · 2 findings · 1 could not read the file.
  vault-language <vault>       print the working language recorded in the vault's
                               CRITICAL_FACTS.md, accepting every spelling the key has
                               had. Raw value, never normalised — a real answer may name
                               two languages for two purposes.
                               exit 0 answered · 1 no profile file · 2 key unanswered.
  local-conventions <vault> <project> [claude-md]
                               print the frontmatter KEYS this project uses beyond
                               the template (from its latest session log and decision
                               note) and any rule its CLAUDE.md states. Keys only —
                               values are a judgement per entry. Fails when it could
                               read none of the three, so silence cannot pass for
                               "this project has no local conventions".
  save-report <vault> <project>
                               print what this save actually left on disk — session log,
                               wiki notes, decision notes, version stamp, _PROJECT.md,
                               taskboard, map, index, connections, local keys — measured
                               against the vault's working tree, so a skipped step shows
                               up as MISSING instead of as a filled-in template line.
                               Run it AFTER the writes and BEFORE the commit.
                               exit 0 every owed step left a trace · 2 one did not
                               · 1 could not measure.
  lint-collect <vault> [--project P]
                               run every mechanical vault check and print each
                               finding as `key<TAB>detail` on stdout. Fails, never
                               prints a green, when its input is empty.
  lint-diff <baseline> [--seal]
                               read findings on stdin (one per line, `key<TAB>detail`),
                               print what is NEW and what is GONE against the baseline,
                               and how many are unchanged. --seal rewrites the baseline.
                               An empty stdin against a populated baseline is refused:
                               a broken producer and a clean vault look the same from
                               here. --allow-empty is the deliberate way through.
  release-check <vault>        answer gates 2 and 3 of the release rule by measuring them:
                               run the lint against this vault and report the delta, and
                               look for a session log dated on or after the HEAD commit in
                               a project stamped with the version HEAD describes. Both were
                               a protocol nothing checked — and on 2026-08-18 gate 3 was
                               declared closed by the session that wrote the code. Not part
                               of preflight.sh on purpose: that stays repo-only and must
                               run where no vault exists.
                               exit 0 both gates answered · 2 one is not met · 1 cannot read
  rename <vault> <old-rel-path> <new-rel-path> [--apply]
                               rename a wiki note and repoint every link form to it —
                               bare, path-qualified, aliased, #heading, ^block, ![[embed]].
                               The Obsidian CLI is never used for this: it wrote settings
                               into the vault and let the GUI splice links into unrelated
                               sentences from a stale cache. Refuses a basename already
                               taken elsewhere in the vault. A pointer is repointed, a
                               QUOTATION is not — `wiki/name.md` in prose records what was
                               created that day — and the run prints how many quoted
                               mentions it left. Dry-run unless --apply.
USAGE
}

# ── release-check ────────────────────────────────────────────────────────────
# Gates 2 and 3 of the release rule were the only two nothing measured, and they are the
# two that decide a tag. Gate 1 (preflight) is a script; these were a protocol, kept in a
# person's head — and on 2026-08-18 gate 3 was declared closed by a session that had
# written the code it was judging, which is the one thing the rule forbids in so many words.
#
# It lives here and NOT in `preflight.sh` on purpose: the gate is repo-only and installs
# into a clean temporary $HOME, so it can run on a machine that has no vault, and a check
# that silently needs one would be a green meaning "did not run". This reads the vault; the
# release rule names both commands and their order.
#
# Gate 2 is EXECUTED rather than attested — collect and diff, right here, and report.
# Gate 3 is inferred from what a foreign session leaves behind: a session log dated after
# the commit under test, in a project stamped with that same version. Neither half is a
# judgement, so neither is left to memory.
release_check() {
    vault="${1:-}"
    [ -d "$vault" ] || { echo "release-check: no vault at '${vault:-}'" >&2; return 1; }
    repo=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
    [ -d "$repo/.git" ] || repo=""
    rc_status=0

    # ── gate 2: the lint has actually been run on this vault, by running it ──
    rc_tmp="${TMPDIR:-/tmp}/brain-release.$$"
    if lint_collect "$vault" > "$rc_tmp" 2>/dev/null; then
        n_find=$(grep -c . "$rc_tmp" || true)
        base="$vault/00-system/lint-baseline.txt"
        if [ -f "$base" ]; then
            # The status is read, not just the text. `lint_diff` refuses on a corrupt
            # baseline and on an empty producer, and both refusals print no "NEW" line —
            # so parsing the output alone turns a refusal into "0 NEW", which is this
            # package's own headline defect appearing inside its release gate. Found
            # 2026-08-26, minutes after the baseline guard above was added: gate 2 said
            # `ok, 0 NEW` while a hand-run diff on the same vault said 3.
            delta=$(lint_diff "$base" < "$rc_tmp" 2>&1); rc_delta=$?
            n_new=$(printf '%s' "$delta" | sed -nE 's/^NEW since last lint \(([0-9]+)\).*/\1/p')
            # A finding that KEPT its key and grew is a regression too, and it is the one
            # the delta was blind to until 2026-08-26. Asking about NEW alone would let a
            # board go 184 -> 197 between two releases without a word.
            n_worse=$(printf '%s' "$delta" | sed -nE 's/^WORSE since last lint \(([0-9]+)\).*/\1/p')
            : "${n_new:=0}"; : "${n_worse:=0}"
            if [ "$rc_delta" -ne 0 ]; then
                echo "gate 2  MISSING   the delta could not be read — the baseline itself is the problem:"
                printf '%s\n' "$delta" | sed 's/^/          /'
                rc_status=2
            elif [ "$n_new" -eq 0 ] && [ "$n_worse" -eq 0 ]; then
                echo "gate 2  ok        lint run here: $n_find findings, nothing new and nothing worse"
            else
                echo "gate 2  ANSWER    lint run here: $n_find findings, $n_new NEW and $n_worse WORSE — say whether each is this release"
            fi
        else
            echo "gate 2  MISSING   no baseline at $base — a delta cannot be read, so nothing was ever sealed"
            rc_status=2
        fi
    else
        echo "gate 2  MISSING   lint-collect could not run against $vault"
        rc_status=2
    fi
    rm -f "$rc_tmp"

    # ── gate 3: a session other than the one that wrote the code has used it ──
    if [ -z "$repo" ]; then
        echo "gate 3  MISSING   not inside the package repository — the commit under test is unknown"
        rm -f "$rc_tmp"; return 2
    fi
    # The code under test is what gets INSTALLED, never HEAD. A commit touching only
    # `preflight.sh` or `CLAUDE.md` changes nothing a session can run, yet `git describe
    # HEAD` renames the thing under judgement and no stamp in the vault can ever match it.
    # Measured 2026-08-26: HEAD read `v1.8.0-2-g4319071` (two non-shipping commits past the
    # tag), gate 3 reported MISSING, and the gate was in fact closed — the last shipping
    # commit was `39f859f` of 08-19 and three foreign projects had used it since. A false
    # red in the release gate is worse than none: it gets read as noise.
    #
    # Rejected, and worth writing down: recomputing VERSION from the shipping paths instead.
    # The `release: vX` commit itself ships nothing, so `describe` over shipping paths would
    # call v1.8.0's own code `v1.7.0-N-g39f859f` — the version would understate itself.
    code_when=$(git -C "$repo" log -1 --format=%cI -- SKILL.md commands lib install.sh update.sh 2>/dev/null)
    code_sha=$(git -C "$repo" log -1 --format=%h  -- SKILL.md commands lib install.sh update.sh 2>/dev/null)
    if [ -z "$code_when" ]; then
        echo "gate 3  MISSING   no commit touches the installed paths — nothing to judge"
        return 2
    fi
    code_min=$(printf '%s' "$code_when" | cut -c1-16)

    # The version is read from the INSTALLED copy, because that is what a session ran and
    # what `/brain-save` stamps into a project. Reading it here through brain_version()
    # would resolve against this script's own directory — the repo, which carries no
    # VERSION file — and answer "unknown" every time.
    inst_dir="$HOME/.claude/skills/second-brain"
    ver=""
    [ -r "$inst_dir/lib/VERSION" ] && ver=$(head -1 "$inst_dir/lib/VERSION")
    if [ -z "$ver" ] || [ "$ver" = "unknown" ]; then
        echo "gate 3  ANSWER    nothing is installed here, so no session can have used this code"
        echo "          run ./update.sh, then use the package from another project"
        return $rc_status
    fi
    # "The installed copy is not this code" and "nobody has used this code" are different
    # facts, and only the second is a red. Saying MISSING for the first would be a verdict
    # about the soak drawn from a fact about the machine.
    stale_files=""
    for f in SKILL.md lib/brain.sh; do
        cmp -s "$repo/$f" "$inst_dir/$f" || stale_files="$stale_files $f"
    done
    for f in "$repo"/commands/*.md; do
        [ -f "$f" ] || continue
        cmp -s "$f" "$HOME/.claude/commands/$(basename "$f")" || stale_files="$stale_files commands/$(basename "$f")"
    done
    if [ -n "$stale_files" ]; then
        echo "gate 3  ANSWER    the installed copy ($ver) is not this code — run ./update.sh first"
        echo "         differs:$stale_files"
        return $rc_status
    fi

    # A `-dirty` stamp means the working tree is ahead of every commit, so the commit time
    # bounds nothing and printing it as the code's age would be a true verdict carrying a
    # false premise. The stamp is what binds there — a project can only carry `-dirty` if a
    # session ran against exactly this uncommitted tree.
    code_note=""
    case "$ver" in
        *-dirty) code_note=" — the working tree is ahead of $code_sha, so the stamp binds, not the date" ;;
    esac

    # A session that counts, on three conditions at once:
    #   * it belongs to ANOTHER project. The session that writes the code saves into this
    #     package's own project by construction — the project is decided by the repository
    #     being worked in. Measured 2026-08-18: `b9e18a3` at 11:03:04 and this project's
    #     `2026-08-18_1111_session.md` eight minutes later, which is the very session that
    #     declared the gate closed on its own code.
    #   * its log is stamped LATER than the commit. The log file is created by /brain-save,
    #     i.e. at save time, so "later than the commit" alone would have passed that same
    #     08-18 author — it is the project that separates them, and the time only closes
    #     the cheap hole of a foreign save that happened earlier the same day.
    #   * its project carries this version. A log alone says a session happened; the stamp
    #     says it happened ON THIS CODE.
    # Four logs of 350 carry no HHMM (June-July, two of them lint runs): time unknown reads
    # as 00:00, so such a log counts only on a strictly later day.
    own=$(basename "$repo")
    witnesses=""
    while IFS= read -r pm <&3; do
        [ -n "$pm" ] || continue
        pdir=$(dirname "$pm")
        prel=${pdir#"$vault"/}
        [ "$prel" != "$own" ] || continue
        pver=$(sed -nE 's/^brain-version:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/p' "$pm" | head -1)
        [ "$pver" = "$ver" ] || continue
        while IFS= read -r log <&4; do
            [ -n "$log" ] || continue
            lbase=$(basename "$log")
            lday=$(printf '%s' "$lbase" | cut -c1-10)
            case "$lday" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;; *) continue ;; esac
            lhm=$(printf '%s' "$lbase" | sed -nE 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}_([0-9]{2})([0-9]{2})_.*/\1:\2/p')
            [ -n "$lhm" ] || lhm="00:00"
            if [ "${lday}T${lhm}" \> "$code_min" ]; then
                witnesses="${witnesses}  ${prel}/${lbase}"$'\n'
            fi
        done 4<<EOF4
$(find "$pdir/sessions" -name '*_session.md' 2>/dev/null | LC_ALL=C sort)
EOF4
    done 3<<EOF3
$(find "$vault" -name '_PROJECT.md' -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort)
EOF3
    if [ -n "$witnesses" ]; then
        echo "gate 3  ok        $ver ($code_sha, $code_min)$code_note has been used by a session in another project:"
        printf '%s' "$witnesses"
    else
        echo "gate 3  MISSING   no session in another project, stamped $ver, saved after $code_sha ($code_min)$code_note"
        echo "          the soak is not a waiting period, it is evidence — use the package, then re-run"
        rc_status=2
    fi
    return $rc_status
}

# ── lint-diff ────────────────────────────────────────────────────────────────
# Measured 2026-08-03: a full YAML pass over 646 frontmatter blocks takes 0.19s and
# the ambiguous-link sweep 0.1s — the machine half of a lint costs nothing, so
# there is nothing to save by scanning fewer files. What actually costs is the
# session re-reading and re-judging every finding, including the ones parked since
# July. So the incremental part belongs here: run every check in full, then show
# only the delta against the previous run.
#
# This is also what separates a one-off debt payment from routine upkeep — the two
# were indistinguishable before, which made a whole day's cost look like today's tax.
#
# A finding is `key<TAB>detail`: the key is stable (type + object) and is what gets
# compared; the detail may carry changing numbers and is only displayed. Putting a
# number in the key would report a known problem as new every time it moves.
lint_diff() {
    base=""; seal=""; allow_empty=""; scope=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --seal)        seal="--seal" ;;
            --allow-empty) allow_empty=1 ;;
            --scope)       shift; scope="${1:-}"
                           [ -n "$scope" ] || { echo "lint-diff: --scope needs a project" >&2; return 64; } ;;
            -*)            echo "lint-diff: unknown option '$1'" >&2; return 64 ;;
            *)             if [ -n "$base" ]; then
                               echo "lint-diff: one baseline path, got a second: '$1'" >&2; return 64
                           fi
                           base="$1" ;;
        esac
        shift
    done
    [ -n "$base" ] || { echo "lint-diff: need a baseline path" >&2; return 1; }

    cur="${TMPDIR:-/tmp}/brain-lint-cur.$$"
    cat > "$cur"
    # Keys must be unique: type plus object. Two different objects sharing one key
    # ("stale-draft" for three separate files) collapse into one, and fixing one of
    # them is invisible to the diff because the key stays put. Caught on the very
    # first live baseline, where the type had been written without the object.
    #
    # Both inputs are checked, not just stdin. Until 2026-08-26 only stdin was, and the
    # baseline was the input that could actually go bad on its own: a scoped `--seal`
    # wrote out-of-scope CURRENT findings next to the baseline's own line for the same
    # key (see the seal branch below), so the file grew a second line per key whose
    # detail had moved. Measured that day in the live vault — two `scope-note:lifecycle-docs`
    # lines. Nothing noticed, because `cut_keys` runs `sort -u` and a duplicate key
    # collapses there silently: the comparison stays correct while the file rots.
    _dup_keys() { cut -f1 "$1" | LC_ALL=C sort | uniq -d; }
    dup=$(_dup_keys "$cur")
    if [ -n "$dup" ]; then
        echo "lint-diff: keys are not unique — add the object to the key:" >&2
        printf '%s\n' "$dup" | sed 's/^/  /' >&2
        rm -f "$cur"; return 1
    fi
    if [ -f "$base" ]; then
        dup=$(_dup_keys "$base")
        if [ -n "$dup" ]; then
            echo "lint-diff: the baseline holds the same key twice — it cannot be compared:" >&2
            printf '%s\n' "$dup" | sed 's/^/  /' >&2
            echo "  Delete the stale line by hand; a key names one object, so one line is right." >&2
            rm -f "$cur"; return 1
        fi
    fi

    # An empty stdin against a POPULATED baseline is the dangerous case, and it was
    # unguarded until 2026-08-19: every finding was reported GONE, exit 0, and --seal
    # wrote a zero-byte baseline into the vault — so the next run on any machine reports
    # the lot as NEW. That is exactly the fabricated delta the baseline exists to prevent,
    # produced by the baseline's own tool. Measured: `lint-collect /nonexistent | lint-diff
    # base --seal` emptied a 3-key baseline and returned 0, because the collector's
    # non-zero exit is invisible here (this file runs under `set -u`, NOT `pipefail` — a
    # pipeline reports its LAST command). "The producer broke" and "the vault went clean"
    # are the same observation from inside, so the tie is broken by refusing and saying so.
    if [ ! -s "$cur" ] && [ -s "$base" ] && [ -z "$allow_empty" ]; then
        echo "lint-diff: no findings on stdin, but the baseline holds $(grep -c . "$base")" >&2
        echo "  A broken producer and a vault that went clean are indistinguishable here." >&2
        echo "  Check the collector's exit code first. When the vault really is clean," >&2
        echo "  pass --allow-empty; only then will --seal empty the baseline." >&2
        rm -f "$cur"; return 1
    fi
    if [ ! -s "$cur" ] && [ ! -f "$base" ]; then
        # No findings and no baseline is a legitimate first clean run, but an empty
        # stdin usually means the caller's pipeline broke. Say which one it is.
        echo "lint-diff: no findings on stdin and no baseline yet — nothing to compare"
        [ "$seal" = "--seal" ] && : > "$base"
        rm -f "$cur"; return 0
    fi
    if [ ! -f "$base" ]; then
        echo "lint-diff: no baseline at $base — treating all $(grep -c . "$cur") findings as new"
        sed 's/^/  NEW  /' "$cur"
        [ "$seal" = "--seal" ] && cp "$cur" "$base"
        rm -f "$cur"; return 0
    fi

    # LC_ALL=C on every sort that feeds comm, and on comm itself. Collation is
    # locale-dependent: measured 2026-08-04, the C locale orders `Note-Alone.md` before
    # `note-alone.md` while en_US.UTF-8 orders them the other way, and `comm` requires
    # both inputs ordered the same way. Pinning makes the order a property of the code
    # rather than of whichever machine happens to run it.
    #
    # What this comment claimed until 2026-08-04 and what measuring it showed:
    #   - claimed: an unpinned run reports the SAME key as both NEW and GONE.
    #     Not reproducible on Arch (glibc 2.4x, coreutils 9.11): `sort` and `comm` read
    #     one environment, so they agree, and glibc's collation has a codepoint tiebreak
    #     that keeps `sort -u` from collapsing keys distinct only in punctuation or case.
    #     Whether BSD `sort`/`comm` behave differently is untested — see the taskboard.
    #   - claimed: exporting LC_ALL=C globally would blind the Cyrillic patterns.
    #     Measured false in the dangerous direction. Literal patterns (`Статус`,
    #     `Завершено`) match fine under C — they are byte sequences. The character
    #     CLASS `[А-Яа-яЁё]` does not stop matching either; under C it degrades into a
    #     byte range that matches ANY non-ASCII, so `café` reads as Cyrillic.
    # So the pinning stays — it costs nothing and removes a machine-dependent property
    # from a cross-machine comparison — but it is defence, not a repair of a measured
    # break. Still not exported globally: over-matching classes are the reason now.
    # Anything asserting an equivalent of `[А-Яа-яЁё]` must state the locale it needs
    # instead of assuming one; preflight self-tests exactly that before using the class.
    # ── scope ────────────────────────────────────────────────────────────────
    # The baseline is ONE file for the whole vault while a lint run is scoped to a project
    # by default. Until 2026-08-19 the two were compared regardless: a scoped run reported
    # every other project's finding as GONE — which the report glosses as "fixed, confirm it
    # was deliberate" — and `--seal` then erased them from a file that is committed to the
    # vault and read on every machine, so the next full run reported the lot as NEW. The
    # command manufactured, by its own documented default, exactly the fabricated delta it
    # exists to expose.
    #
    # So a scope splits BOTH sides. Baseline lines outside the scope are carried through a
    # seal untouched; current findings outside it are named and not compared — a scoped run
    # legitimately produces some, because two sweeps stay vault-wide by design, and silently
    # counting them as NEW would be the same fabrication in the other direction.
    #
    # Attribution is by prefix against the scope given, not by parsing the key: the object
    # is `demo`, `_arch/dimarch`, `goprofi-voronka/wiki/note.md` — one, two or many segments
    # — and "does it start with P, at a segment boundary" needs no grammar for any of them.
    base_cmp="$base"
    if [ -n "$scope" ]; then
        base_in="${TMPDIR:-/tmp}/brain-lint-basein.$$"
        base_out="${TMPDIR:-/tmp}/brain-lint-baseout.$$"
        cur_out="${TMPDIR:-/tmp}/brain-lint-curout.$$"
        cur_in="${TMPDIR:-/tmp}/brain-lint-curin.$$"
        : > "$base_in"; : > "$base_out"; : > "$cur_in"; : > "$cur_out"
        _scope_split() {
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                obj=${line%%	*}; obj=${obj#*:}
                case "$obj" in
                    "$scope"|"$scope"/*) printf '%s\n' "$line" >> "$2" ;;
                    *)                   printf '%s\n' "$line" >> "$3" ;;
                esac
            done < "$1"
        }
        _scope_split "$base" "$base_in" "$base_out"
        _scope_split "$cur"  "$cur_in"  "$cur_out"
        n_out=$(grep -c . "$cur_out" || true)
        if [ "$n_out" -gt 0 ]; then
            echo "outside the scope '$scope', reported but not compared ($n_out):"
            cut -f1 "$cur_out" | sed 's/^/  · /'
        fi
        mv "$cur_in" "$cur"
        base_cmp="$base_in"
    fi

    cut_keys() { cut -f1 "$1" | LC_ALL=C sort -u; }
    new_keys="${TMPDIR:-/tmp}/brain-lint-new.$$"
    gone_keys="${TMPDIR:-/tmp}/brain-lint-gone.$$"
    LC_ALL=C comm -23 <(cut_keys "$cur") <(cut_keys "$base_cmp") > "$new_keys"
    LC_ALL=C comm -13 <(cut_keys "$cur") <(cut_keys "$base_cmp") > "$gone_keys"

    n_new=$(grep -c . "$new_keys"); n_gone=$(grep -c . "$gone_keys")
    n_same=$(( $(cut_keys "$cur" | grep -c .) - n_new ))

    # A key present on both sides can still have moved. Only types declared in
    # LINT_COUNTED are read this way, and only their LEADING integer — see the
    # declaration for why the trait cannot be inferred from the detail.
    moved="${TMPDIR:-/tmp}/brain-lint-moved.$$"
    awk -F'\t' -v counted=" $LINT_COUNTED " '
        NR == FNR { was[$1] = $2; next }
        ($1 in was) {
            t = $1; sub(/:.*/, "", t)
            if (index(counted, " " t " ") == 0) next
            a = was[$1]; b = $2
            if (a !~ /^[0-9]+/ || b !~ /^[0-9]+/) next
            if (b + 0 > a + 0)      printf "worse\t%s\t%s\t%s\n",  $1, a + 0, b + 0
            else if (b + 0 < a + 0) printf "better\t%s\t%s\t%s\n", $1, a + 0, b + 0
        }' "$base_cmp" "$cur" > "$moved"
    n_worse=$(grep -c '^worse' "$moved" || true)
    n_better=$(grep -c '^better' "$moved" || true)
    n_same=$(( n_same - n_worse - n_better ))

    if [ "$n_new" -gt 0 ]; then
        echo "NEW since last lint ($n_new):"
        while read -r k; do
            [ -n "$k" ] || continue
            awk -F'\t' -v k="$k" '$1 == k { print "  + " $1 (NF > 1 ? " — " $2 : "") }' "$cur"
        done < "$new_keys"
    fi
    if [ "$n_worse" -gt 0 ]; then
        echo "WORSE since last lint ($n_worse) — same finding, bigger:"
        awk -F'\t' '$1 == "worse" { printf "  ^ %s — %s -> %s\n", $2, $3, $4 }' "$moved"
    fi
    if [ "$n_gone" -gt 0 ]; then
        echo "GONE since last lint ($n_gone):"
        sed 's/^/  - /' "$gone_keys"
    fi
    if [ "$n_better" -gt 0 ]; then
        echo "BETTER since last lint ($n_better):"
        awk -F'\t' '$1 == "better" { printf "  v %s — %s -> %s\n", $2, $3, $4 }' "$moved"
    fi
    echo "known and unchanged: $n_same (parked debt, not this session's regression)"

    if [ "$seal" = "--seal" ]; then
        if [ -n "$scope" ]; then
            # In-scope lines are replaced; out-of-scope lines are carried through from the
            # BASELINE, verbatim. `$cur_out` must never appear here — those are the current
            # findings this run printed as "reported but not compared", and sealing them
            # would record another project's state as known debt on the strength of a run
            # that deliberately looked away from it. Measured 2026-08-26: a scoped seal on
            # `alpha` wrote `beta 99 open items` beside the baseline's `beta 10`, giving two
            # lines for one key, and the live vault already carried such a pair. Worse than
            # the duplicate: B's regression becomes parked debt on every machine, and the
            # only run that could have caught it is the one that sealed it.
            cat "$cur" "$base_out" | LC_ALL=C sort -u > "$base"
            echo "baseline updated: $base ($(grep -c . "$cur") in scope, $(grep -c . "$base_out" || true) carried over, $(grep -c . "$cur_out" || true) left uncompared)"
        else
            cp "$cur" "$base"
            echo "baseline updated: $base"
        fi
    fi
    [ -n "$scope" ] && rm -f "$base_in" "$base_out" "$cur_out"
    rm -f "$cur" "$new_keys" "$gone_keys" "$moved"
}

# ── archive ──────────────────────────────────────────────────────────────────
# Moving Done entries used to mean the model reading several hundred lines and
# retyping them almost verbatim — measured 2026-07-22, it ate most of a session,
# and the first attempt silently duplicated three entries. Cutting text is not a
# language task: the model picks the boundary (a date), the script moves the
# bytes. Nothing is summarised, reworded or dropped here by design.
#
# An entry starts at `- [x] YYYY-MM-DD` or `- ✅ YYYY-MM-DD` and continues through
# every following line until the next such marker — both forms exist across
# projects, and a counter that knows only one reports zero for the other.
archive_done() {
    tb="${1:-}"; ar="${2:-}"; before="${3:-}"; apply="${4:-}"
    [ -f "$tb" ] || { echo "archive: no taskboard at '${tb:-}'" >&2; return 1; }
    # The archive note is CREATED when it does not exist, under --apply. Refusing was a
    # dead end: nothing in the package ever created one — not /brain-init, not install.sh —
    # and no prompt named its path, so the remedy prescribed for `taskboard-done` failed on
    # its first use in every project, with a message naming a file the user had no way to
    # know they were supposed to make. Measured 2026-08-19. A dry run says it would create
    # rather than creating, so the default stays a no-op.
    if [ ! -f "$ar" ]; then
        case "$ar" in
            "") echo "archive: need an archive-note path as the second argument" >&2; return 1 ;;
        esac
        if [ "$apply" = "--apply" ]; then
            [ -d "$(dirname "$ar")" ] || { echo "archive: no directory for '$ar'" >&2; return 1; }
            printf '# Archive — closed tasks\n\nMoved out of the taskboard by `brain.sh archive`.\nThe taskboard keeps what is open; this file keeps what is done and dated.\n' > "$ar" ||
                { echo "archive: could not create '$ar'" >&2; return 1; }
            echo "archive: created $ar"
        else
            echo "archive: $ar does not exist yet — --apply would create it"
        fi
    fi
    case "$before" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
        *) echo "archive: --before needs YYYY-MM-DD, got '${before:-}'" >&2; return 1 ;;
    esac

    work="${TMPDIR:-/tmp}/brain-archive.$$"
    mkdir -p "$work" || return 1
    awk -v before="$before" -v w="$work" '
        BEGIN { part = "head" }
        # Section boundaries: Done starts at its heading, ends at the next ## heading.
        /^## / {
            if (part == "done") { part = "tail" }
            else if ($0 ~ /^## (Done|Завершено)/) { print > (w "/head"); part = "done"; next }
        }
        part != "done" { print > (w "/" part); next }
        {
            # A `###` sub-heading inside Done belongs to the BOARD, not to the entry above
            # it. Until 2026-08-19 it fell through to `dest` and travelled with whichever
            # entry came before: a fixture with `### July` / two July entries / `### August`
            # / two August entries archived `### August` into the archive note, leaving the
            # August entries under `### July` — the board then asserting that August work
            # closed in July, and the archive note ending on a heading with nothing under it.
            # Both balance checks passed by construction: no entry and no line was lost,
            # they were merely filed under a heading that now lies. `sweep-closed` states
            # the rule for its own direction ("a heading is not moved — only items are");
            # `archive` moved them, into a different file.
            # The heading and any prose following it stay in the board. An entry under it
            # still moves when it is due — only the heading stops travelling.
            if ($0 ~ /^###+[[:space:]]/) {
                print > (w "/kept"); dest = "kept"; cur_undated = 0; next
            }
            # New entry? `- [x] 2026-08-03` / `- ✅ 2026-08-03`, at column 0 only.
            # An INDENTED closed item is a sub-item of the entry above it, not an entry:
            # it is one line of the body of that entry and must travel with it. Anchoring this
            # at ^[[:space:]]* instead tore parents from their children — measured
            # 2026-08-04 on a fixture, `--apply` moved a dated parent into the archive
            # note and left its two closed sub-items behind in Done, orphaned and
            # meaningless. Silently: exit 0, and the balance check below agreed, because
            # it counted the same wrong population (2 moved + 2 kept = 4).
            # Continuation lines fall through to `dest` below, which is what makes the
            # sub-items follow their parent once they stop being counted as entries.
            if ($0 ~ /^-[[:space:]]*(\[x\]|✅)/) {
                entry++                       # a new entry begins; body lines follow
                d = ""
                if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
                    d = substr($0, RSTART, RLENGTH)
                # No date -> keep. Never move what we cannot date.
                dest = (d != "" && d < before) ? "moved" : "kept"
                n[dest]++
                # Three states, three different words — see the note above the function.
                # `undatable` is the one that used to be silent: the entry carries no date
                # in its head, but its BODY does, so "nothing to archive" was read as
                # "nothing is due" when it meant "I am not looking where the date is".
                if (d == "") { undated_head++; body_date = 0; cur_undated = 1 }
                else         { cur_undated = 0 }
                next_is_body = 1
            }
            # A body line of an entry whose head carried no date: remember that a date
            # exists down here, but never USE it — measured 2026-08-16 on the goprofi
            # taskboard as of 08-07, body dates mean several different things
            # ("Исправлено 07.08" is a closing date, "(заведено 2026-07-31)" is not,
            # "со сроком 2026-08-02" is a deadline). Moving by them would archive
            # entries by the wrong date, silently.
            if (cur_undated && $0 !~ /^-[[:space:]]*(\[x\]|✅)/ &&
                $0 ~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9]?\.[0-9][0-9]/) {
                if (!body_date) { body_date = 1; undatable++ }
            }
            if (dest == "") { print > (w "/head"); next }   # prose before the first entry
            print > (w "/" dest)
        }
        END {
            print n["moved"] + 0 > (w "/n_moved")
            print n["kept"]  + 0 > (w "/n_kept")
            print undated_head + 0 > (w "/n_undated")
            print undatable + 0 > (w "/n_undatable")
        }
    ' "$tb" || { rm -rf "$work"; return 1; }

    for f in head kept moved tail n_moved n_kept; do : > "$work/$f.z"; done
    for f in head kept moved tail; do [ -f "$work/$f" ] || : > "$work/$f"; done
    n_moved=$(cat "$work/n_moved" 2>/dev/null || echo 0)
    n_kept=$(cat "$work/n_kept" 2>/dev/null || echo 0)
    n_undated=$(cat "$work/n_undated" 2>/dev/null || echo 0)
    n_undatable=$(cat "$work/n_undatable" 2>/dev/null || echo 0)

    # Balance check before touching anything. The first hand-rolled archiving in
    # this repo duplicated three entries; a count that does not add up means stop.
    # Count inside the Done section only, by a separate pass: closed items also
    # appear under In progress (sub-items of an open task), and counting the whole
    # file compares two different populations — which is exactly what the first
    # version of this check did, and it refused on a perfectly good taskboard.
    # Same anchor as the splitter above, deliberately: a balance check that counts a
    # different population than the thing it is balancing cannot detect anything.
    total_before=$(awk '
        /^## / { done_sec = ($0 ~ /^## (Done|Завершено)/); next }
        done_sec && /^-[[:space:]]*(\[x\]|✅)/ { n++ }
        END { print n + 0 }
    ' "$tb")
    if [ "$((n_moved + n_kept))" -ne "$total_before" ]; then
        echo "archive: refused — $n_moved moved + $n_kept kept != $total_before in file" >&2
        rm -rf "$work"; return 1
    fi

    echo "archive: $n_moved entries older than $before, $n_kept stay (of $total_before)"
    # Say which of the three states the untouched entries are in. "0 moved" used to be
    # the whole message, and it reads as "nothing is due for archiving" when it can also
    # mean "36 entries are due and I cannot see their dates" — a green answering a
    # different question than the one asked, which is this package's headline defect
    # class. Measured 2026-08-16 on goprofi's taskboard as of 08-07: 5 entries dated in
    # the head, 31 dated only in the body, 1 with no date at all.
    if [ "$n_undated" -gt 0 ]; then
        if [ "$n_undatable" -gt 0 ]; then
            echo "archive: $n_undatable of them carry a date in the BODY, not in the entry line —"
            echo "archive:   not moved on purpose: a body date may be when the task was opened or due,"
            echo "archive:   not when it closed. Recover the real ones with: brain.sh backfill-dates $tb"
        fi
        no_date=$((n_undated - n_undatable))
        [ "$no_date" -gt 0 ] &&
            echo "archive: $no_date carry no date anywhere — date them by hand or with backfill-dates"
    fi
    if [ "$apply" != "--apply" ]; then
        echo "archive: dry-run, nothing written (pass --apply)"
        rm -rf "$work"; return 0
    fi
    if [ "$n_moved" -eq 0 ]; then
        echo "archive: nothing to move"; rm -rf "$work"; return 0
    fi

    cp "$tb" "$work/tb.bak"; cp "$ar" "$work/ar.bak"
    cat "$work/head" "$work/kept" "$work/tail" > "$work/tb.new" || { rm -rf "$work"; return 1; }
    { cat "$ar"; echo; cat "$work/moved"; } > "$work/ar.new" || { rm -rf "$work"; return 1; }

    # Every moved line must exist in the new archive, and the taskboard must have
    # shrunk by exactly what the archive gained.
    moved_lines=$(grep -c . "$work/moved")
    tb_before=$(grep -c . "$tb"); ar_before=$(grep -c . "$ar")
    tb_after=$(grep -c . "$work/tb.new"); ar_after=$(grep -c . "$work/ar.new")
    if [ "$((tb_before - tb_after))" -ne "$moved_lines" ] ||
       [ "$((ar_after - ar_before))" -ne "$moved_lines" ]; then
        echo "archive: refused — line balance off (taskboard -$((tb_before - tb_after)), archive +$((ar_after - ar_before)), moved $moved_lines)" >&2
        rm -rf "$work"; return 1
    fi

    mv "$work/tb.new" "$tb" && mv "$work/ar.new" "$ar"
    echo "archive: moved $n_moved entries ($moved_lines lines) into $(basename "$ar")"
    rm -rf "$work"
}

# ── backfill-dates ───────────────────────────────────────────────────────────
# Recover the closing date of a Done entry from the file's own git history: the date of
# the FIRST commit in which that entry appears closed. `archive` moves dated entries and
# refuses undated ones, so an undated backlog makes the Done threshold unsatisfiable by
# any amount of running `archive` — a permanent violation rather than a standard, which
# this project classifies as a defect in the rule, not in the board.
#
# Why git and not the text: measured 2026-08-16 on the goprofi taskboard as of 08-07,
# 31 of 37 entries carried a date ONLY in the body, and those dates mean different
# things — "Исправлено 07.08" is a closing date, "(заведено 2026-07-31)" is an opening
# one, "со сроком 2026-08-02" is a deadline. Reading them would date entries wrongly and
# silently. The first commit that shows the entry closed is not an opinion.
#
# What the date means, stated because it is not quite "when the work finished": it is
# when the closure was first COMMITTED under the entry's current wording. Re-wording an
# entry after closing it moves its key, so the date found is that of the re-wording. That
# is a bounded error in one direction (never earlier than the real closure) and it beats
# the alternative on offer, which is no date at all — goprofi did exactly this by hand on
# 2026-08-15 for 34 entries, with zero key collisions and zero re-opened items.
#
# The key is the entry head with the marker, dates and markdown noise stripped. ASCII
# operations only: a character class like [^[:alnum:]] behaves differently for Cyrillic
# between gawk, mawk and the BSD awk on macOS, and the vault is full of Cyrillic.
_bf_key_awk='
function bfkey(s) {
    sub(/^-[[:space:]]*(\[x\]|\[ \]|✅)[[:space:]]*/, "", s)
    gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/, "", s)
    gsub(/[`*_]/, "", s)
    gsub(/[[:space:]]+/, " ", s)
    sub(/^ /, "", s); sub(/ $/, "", s)
    # Deliberately NOT truncated. substr() counts bytes in mawk and in the BSD awk, so a
    # cut at N would split a Cyrillic character in half — and a key holding invalid UTF-8
    # is the class that already cost this project three checks in a row, because GNU grep
    # returns zero matches on such input. The whole line costs nothing to hold.
    return s
}'

# Closed entry keys of one taskboard, read from stdin.
_bf_keys() {
    awk "$_bf_key_awk"'
        /^## / { d = ($0 ~ /^## (Done|Завершено)/); next }
        d && /^-[[:space:]]*(\[x\]|✅)/ { k = bfkey($0); if (k != "") print k }
    '
}

backfill_dates() {
    tb="${1:-}"; apply="${2:-}"
    [ -f "$tb" ] || { echo "backfill-dates: no taskboard at '${tb:-}'" >&2; return 1; }
    dir=$(cd "$(dirname "$tb")" && pwd) || return 1
    base=$(basename "$tb")
    if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        # No history means no source of truth. Refuse loudly: "cannot look" and
        # "nothing to find" are different facts, and only one deserves a clean exit.
        echo "backfill-dates: $dir is not a git repository — there is no history to read" >&2
        return 1
    fi
    rel=$(git -C "$dir" ls-files --full-name -- "$base" 2>/dev/null | head -1)
    [ -n "$rel" ] || { echo "backfill-dates: $base is not tracked by git — no history to read" >&2; return 1; }
    # `--full-name` is relative to the repository ROOT, so every git call below has to run
    # from there. Run from the file's own directory instead and the pathspec resolves to
    # `<dir>/<dir>/<file>`, which matches nothing: git exits 0 with an empty log, and the
    # backfill would have reported "no entry is datable" about a file with 156 revisions.
    top=$(git -C "$dir" rev-parse --show-toplevel) || return 1

    work="${TMPDIR:-/tmp}/brain-backfill.$$"
    mkdir -p "$work" || return 1

    # Which entries need a date: closed, in Done, no date in the entry line.
    awk "$_bf_key_awk"'
        /^## / { d = ($0 ~ /^## (Done|Завершено)/); next }
        d && /^-[[:space:]]*(\[x\]|✅)/ && $0 !~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
            k = bfkey($0); if (k != "") print k
        }
    ' "$tb" > "$work/need"
    n_need=$(grep -c . "$work/need")
    if [ "$n_need" -eq 0 ]; then
        echo "backfill-dates: every closed entry already carries a date — nothing to do"
        rm -rf "$work"; return 0
    fi
    # Duplicate keys would each claim the other's date. Refuse, as lint-diff does.
    dup=$(LC_ALL=C sort "$work/need" | uniq -d)
    if [ -n "$dup" ]; then
        echo "backfill-dates: refused — these entries are indistinguishable by their text:" >&2
        printf '%s\n' "$dup" | sed 's/^/  /' >&2
        rm -rf "$work"; return 1
    fi

    # Walk the history oldest first; the first commit showing a key as closed dates it.
    : > "$work/found"
    n_rev=0
    git -C "$top" log --format='%H %ad' --date=short --reverse -- "$rel" > "$work/revs" 2>/dev/null
    while read -r sha day; do
        [ -n "$sha" ] || continue
        n_rev=$((n_rev + 1))
        git -C "$top" show "$sha:$rel" 2>/dev/null | _bf_keys |
            while IFS= read -r k; do
                [ -n "$k" ] || continue
                grep -qxF "$k" <<<"$(cut -f2- "$work/found")" || printf '%s\t%s\n' "$day" "$k" >> "$work/found"
            done
    done < "$work/revs"
    if [ "$n_rev" -eq 0 ]; then
        echo "backfill-dates: git knows no revision of $rel — nothing to read" >&2
        rm -rf "$work"; return 1
    fi

    # Report before writing: which entries got a date, which the history cannot date.
    n_hit=0; n_miss=0
    : > "$work/plan"
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        day=$(awk -F'\t' -v key="$k" '$2 == key { print $1; exit }' "$work/found")
        if [ -n "$day" ]; then
            n_hit=$((n_hit + 1)); printf '%s\t%s\n' "$day" "$k" >> "$work/plan"
        else
            n_miss=$((n_miss + 1))
            printf 'backfill-dates:   no commit shows this entry closed: %s\n' "$(cut -c1-60 <<<"$k")"
        fi
    done < "$work/need"

    echo "backfill-dates: $n_need undated entries, $n_hit datable from $n_rev revisions, $n_miss not"
    if [ "$apply" != "--apply" ]; then
        [ "$n_hit" -gt 0 ] && head -5 "$work/plan" |
            while IFS="$(printf '\t')" read -r day k; do
                printf 'backfill-dates:   %s  %s\n' "$day" "$(cut -c1-60 <<<"$k")"
            done
        echo "backfill-dates: dry-run, nothing written (pass --apply)"
        rm -rf "$work"; return 0
    fi
    if [ "$n_hit" -eq 0 ]; then
        echo "backfill-dates: nothing to write"; rm -rf "$work"; return 0
    fi

    cp "$tb" "$work/tb.bak"
    # -v, not a trailing PLAN=... assignment: an operand assignment is applied when awk
    # reaches that argument, which is AFTER BEGIN has run, so the plan would be read from
    # an empty filename. Caught by awk going fatal; had BEGIN not used it, it would have
    # been a silent no-op instead.
    awk -v PLAN="$work/plan" "$_bf_key_awk"'
        BEGIN { FS = "\t"
                while ((getline line < PLAN) > 0) { split(line, a, "\t"); date[a[2]] = a[1] } }
        /^## / { d = ($0 ~ /^## (Done|Завершено)/) }
        {
            if (d && $0 ~ /^-[[:space:]]*(\[x\]|✅)/ && $0 !~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
                k = bfkey($0)
                if (k in date) {
                    # Insert right after the marker, the position `archive` reads.
                    match($0, /^-[[:space:]]*(\[x\]|✅)/)
                    print substr($0, 1, RLENGTH) " " date[k] substr($0, RLENGTH + 1)
                    next
                }
            }
            print
        }
    ' "$tb" > "$work/tb.new" || { rm -rf "$work"; return 1; }

    # Two safeties, both refusing rather than repairing. (1) the entry count may not
    # change; (2) stripping the inserted dates again must reproduce the original byte
    # for byte — that is what proves nothing but a date was touched.
    c_old=$(awk '/^## /{d=($0 ~ /^## (Done|Завершено)/); next} d && /^-[[:space:]]*(\[x\]|✅)/{n++} END{print n+0}' "$tb")
    c_new=$(awk '/^## /{d=($0 ~ /^## (Done|Завершено)/); next} d && /^-[[:space:]]*(\[x\]|✅)/{n++} END{print n+0}' "$work/tb.new")
    if [ "$c_old" -ne "$c_new" ]; then
        echo "backfill-dates: refused — entry count changed $c_old -> $c_new" >&2
        rm -rf "$work"; return 1
    fi
    sed -E 's/^(-[[:space:]]*(\[x\]|✅)) [0-9]{4}-[0-9]{2}-[0-9]{2}/\1/' "$work/tb.new" > "$work/tb.strip"
    sed -E 's/^(-[[:space:]]*(\[x\]|✅)) [0-9]{4}-[0-9]{2}-[0-9]{2}/\1/' "$tb"           > "$work/tb.orig.strip"
    if ! cmp -s "$work/tb.strip" "$work/tb.orig.strip"; then
        echo "backfill-dates: refused — the rewrite changed something other than a date" >&2
        rm -rf "$work"; return 1
    fi
    cat "$work/tb.new" > "$tb" || { rm -rf "$work"; return 1; }
    echo "backfill-dates: dated $n_hit entries from git history (backup: $work/tb.bak)"
    return 0
}

# ── version ──────────────────────────────────────────────────────────────────
# The installed system used to have no way to state its own version: update.sh
# computed one, printed it to stdout and wrote it nowhere. So no command could
# say "this machine runs 1.3 while the vault is already on 1.6.0 — run
# update.sh", and the drift stayed invisible until something behaved oddly.
brain_version() {
    v="$(dirname "$0")/VERSION"
    if [ -r "$v" ]; then
        head -1 "$v"
    else
        echo "unknown"
    fi
}

# ── rename ───────────────────────────────────────────────────────────────────
# Renames a note and repoints every [[wikilink]] to it. This exists because
# `obsidian move` — the one mutating CLI call the package used to prescribe — was
# measured on 2026-08-04 doing three things nobody asked for. It wrote
# `"alwaysUpdateLinks": true` into the vault's own .obsidian/app.json; it updated no
# link at the time of the call (git status right after showed only the note itself);
# and minutes later, while the session was editing those files, the GUI rewrote their
# backlinks from its own cached copy, at offsets valid for the pre-edit text — 8
# corrupted spots across 6 files, exit 0, nothing on stderr. A verification placed
# right after a mutating call cannot see damage that arrives afterwards, which is why
# the answer is not a better guard but no CLI write at all.
#
# Two lines this draws, both learned from that incident:
#   * A POINTER is updated, a QUOTATION is not. `[[name]]` in a session log points at a
#     note that still exists under a new name, so repointing keeps the old statement
#     true; `` `wiki/name.md` `` in prose is a record of what was created that day, and
#     rewriting it would falsify history. Measured the same day: the only mention of the
#     renamed note in sessions/ was inline code, which is exactly why `obsidian
#     unresolved` never flagged it.
#   * The target's LAST PATH COMPONENT must match in full. A substring replace renames
#     `note` inside `note-two`; the scan below compares components, never text.
#
# The code-vs-prose state machine here is the same three rules as `_lc_strip` inside
# lint-collect (fence toggles, blank line resets, backticks split the line) — if you
# change one, change the other; preflight 39 asserts both still carry all three.
rename_note() {
    vault="${1:-}"; old_rel="${2:-}"; new_rel="${3:-}"; apply="${4:-}"
    [ -n "$vault" ] && [ -n "$old_rel" ] && [ -n "$new_rel" ] || {
        echo "rename: need <vault> <old-relative-path> <new-relative-path> [--apply]" >&2; return 1; }
    [ -d "$vault" ] || { echo "rename: no vault at $vault" >&2; return 1; }
    case "$old_rel" in /*|*..*) echo "rename: give a path relative to the vault, got '$old_rel'" >&2; return 1 ;; esac
    case "$new_rel" in /*|*..*) echo "rename: give a path relative to the vault, got '$new_rel'" >&2; return 1 ;; esac
    [ -f "$vault/$old_rel" ] || { echo "rename: no file at $old_rel" >&2; return 1; }
    [ -e "$vault/$new_rel" ] && { echo "rename: $new_rel already exists" >&2; return 1; }

    old_base=$(basename "$old_rel" .md)
    new_base=$(basename "$new_rel" .md)
    [ "$old_base" = "$new_base" ] && { echo "rename: the basename does not change — nothing to repoint" >&2; return 1; }

    # A backslash in a basename is refused rather than handled, because the value travels
    # into awk through `-v`, and POSIX `awk -v` runs escape processing on the VALUE. Both
    # directions are silent-wrong-answer, measured 2026-08-04: renaming *to* `tab\there`
    # writes that name to disk while rewriting every link to `[[tab<TAB>here]]` and
    # reporting success — every link broken, nothing said; renaming *from* a name that
    # already carries one yields an OLD matching nothing, so the file moves and zero links
    # are repointed, again reporting success. Passing the values through `ENVIRON[]`
    # instead would handle it, but a backslash in a note name is not a case worth
    # supporting — refusing states that, and a refusal is loud.
    case "$old_base$new_base" in
        *\\*) echo "rename: a backslash in a note name is not supported (awk -v would reinterpret it); rename the file by hand" >&2; return 1 ;;
    esac

    # Read-time uniqueness: a bare [[link]] resolves to the first shortest-path match,
    # so a basename that already exists elsewhere makes every link to it ambiguous the
    # moment this one lands. Refuse rather than create the class the lint hunts for.
    # No -type f here on purpose, unlike the rewrite loop below: this asks whether the
    # NAME is taken, and Obsidian resolves a link to a symlink named foo.md just as it
    # does to a regular file. Narrowing this to regular files would stop seeing exactly
    # the collision it exists to prevent.
    clash=$(cd "$vault" && find . -name "$new_base.md" -not -path './.git/*' | sed 's|^\./||')
    [ -n "$clash" ] && {
        echo "rename: the basename $new_base is already taken in this vault, links to it would be ambiguous:" >&2
        printf '%s\n' "$clash" | sed 's/^/  /' >&2
        return 1; }

    rn_tmp=$(mktemp -d) || return 1
    touched=0; links=0; quoted=0
    # Read the list through a redirect, never `for f in $(find …)`: word splitting drops
    # every name containing a space, and the run still reports success for the files it
    # did reach. Measured 2026-08-04 on the first fixture that had such a name — the file
    # kept a link to the old name and the summary said 2 files, exit 0. Process
    # substitution rather than a pipe, because the counters below must survive the loop.
    while IFS= read -r f; do
        src="$vault/$f"
        grep -qF "$old_base" "$src" 2>/dev/null || continue
        awk -v OLD="$old_base" -v NEW="$new_base" '
            function firstsep(s,   a, b, c, m) {
                a = index(s, "|"); b = index(s, "#"); c = index(s, "^"); m = 0
                if (a > 0) m = a
                if (b > 0 && (m == 0 || b < m)) m = b
                if (c > 0 && (m == 0 || c < m)) m = c
                return m
            }
            # Compare the last path component in full, never a substring: [[note]] and
            # [[note-two]] differ, and so do [[a/note]] and [[b/note]] only in prefix.
            function retarget(inner,   m, tgt, rest, pre, base, i, p, ext) {
                m = firstsep(inner)
                if (m > 0) { tgt = substr(inner, 1, m - 1); rest = substr(inner, m) }
                else       { tgt = inner; rest = "" }
                pre = ""; base = tgt; i = 0
                while ((p = index(substr(tgt, i + 1), "/")) > 0) i = i + p
                if (i > 0) { pre = substr(tgt, 1, i); base = substr(tgt, i + 1) }
                ext = ""
                if (length(base) > 3 && substr(base, length(base) - 2) == ".md") {
                    ext = ".md"; base = substr(base, 1, length(base) - 3)
                }
                if (base != OLD) return inner
                hits++
                return pre NEW ext rest
            }
            function rewriteseg(s,   out, i, j, inner) {
                out = ""
                while (1) {
                    i = index(s, "[[")
                    if (i == 0) break
                    out = out substr(s, 1, i + 1)
                    s = substr(s, i + 2)
                    j = index(s, "]]")
                    if (j == 0) break          # unterminated: leave the rest untouched
                    inner = substr(s, 1, j - 1)
                    out = out retarget(inner) "]]"
                    s = substr(s, j + 2)
                }
                return out s
            }
            # A quotation is counted, not changed — so a run never claims to have
            # repointed something it deliberately left alone.
            function countquoted(s) { if (index(s, OLD) > 0) quoted++ }
            /^[[:space:]]*```/ { fence = !fence; countquoted($0); print; next }
            fence              { countquoted($0); print; next }
            !NF                { incode = 0; print; next }
            {
                n = split($0, part, "`"); out = ""
                for (i = 1; i <= n; i++) {
                    if (incode) { countquoted(part[i]); out = out part[i] }
                    else        { out = out rewriteseg(part[i]) }
                    if (i < n) { out = out "`"; incode = !incode }
                }
                print out
            }
            END { print hits + 0 " " quoted + 0 > "/dev/stderr" }
        ' "$src" > "$rn_tmp/out" 2>"$rn_tmp/n"
        read -r h q < "$rn_tmp/n"
        quoted=$(( quoted + q ))
        [ "$h" -gt 0 ] || continue
        links=$(( links + h )); touched=$(( touched + 1 ))
        printf '  %s (%s link(s))\n' "$f" "$h"
        [ "$apply" = "--apply" ] && cat "$rn_tmp/out" > "$src"
    # -type f: a symlink named *.md would otherwise be enumerated, and `cat > "$src"`
    # follows it — rewriting the symlink's TARGET instead of the link, silently, and
    # outside the vault when the target points there. A symlink whose target is itself
    # inside the vault loses nothing by being skipped: the target is enumerated on its
    # own and rewritten once.
    done < <(cd "$vault" && find . -type f -name '*.md' -not -path './.git/*' | sed 's|^\./||')
    rm -rf "$rn_tmp"

    if [ "$apply" = "--apply" ]; then
        if git -C "$vault" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "$vault" mv "$old_rel" "$new_rel" 2>/dev/null || mv "$vault/$old_rel" "$vault/$new_rel"
        else
            mv "$vault/$old_rel" "$vault/$new_rel"
        fi
        printf 'rename: %s -> %s, %s link(s) repointed in %s file(s), %s quoted mention(s) left as written\n' \
            "$old_rel" "$new_rel" "$links" "$touched" "$quoted"
    else
        printf 'rename: dry run — would move %s -> %s and repoint %s link(s) in %s file(s); %s quoted mention(s) stay as written (pass --apply)\n' \
            "$old_rel" "$new_rel" "$links" "$touched" "$quoted"
    fi
}

# ── obsidian-available ───────────────────────────────────────────────────────
# Electron keeps a SingletonLock symlink in its userData dir while it runs — on
# every OS. Test it with -L, not -e: the link deliberately points at a target
# that does not exist, so -e reads false even while Obsidian is up.
# Never use `pgrep -f obsidian` here: -f matches the full command line of every
# process, including the shell running this guard, whose own invocation text
# contains the word — a guaranteed false positive that then cold-starts the GUI.
# Comparing `vault info=name` to the vault we mean is the point: a zero exit code
# only proves *some* vault is open, and every CLI path is relative to that one,
# so with another vault switched on in the GUI a write lands there, silently.
obsidian_available() {
    vault="${1:-}"
    [ -n "$vault" ] || return 1
    command -v obsidian >/dev/null 2>&1 || return 1
    { [ -L "$HOME/Library/Application Support/obsidian/SingletonLock" ] ||
      [ -L "$HOME/.config/obsidian/SingletonLock" ]; } || return 1
    [ "$(_timeout 2 obsidian vault info=name 2>/dev/null)" = "$(basename "$vault")" ]
}

# ── vault-sync ───────────────────────────────────────────────────────────────
# The vault is shared across machines and several of its files are append-only
# registries that every session on every machine edits (00-system/index.md,
# 00-system/connections.md, each project's _PROJECT.md). Writing on top of a
# stale checkout conflicts at push time by construction, in exactly those files;
# pull first and the same write is a fast-forward.
vault_sync() {
    vault="${1:-}"
    if [ -z "$vault" ] || [ ! -d "$vault" ]; then
        echo "vault-sync: no vault at '${vault:-}'" >&2
        return 1
    fi
    # A local-only vault is a supported setup — skip silently, never `git init`
    # or add a remote on the user's behalf.
    git -C "$vault" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "sync skipped: not a git repo"; return 0; }
    remotes=$(git -C "$vault" remote)
    [ -n "$remotes" ] || {
        echo "sync skipped: no remote"; return 0; }

    out=$(_timeout 30 git -C "$vault" pull --rebase --autostash 2>&1)
    rc=$?

    # Last *non-empty* line: git pads its output, and a warning whose reason is a
    # blank string tells the session nothing about why the sync did not happen.
    last=$(echo "$out" | grep -v '^[[:space:]]*$' | tail -1)
    [ -n "$last" ] || last="git exited $rc with no output (timeout?)"

    if [ $rc -eq 0 ]; then
        echo "$last"
        return 0
    fi
    # Mid-rebase means the conflict must stop the write entirely: writing into a
    # tree that is mid-rebase mixes two sessions into one unreviewable diff and
    # lands conflict markers inside the notes themselves.
    if [ -d "$vault/.git/rebase-merge" ] || [ -d "$vault/.git/rebase-apply" ]; then
        echo "CONFLICT: rebase stopped, vault is mid-rebase — write nothing" >&2
        # Order matters: `>&2` first (fd1 := current fd2), then silence fd2.
        # Written `2>/dev/null >&2` the list would be copied into the already
        # redirected fd2 — i.e. into /dev/null — and vanish without a trace.
        git -C "$vault" diff --name-only --diff-filter=U >&2 2>/dev/null
        return 3
    fi
    # Anything else (offline, DNS, auth, timeout) must not block the save: an
    # unsaved session is a worse loss than a deferred sync, and the push at the
    # end surfaces the divergence anyway.
    echo "WARN: vault sync failed, proceeding unsynced — $last" >&2
    return 2
}

# ── _timeout: the tool is not guaranteed to exist ────────────────────────────
# `timeout` is GNU coreutils. Stock macOS does not ship it — one of the two declared
# target machines, and every stranger who installs this package. Measured 2026-08-19 on a
# PATH without it: `vault-sync` never ran `git pull` at all, rc=127 fell into the
# catch-all branch, and the command reported "remote unreachable → warn and keep going".
# So every save, lint and init on such a machine works from a stale checkout forever,
# blaming the network — the exact failure the sync step exists to prevent, wearing the
# costume of a handled error.
#
# This is the class CLAUDE.md already records for `date`, `stat` and `sed`: a command name
# does not guarantee the tool. `date` got a fallback; `timeout` had none, and no check was
# looking, because check 20 scans for non-portable FLAGS and `timeout` is a whole command.
#
# Order: coreutils `timeout`, Homebrew's `gtimeout`, then a shell implementation — the
# watchdog is a background subshell that TERMs the job, which is all we need here (kill
# the pull, keep the session). The shell branch returns the job's own status, or 124 when
# it was killed, matching coreutils so the callers need no special case.
_timeout() {
    _to_secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_to_secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$_to_secs" "$@"
    else
        "$@" &
        _to_job=$!
        ( sleep "$_to_secs"; kill -TERM "$_to_job" 2>/dev/null ) &
        _to_watch=$!
        wait "$_to_job" 2>/dev/null; _to_rc=$?
        kill -TERM "$_to_watch" 2>/dev/null
        wait "$_to_watch" 2>/dev/null
        # 143 = TERM. coreutils reports a timed-out command as 124; match that, so a
        # caller cannot tell the branches apart by exit code alone.
        [ "$_to_rc" -eq 143 ] && _to_rc=124
        return "$_to_rc"
    fi
}

# ── stamp-updated ────────────────────────────────────────────────────────────
# Never `obsidian property:set`: it does not edit the field it is given, it
# parses the whole frontmatter and re-serializes it — quotes stripped, inline
# lists expanded to block form, `007` reinterpreted as `7`. No warning, exit 0.
# This touches one line and cannot reformat anything else.
stamp_field() {
    file="${1:-}"
    key="${2:-}"
    val="${3:-}"
    if [ ! -f "$file" ]; then
        echo "stamp-field: no such file: ${file:-}" >&2
        return 1
    fi
    if [ -z "$key" ] || [ -z "$val" ]; then
        echo "stamp-field: need <file> <key> <value>" >&2
        return 1
    fi
    case "$key" in
        *[!A-Za-z0-9_-]*) echo "stamp-field: refusing odd key '$key'" >&2; return 1 ;;
    esac
    [ "$(head -1 "$file")" = "---" ] || {
        echo "stamp-field: $file has no frontmatter block" >&2; return 1; }
    # And the block must CLOSE. Without a closing `---` the awk below never sets
    # `done_fm`, so its "a line starting with `key:`" rule applies to the WHOLE file and
    # every body line beginning with the key is replaced by the stamp. Measured
    # 2026-08-19 on a fixture: a note whose body carried `updated: this is prose` lost
    # that line, exit 0, with the expected `updated: <date>` printed as if all was well.
    # This input class is not hypothetical — `lint-collect` reports `frontmatter: block
    # not terminated`, so the vault is known to contain it. The `[ ! -s "$tmp" ]` guard
    # below cannot see it: the result is not empty, only wrong.
    awk 'NR > 1 && /^---[[:space:]]*$/ { found = 1; exit } END { exit !found }' "$file" || {
        echo "stamp-field: $file has an unterminated frontmatter block — refusing" >&2
        return 1; }

    tmp="$file.brain-tmp.$$"
    awk -v k="$key" -v d="$val" '
        NR == 1 { print; next }
        !done_fm && /^---[[:space:]]*$/ {
            if (!seen) { print k ": " d }           # key absent -> add it
            done_fm = 1; print; next
        }
        !done_fm && index($0, k ":") == 1 { print k ": " d; seen = 1; next }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Refuse to install a result that lost the frontmatter or the file body.
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"; echo "stamp-field: refused, result was empty" >&2; return 1
    fi
    mv "$tmp" "$file"
    grep -m1 "^$key:" "$file"
}

# ── sweep-closed ─────────────────────────────────────────────────────────────
# `archive` moves Done into the archive note. That is the wrong end of the file:
# the threshold that keeps firing is `## In progress`, and the tool never looked
# there. Same distortion already fixed twice — the Done counter that read the whole
# file, and the `_PROJECT.md` budget that summed prose with link lists. Measure and
# move the part that hurts.
#
# What hurts, measured 2026-08-04 across seven projects: not sections. Zero `###`
# sections under In progress are closed outright — the first version of this was
# going to move whole sections and would have moved nothing anywhere. The weight is
# in single sections mixing both states: `goprofi-voronka` carries one of 1073 lines
# holding 42 closed items and 40 open ones, titled CLOSED. So the unit is the item:
# closed top-level items with their bodies move to Done, open ones stay.
# Effect at the time of writing: 346 -> 218 lines here (under the 300 threshold),
# 1074 -> 701 in goprofi — not enough there alone, and said rather than rounded up.
#
# Why the threshold matters at all: an In progress section a session cannot hold in
# context gets appended to blind. Measured 2026-07-31 in goprofi — a task was entered
# twice because the first copy sat below the chunk that had been read.
#
# A closed SUB-item never moves on its own. Its text usually explains the open parent
# it sits under, and that is the same reason `archive` must never touch Backlog.
#
# The safety property is stronger than archive's and simpler to state: the result is a
# permutation of the input. Same number of lines, same multiset of lines, nothing
# written that was not there — including no generated heading for the moved block.
sweep_closed() {
    tb="${1:-}"; apply="${2:-}"
    [ -f "$tb" ] || { echo "sweep-closed: no taskboard at '${tb:-}'" >&2; return 1; }
    grep -qE '^## (Done|Завершено)' "$tb" || {
        echo "sweep-closed: no Done section in $tb — nowhere to move to" >&2; return 1; }
    grep -qE '^## .*(In progress|В работе)' "$tb" || {
        echo "sweep-closed: no In progress section in $tb — nothing to sweep" >&2; return 1; }

    work="${TMPDIR:-/tmp}/brain-sweep.$$"
    mkdir -p "$work" || return 1
    awk -v w="$work" '
        BEGIN { part = "pre"; state = "" }
        function flush() { state = "" }
        /^## / {
            flush()
            if ($0 ~ /In progress|В работе/) { print > (w "/pre"); part = "keep"; next }
            if (part == "keep") part = "post_head"
            if (part == "post_head" && $0 ~ /^## (Done|Завершено)/) {
                print > (w "/post_head"); part = "post_tail"; next
            }
        }
        part != "keep" { print > (w "/" part); next }
        # inside In progress: classify top-level items only (column 0)
        /^- \[x\]|^- ✅/ { state = "moved"; n_moved++; print > (w "/moved"); next }
        /^- \[ \]/       { state = "keep";  n_kept++;  print > (w "/keep");  next }
        /^#+[[:space:]]/ { flush(); print > (w "/keep"); next }
        # A column-0 list marker that is NOT one of the two recognised checkbox forms
        # starts a NEW top-level item, and nothing here proves it closed — so it stays,
        # and the previous state stops leaking into it. Until 2026-08-19 such a line fell
        # through to the inheritance rule below: a fixture whose board carried
        # `- Note: an open reminder with no checkbox` after a closed entry filed that
        # reminder under `## Done`, exit 0, reporting "1 closed items -> Done". The
        # permutation and line-count safeties cannot see it — the result IS a permutation,
        # only of the wrong partition. Not counted as a kept ENTRY: the numbers in the
        # report are about checkbox items, and inflating them would trade one wrong number
        # for another.
        # NOTE for editors: this awk program is single-quoted, so no apostrophes here.
        /^[-*+][[:space:]]/ || /^[0-9]+[.)][[:space:]]/ {
            state = "keep"; print > (w "/keep"); next
        }
        { print > (w "/" (state == "moved" ? "moved" : "keep")) }
        END { print n_moved + 0 > (w "/n_moved"); print n_kept + 0 > (w "/n_kept") }
    ' "$tb" || { rm -rf "$work"; return 1; }

    for f in pre keep moved post_head post_tail; do [ -f "$work/$f" ] || : > "$work/$f"; done
    n_moved=$(cat "$work/n_moved" 2>/dev/null || echo 0)
    n_kept=$(cat "$work/n_kept" 2>/dev/null || echo 0)
    # `grep -c ''` prints 0 AND exits 1 on an empty file, so `|| echo 0` appended a SECOND
    # zero and the report read `(0\n0 lines)`. awk gives the count with a zero exit, so the
    # fallback that produced the defect is not needed at all. Found 2026-08-17 by reading
    # the tool's own output during a save.
    moved_lines=$(awk 'END { print NR }' "$work/moved")

    if [ ! -s "$work/post_head" ]; then
        echo "sweep-closed: refused — Done heading not found while splitting" >&2
        rm -rf "$work"; return 1
    fi
    echo "sweep-closed: $n_moved closed items ($moved_lines lines) -> Done, $n_kept open ones stay"
    # Say what this move does NOT solve. `archive` never moves an undated entry — that
    # is deliberate, it cannot place what it cannot date — and In progress items were
    # historically written without one. So a sweep can put the taskboard's Done count
    # over its own threshold with entries no later step can take away, and without this
    # line the next run would report that as new debt of unknown origin. Measured here
    # 2026-08-04: of 30 swept items 24 carried no date, Done went 11 -> 41, and
    # `archive --before` could take only 6.
    if [ "$n_moved" -gt 0 ]; then
        # No `|| echo 0` here: grep -c always prints a count and exits 1 when that
        # count is zero, so the fallback would append a second line and the arithmetic
        # below would fail on a two-line value. Caught by check 26 on a dateless fixture.
        n_dated=$(grep -cE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "$work/moved" 2>/dev/null)
        n_undated=$((n_moved - ${n_dated:-0}))
        if [ "$n_undated" -gt 0 ]; then
            echo "sweep-closed: $n_undated of them carry no date — archive cannot move those, they stay in Done"
            # Where that date used to be: the item often has none because it sat in
            # the section HEADING, and headings are not moved. So the sweep does not
            # merely leave an item undated — it separates it from the only date it
            # ever had. That has to be said BEFORE the loss, not by the next lint.
            # Measured 2026-08-04 on this project's own taskboard: 33 of 35 entries
            # in Done carried no date, and archive could take 2.
            dated_h=$(awk '
                /^## / { inprog = ($0 ~ /In progress|В работе/); h = ""; next }
                !inprog { next }
                /^### / { h = $0; next }
                h != "" && /^-[[:space:]]*(\[x\]|✅)/ && $0 !~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
                    if (h ~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[0-9][0-9]\.[0-9][0-9]/) seen[h] = 1
                }
                END { for (k in seen) print k }
            ' "$tb")
            if [ -n "$dated_h" ]; then
                echo "sweep-closed: their date sits in the heading, and headings are not moved —"
                printf '%s\n' "$dated_h" | sed 's/^/sweep-closed:   /'
                echo "sweep-closed:   moving them separates the items from the only date they have."
                echo "sweep-closed:   Date the items themselves BEFORE moving, or archive can never take them"
            fi
        fi

        # A heading is not moved — only items are — so a heading whose own text is a
        # closure claim can end up standing over the open items that stayed. The file
        # loses nothing (this is a permutation), but it starts asserting something
        # false, and a taskboard is read by its headings first.
        # Measured 2026-08-04 in goprofi-voronka: one `### CLOSED 03.08 …` section
        # of 1073 lines held 42 closed items and 40 open ones. Sweeping it would have
        # left "CLOSED" as the title of forty open tasks. That is not a defect of the
        # sweep, it is bookkeeping that predates it — but the sweep is what makes it
        # visible, so the sweep is what has to say it.
        awk '
            /^## / { inprog = ($0 ~ /In progress|В работе/); h = ""; next }
            !inprog { next }
            /^### / { h = $0; open = 0; next }
            h != "" && /^- \[ \]/ { if (open++ == 0) lying[h] = 1 }
            END { for (k in lying) if (k ~ /✅|ЗАКРЫТО|DONE|CLOSED|ЗАВЕРШ/) print k }
        ' "$tb" | while IFS= read -r bad; do
            [ -n "$bad" ] || continue
            echo "sweep-closed: WARNING — this heading claims closure but open items remain under it:"
            echo "sweep-closed:   $bad"
            echo "sweep-closed:   the move loses nothing, but this heading becomes false — split the section by hand"
        done
    fi
    if [ "$n_moved" -eq 0 ]; then rm -rf "$work"; return 0; fi
    if [ "$apply" != "--apply" ]; then
        echo "sweep-closed: dry run, nothing written (pass --apply)"
        rm -rf "$work"; return 0
    fi

    cat "$work/pre" "$work/keep" "$work/post_head" "$work/moved" "$work/post_tail" > "$work/new" ||
        { rm -rf "$work"; return 1; }

    # Permutation check, both halves. Line count alone would miss a swap; the sorted
    # multiset alone would miss a duplicate paired with a loss of the same size.
    if [ "$(grep -c '' "$work/new")" -ne "$(grep -c '' "$tb")" ]; then
        echo "sweep-closed: refused — line count changed ($(grep -c '' "$tb") -> $(grep -c '' "$work/new"))" >&2
        rm -rf "$work"; return 1
    fi
    LC_ALL=C sort "$tb" > "$work/a.sorted"; LC_ALL=C sort "$work/new" > "$work/b.sorted"
    if ! cmp -s "$work/a.sorted" "$work/b.sorted"; then
        echo "sweep-closed: refused — the multiset of lines changed, this is not a permutation" >&2
        diff "$work/a.sorted" "$work/b.sorted" | head -6 >&2
        rm -rf "$work"; return 1
    fi

    cp "$tb" "$work/tb.bak"
    mv "$work/new" "$tb" || { rm -rf "$work"; return 1; }
    echo "sweep-closed: moved $n_moved items ($moved_lines lines) into Done"
    rm -rf "$work"
}

# ── budgets ──────────────────────────────────────────────────────────────────
# One implementation, two callers. /brain-lint measures these a day later; /brain-save
# measures them at the moment of writing. A second implementation is exactly how a
# finding becomes something only one of the two can see — the defect this package has
# now met in four separate checks. So the thresholds and the counters live here once,
# and both callers read the same numbers.
#
# Why /brain-save needs them at all: the lint reports an overrun to whoever runs the
# lint, which is a maintenance session, hours or days after the write that caused it.
# Measured 2026-08-03: `_mac/mac-setup` went 51→62 and 28→35 in a save at 22:03 and
# surfaced an hour later on another machine; and in one session this project's own
# `_PROJECT.md` crossed its budget four times through ordinary status edits, each time
# announced only by a lint run by hand. A session cannot be relied on to run that lint,
# so the measurement belongs at the write.
# Three sections, three independent limits — never their sum.
# The sum was the defect. `For future Claude` already had its own limit of 20 and was
# counted again inside the 60; `Последняя сессия` is already governed by "keep the last
# ~5 entries" and was counted again as lines. So two thirds of the budget was regulating
# what another rule already regulated, and the only unregulated section — Current state —
# got whatever was left, which on a busy project was nothing. Measured 2026-08-16 over
# every revision since the budget was introduced: goprofi-voronka was OVER in 66 of 96
# revisions (peak 162) and _arch/dimarch in 11 of 14 (peak 201), while both sit at 58-60
# today because sessions squeeze them there every save. A warning that fires two runs out
# of three is not a warning. This is the same duplicate-signal removal already performed
# once on the taskboard, where a whole-file threshold restated two targeted ones.
# Current state: measured 12-35 across the vault; SKILL.md asks for ~10 and 30 is the
# point past which it is demonstrably a recap rather than a status.
BUDGET_CURRENT=30
# Entries, not lines: the rule was always "keep the last ~5 entries", and the same 5
# entries span 5 lines in one project and 26 in another — lines measure how wordy each
# entry is, which is the author's judgement, not debt.
BUDGET_SESSIONS=5
BUDGET_FFC=20
BUDGET_DONE=20
# Items, not lines — see _budget_prog. 40 open top-level tasks is roughly what the two
# outlier boards exceed and every other board sits far below (next largest: 4).
BUDGET_PROG=40

# ── which findings carry a magnitude ─────────────────────────────────────────
# The delta compares KEYS, so a debt that grows keeps its key and reads as parked.
# Measured 2026-08-26 against the 08-23 baseline: goprofi's In progress went 184 -> 197,
# `wiki-no-sibling:_mac/mac-setup` DOUBLED 2 -> 4, and this project's own board improved
# 70 -> 62 — all four inside `known and unchanged: 29`.
#
# The fix is not "compare the detail". A detail changes on its own: `stale-draft` counts
# days elapsed and grows every night, which would make seven permanent WORSE lines and a
# fifth signal nobody reads — this project has already cut four of those. So the magnitude
# is DECLARED, per finding type, exactly as the lifecycle-document measurement of 08-19
# concluded: a trait must be declared, never inferred. `stale-draft` is the case that
# proves declaration is needed — its detail opens with a number like the counted ones do.
#
# Convention for a counted type: its detail OPENS with the magnitude. Two types were
# rewritten on 2026-08-26 to obey it (`current-state`, `ffc-budget`), which changes their
# detail text only — the key is what the baseline compares, so no delta was fabricated.
# Every type the collector emits must appear in exactly one of these two lists; a new type
# is a red until it is classified, which is what keeps the enumeration derived rather than
# remembered.
LINT_COUNTED="ambiguous-link current-state ffc-budget key-uniformity retelling-no-source session-list taskboard-done taskboard-inprogress wiki-no-backlink wiki-no-links wiki-no-sibling"
# Not counted, and why: `stale-draft` is time elapsed, not debt; `scope-note` is an
# inventory; the rest state a fact that is either true or absent and carry no number.
LINT_UNCOUNTED="decision-legacy decision-ref decision-schema frontmatter map-stale missing-updated project-missing project-unregistered registry-stale scope-note stale-draft stale-project"

# non-blank lines of one '## ' section, heading excluded. Top-level, not nested in
# lint_collect: prose-budget needs the same counter, and a copy would be a second
# implementation of a threshold that must read identically from both callers.
_lc_section() {
    awk -v pat="$2" '/^## /{ p = ($0 ~ pat); next } p && NF' "$1" | grep -c .
}

_budget_current() { _lc_section "$1" '^## (Current state|Статус)'; }
# Entries of the session list: a line that starts with a date. Both heading spellings.
_budget_sessions() {
    awk '/^## / { p = ($0 ~ /^## (Last session|Последняя сессия)/); next }
         p && /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { n++ }
         END { print n + 0 }' "$1"
}
_budget_ffc()   { _lc_section "$1" '^## For future Claude'; }
# Both markers, always: projects write closed items as `- [x]` and as `- ✅`, and a
# counter that knows one reports zero for a project using the other. Count inside Done
# only — a closed sub-item under an open task is not an archivable entry.
_budget_done() {
    awk '/^## / { d = ($0 ~ /^## (Done|Завершено)/); next }
         d && /^-[[:space:]]*(\[x\]|✅)/ { n++ }
         END { print n + 0 }' "$1"
}
# How many Done entries `archive` can actually move: the ones carrying a date in the
# entry line, which is the only place it reads. One implementation, two callers (the lint
# and prose-budget) — the advice "run archive" is worthless when this is 0, and both
# callers have to say the same number or they will disagree about the same board.
_budget_done_dated() {
    awk '/^## / { d = ($0 ~ /^## (Done|Завершено)/); next }
         d && /^-[[:space:]]*(\[x\]|✅)/ && /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { n++ }
         END { print n + 0 }' "$1"
}

# Open top-level items in In progress — ITEMS, not lines.
# Lines were the wrong unit and the complaint came from a live project: goprofi-voronka
# read 1148/300 with 64 genuinely open tasks, ~18 lines each, because that board requires
# every task to carry its measurement and its mechanism. The threshold was therefore
# unreachable without breaking another rule of that project, which by this project's own
# classification makes it a permanent violation rather than a standard. Counting items
# measures the debt (how much is open) instead of the writing style (how well each item is
# justified), and it is comparable between projects that record tasks differently.
# Measured 2026-08-16 across 10 boards: 130, 60, 4, 3, 3, 0, 0, 0, 0, 0 open items against
# 2084, 494, 55, 10, 4, 2, 2, 2, 1, 1 lines — the two projects the line threshold caught
# are exactly the two the item threshold catches, so no signal is lost in the change.
_budget_prog() {
    awk '/^## / { p = ($0 ~ /In progress|В работе/); next }
         p && /^-[[:space:]]*\[ \]/ { n++ }
         END { print n + 0 }' "$1"
}

# prose-budget <_PROJECT.md> [taskboard.md]
#   exit 0 within budget · 2 over budget · 1 could not measure
prose_budget() {
    pm="${1:-}"; tb="${2:-}"
    [ -n "$pm" ] || { echo "prose-budget: need <_PROJECT.md> [taskboard.md]" >&2; return 1; }
    [ -f "$pm" ] || { echo "prose-budget: no such file: $pm" >&2; return 1; }
    over=0
    report() {  # <label> <value> <budget>
        # A non-numeric value means the counter did not run. Without this, `[ "" -gt 60 ]`
        # errors on stderr and falls to the else branch, printing "ok" for a measurement
        # that never happened — the exact false green this command exists to prevent.
        # Hit live while writing it: _lc_section was nested inside lint_collect and
        # unreachable from here, and the first output said ok for both prose sections.
        case "$2" in
            ''|*[!0-9]*) echo "prose-budget: counter '$1' returned no number ('$2') — nothing was measured" >&2
                         over=2; return 1 ;;
        esac
        if [ "$2" -gt "$3" ]; then
            printf 'OVER +%s  %s: %s/%s\n' "$(( $2 - $3 ))" "$1" "$2" "$3"
            over=1
        else
            printf 'ok              %s: %s/%s\n' "$1" "$2" "$3"
        fi
    }
    report "_PROJECT.md Current state" "$(_budget_current "$pm")" "$BUDGET_CURRENT"
    report "_PROJECT.md session list (entries)" "$(_budget_sessions "$pm")" "$BUDGET_SESSIONS"
    report "_PROJECT.md For future Claude" "$(_budget_ffc "$pm")" "$BUDGET_FFC"
    if [ -z "$tb" ]; then
        echo "taskboard.md                       not given — only the _PROJECT.md sections measured"
    elif [ ! -f "$tb" ]; then
        # NOT READ, never silence: "no taskboard" and "no overrun" are different facts.
        echo "taskboard.md                       NOT READ — no file at $tb"
    else
        dn=$(_budget_done "$tb"); dnd=$(_budget_done_dated "$tb")
        report "taskboard Done (entries)" "$dn" "$BUDGET_DONE"
        # Never advise `archive` without saying how much of it archive can reach: the
        # advice was unactionable on every board whose entries are undated, and an
        # instruction the tool cannot carry out devalues the whole block of output.
        if [ "$dn" -gt "$BUDGET_DONE" ]; then
            if [ "$dnd" -eq 0 ]; then
                echo "        of them archive can move: 0 — date them first: brain.sh backfill-dates $tb"
            else
                echo "        of them archive can move: $dnd (the rest carry no date in the entry line)"
            fi
        fi
        report "taskboard In progress (open items)" "$(_budget_prog "$tb")" "$BUDGET_PROG"
    fi
    [ "$over" -eq 2 ] && return 1   # a counter did not run — not the same as "within budget"
    [ "$over" -eq 1 ] && return 2
    return 0
}

# ── claude-md-audit ──────────────────────────────────────────────────────────
# claude-md-audit <CLAUDE.md>
#   exit 0 clean · 2 findings · 1 could not read the file
#
# The rules this measures already existed and were already checked — but only against
# the TEMPLATE `/brain-init` writes (preflight 10, 10b) and the prose of `/brain-save`
# Step 0a. Nothing ever looked at a project CLAUDE.md that already exists, so a file that
# acquired a state section after creation kept it indefinitely. Measured 2026-08-05
# across the live projects: 2 of 7 carry `## Current state`, 3 carry a `Stack` inventory,
# and one of the state sections had drifted to "30 tables" against 45 on disk — exactly
# the failure the rule predicts, found by a human reading the file rather than by any
# check. This is the same lesson as the prose budget: a rule enforced only at creation is
# enforced once, and the file it governs is loaded in full at every session start.
#
# Why it takes the file as an argument instead of finding it: the vault records no path
# to a project's code, and there is no honest way to derive one. Resolving by basename is
# the "resolve by name" class this package has been burned by three times, and guessing a
# root makes the answer depend on which machine runs it — on a machine where the repo is
# not checked out, "absent" and "clean" become the same observation. `/brain-save` runs
# inside the project and already hands `$PWD/CLAUDE.md` to `local-conventions`, so at the
# one moment the check is worth running, the path is a fact rather than a guess.
#
# Deliberately NOT measured: file size. `dimarch` reached 1080 lines and that was the
# visible symptom, but this project's own CLAUDE.md is 648 lines of rules that all belong
# there. Summing legitimate rules with chronicle is the same distortion already removed
# twice — from the `_PROJECT.md` threshold and from the taskboard one. Measure the part
# that hurts: the sections that carry state, not the total.
# Audit ONE file. The public entry point below runs this over every instruction file the
# repository has, because a project's instructions are rarely one file.
_cma_one() {
    f="$1"
    found=0
    # Both spellings, always — a live fleet is mixed, and a pattern that knows one
    # language reports zero for a project using the other.
    st=$(grep -nE '^#{2,4} +(Current state|Статус)' "$f")
    if [ -n "$st" ]; then
        found=1
        printf 'state-section\t%s\n' "$(printf '%s' "$st" | head -1)"
        echo "  state belongs in _PROJECT.md — this file is read in full before the topic is known"
    fi
    iv=$(grep -nE '^#{2,4} +(Stack|Стек)' "$f")
    if [ -n "$iv" ]; then
        found=1
        printf 'inventory-section\t%s\n' "$(printf '%s' "$iv" | head -1)"
        echo "  third copy of what _PROJECT.md and architecture-map.md own — move any"
        echo "  constraint into the rules and delete the section, never update it"
    fi
    # A date is flagged only when it is the SUBJECT of the heading, which is what a
    # chronicle entry looks like — `## 2026-07-25`, `### Session 2026-08-04`,
    # `### ✅ ЗАКРЫТО 03.08`. A date further along is usually a rule stating when it was
    # adopted, which belongs here: measured 2026-08-05, matching any date in a heading
    # flagged `### Где что лежит (разделение введено 2026-07-25)`, a structural heading
    # in excalipoint, while the three-token form left all 7 live files clean.
    dh=$(awk '/^#{2,4} / {
             t = $0; sub(/^#+[[:space:]]*/, "", t)
             n = split(t, w, /[[:space:]]+/); lim = (n < 3) ? n : 3
             for (i = 1; i <= lim; i++)
                 if (w[i] ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}/ ||
                     w[i] ~ /^[0-9]{2}\.[0-9]{2}(\.[0-9]{2,4})?$/) { print FNR ": " $0; next }
         }' "$f")
    if [ -n "$dh" ]; then
        found=1
        printf 'dated-heading\t%s heading(s) led by a date\n' "$(printf '%s\n' "$dh" | grep -c .)"
        printf '%s\n' "$dh" | sed 's/^/  /'
    fi

    [ "$found" -eq 1 ] && return 2
    return 0
}

# claude-md-audit <CLAUDE.md>
#   exit 0 clean · 2 findings · 1 could not read the file
#
# Scope: the file given AND every other CLAUDE.md tracked in the same repository. A
# project's instructions are not one file — measured 2026-08-16 in goprofi-voronka, they
# are four (root 765 lines, backend 645, content 579, infra 200: 2189 lines, 172 KB) and
# only the root one was ever audited, because that is the path /brain-save happens to
# hand over. Three files out of four were watched by nobody. The scope is printed rather
# than assumed — a check that quietly covers less than it claims is the defect this file
# exists for, and "one file was clean" must never be read as "the instructions are clean".
# Size is still deliberately not measured: rules grow legitimately, and this project has
# removed a size threshold twice for exactly that reason.
claude_md_audit() {
    f="${1:-}"
    [ -n "$f" ] || { echo "claude-md-audit: need <CLAUDE.md>" >&2; return 1; }
    # NOT READ, never silence: "no file" and "no findings" are different facts, and only
    # one of them is worth a zero exit.
    [ -f "$f" ] || { echo "claude-md-audit: no such file: $f" >&2; return 1; }

    # Canonicalise before comparing: `git rev-parse --show-toplevel` resolves symlinks,
    # so where /tmp and /var are symlinks (macOS) the given path and the path git prints
    # name one file in two spellings, and the string compare below counts it twice.
    dir=$(cd "$(dirname "$f")" && pwd -P) || return 1
    f="$dir/$(basename "$f")"
    files="$f"
    if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
        top=$(git -C "$dir" rev-parse --show-toplevel)
        # Tracked files only: an untracked CLAUDE.md in someone's scratch directory is not
        # part of the project's instructions. `ls-files` prints paths from the root.
        others=$(git -C "$top" ls-files -- '*CLAUDE.md' 'CLAUDE.md' 2>/dev/null |
                 while IFS= read -r rel; do
                     [ -f "$top/$rel" ] || continue
                     [ "$top/$rel" = "$f" ] || echo "$top/$rel"
                 done)
        [ -n "$others" ] && files="$f
$others"
    fi
    n_files=$(grep -c . <<<"$files")
    n_lines=0
    while IFS= read -r one; do
        [ -n "$one" ] || continue
        n_lines=$(( n_lines + $(grep -c '' "$one") ))
    done <<<"$files"
    printf 'scope\t%s instruction file(s), %s lines loaded at session start\n' "$n_files" "$n_lines"

    rc=0
    while IFS= read -r one; do
        [ -n "$one" ] || continue
        out=$(_cma_one "$one"); one_rc=$?
        if [ "$one_rc" -eq 2 ]; then
            rc=2
            printf '%s:
' "${one#$(dirname "$f")/}"
            printf '%s
' "$out" | sed 's/^/  /'
        fi
    done <<<"$files"
    [ "$rc" -eq 0 ] &&
        echo "ok  no state section, no inventory copy and no dated chronicle in any of them"
    return "$rc"
}

# ── vault-language ───────────────────────────────────────────────────────────
# What language this vault's owner works in, so templates write headings they can read.
#
# The key has been spelled four ways across the package's own history — `Language:`,
# `Working language:`, `Язык работы:` — and the live vault carries a fourth variant with
# both languages in one value ("Russian in chat, English in code and commits"). So this
# does NOT normalise to a token: it prints the raw value and lets the session judge.
# Deterministic extraction belongs here, the judgement belongs in the prompt — and a
# value naming two languages for two purposes is exactly the judgement a token would
# destroy.
#
# Distinguishes "no such file" from "no such key": the first means the profile was never
# set up and the session should say so, the second means the owner never answered. Only
# one of those is fixed by asking them.
vault_language() {
    vault="${1:-}"
    [ -n "$vault" ] || { echo "vault-language: need <vault>" >&2; return 1; }
    cf="$vault/00-shared/CRITICAL_FACTS.md"
    if [ ! -f "$cf" ]; then
        echo "vault-language: NOT READ — no $cf" >&2
        return 1
    fi
    val=$(awk '
        /^[[:space:]]*(Working language|Language|Язык работы)[[:space:]]*:/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 != "" && $0 !~ /^\(/) { print; exit }
        }' "$cf")
    if [ -z "$val" ]; then
        echo "vault-language: key present but unanswered (or absent) in $cf" >&2
        return 2
    fi
    printf '%s\n' "$val"
}

# ── local-conventions ────────────────────────────────────────────────────────
# Which frontmatter keys THIS project requires beyond the package's template.
#
# Why it is code now: it was a fenced block in /brain-save Step 0c and both of its
# halves were broken in ways nothing could report. The CLAUDE.md half grepped
# "$PROJECT_CLAUDE_MD" — a variable nothing in this package ever assigns, so grep
# received an empty filename, its error went to /dev/null, and the half that mattered
# most for a *new* project never ran at all. The session-log half globbed
# `<sessions>/`*.md in the session's shell: in zsh an unmatched glob aborts the
# command before any redirection applies, so on a project with no logs yet — exactly
# the case the step exists for — it printed a shell error and no result, exit 0.
#
# Both are the shape this project keeps meeting: the step is present, a check that it
# is present goes green, and it runs on nothing. So this one distinguishes "looked and
# found nothing" from "could not look" in its own output, and fails outright when it
# could read neither source — silence from a step that never ran is indistinguishable
# from a project that has no local conventions, and only one of those is safe to act on.
#
# It reports KEYS only, never values. The session that surfaced this wrote a log
# tagged `zone: root` (it crossed both zones) and, minutes later, a decision note
# tagged `zone: backend` (it was about delivery). A copied value is silently wrong,
# which is worse than an absent field.
_fm_keys() {
    awk '/^---[[:space:]]*$/ { c++; if (c == 2) exit; next }
         c == 1 && /^[A-Za-z_-]+:/ { k = $0; sub(/:.*/, "", k); print k }' "$1"
}

local_conventions() {
    vault="${1:-}"; project="${2:-}"; cmd_md="${3:-./CLAUDE.md}"
    [ -n "$vault" ] && [ -n "$project" ] || {
        echo "local-conventions: need <vault> <project> [claude-md]" >&2; return 1; }
    pdir="$vault/$project"
    [ -d "$pdir" ] || { echo "local-conventions: no such project: $pdir" >&2; return 1; }

    looked=0
    for kind in sessions decisions; do
        case "$kind" in
            sessions)  dir="$pdir/sessions"; pat='*_session.md';  label='session-log' ;;
            decisions) dir="$pdir/wiki";     pat='decision-*.md'; label='decision-note' ;;
        esac
        # find, never a glob: unmatched, a glob is a fatal error in zsh and a literal
        # argument in bash, and neither of those is an empty list.
        latest=""
        [ -d "$dir" ] && latest=$(find "$dir" -maxdepth 1 -type f -name "$pat" | LC_ALL=C sort | tail -1)
        if [ -z "$latest" ]; then
            printf '%s\tnone yet — nothing of this kind written in this project\n' "$label"
            continue
        fi
        keys=$(_fm_keys "$latest" | LC_ALL=C sort -u | tr '\n' ' ')
        keys=${keys% }
        if [ -z "$keys" ]; then
            printf '%s\tNOT READ — %s has no frontmatter block\n' "$label" "$(basename "$latest")"
            continue
        fi
        looked=$((looked + 1))
        printf '%s\t%s (from %s)\n' "$label" "$keys" "$(basename "$latest")"
    done

    if [ -f "$cmd_md" ]; then
        looked=$((looked + 1))
        # Two passes, and the wider one is reported as a count rather than dropped.
        # A rule that requires a key almost always names it with a colon, so the
        # narrow pass carries the signal — but "almost always" is not a licence to
        # cap silently: a rule phrased without a key would vanish, and a step that
        # quietly sees less than it claims is the defect this whole file exists for.
        # Never grep for a specific key here: `zone:` was hardcoded in the prompt
        # version, which put one project's convention inside a package shipped to
        # everyone, and would still miss any key not named in advance.
        wide=$(grep -nE '(frontmatter|required|обязательн|must include|требует|должн)' "$cmd_md")
        hits=$(printf '%s\n' "$wide" | grep -E '[A-Za-z_-]+:' | head -10)
        n_wide=$(printf '%s\n' "$wide" | grep -c .)
        n_hits=$(printf '%s\n' "$hits" | grep -c .)
        if [ -n "$hits" ]; then
            printf '%s\n' "$hits" | while IFS= read -r line; do
                printf 'claude-md\t%s\n' "$line"
            done
        else
            printf 'claude-md\tno rule naming a frontmatter key in %s\n' "$cmd_md"
        fi
        if [ "$n_wide" -gt "$n_hits" ]; then
            printf 'claude-md\t+%s more line(s) mention frontmatter but name no key — grep %s if a rule looks missing\n' \
                   "$((n_wide - n_hits))" "$cmd_md"
        fi
    else
        printf 'claude-md\tNOT READ — no file at %s\n' "$cmd_md"
    fi

    if [ "$looked" -eq 0 ]; then
        echo "local-conventions: read nothing at all — no session log, no decision note," >&2
        echo "  and no $cmd_md. An empty result here would be indistinguishable from" >&2
        echo "  'this project has no local conventions'. Fix the path and re-run." >&2
        return 1
    fi
}

# ── save-report ──────────────────────────────────────────────────────────────
# What /brain-save actually did, measured on disk instead of recalled from intent.
#
# The defect this exists for, measured 2026-08-16 in goprofi-voronka, twice in one
# session: a save ran EIGHT of its twelve steps and reported success. The four that
# vanished were the ones that leave no visible trace — the version stamp, the local
# conventions lookup, the decision note, the architecture map — and the miss was caught
# by the user noticing the save felt quick, not by anything the command printed. That is
# the package's own headline failure class ("a failure indistinguishable from success")
# occurring inside the package: session saved, commit made, everything green.
#
# Why a template could not fix it: the old Result block listed the lines but asked for no
# numbers, so it was filled from the memory of what the session meant to do. A count has
# to be counted. So the shell reports the facts and the session explains them — the same
# split as `archive` (the model picks the boundary, the shell moves the bytes).
#
# Three verdicts, and the middle one is the point:
#   ok       the step left a trace on disk
#   MISSING  a step that is owed unconditionally left none          -> exit 2
#   ANSWER   a conditional step left none: legitimate, but the session must SAY why
# ANSWER never sets the exit code. A warning that fires on every run stops being read —
# this project has measured that twice (prose-budget's permanent OVER, the Done counter's
# unreachable advice), and a save that ends in a red on the ordinary case would train
# exactly the blindness the report is built to remove.
#
# The premise is stated, not assumed (preflight 19): the report says what it measured
# against, because a clean working tree means "nothing written yet" before the commit and
# "already committed" after it, and those are different facts about the same silence.
_sr_line() {   # <verdict> <label> <detail>
    printf '%-8s %-20s %s\n' "$1" "$2" "$3"
}

# Paths of one kind out of `git status --porcelain -uall` output.
#   want=new  untracked or added · want=mod  tracked and modified · want=any  either
# A rename is reported as `R  old -> new`; the new name is the one that exists.
_sr_sel() {   # <want> <prefix> ; changes on stdin
    awk -v want="$1" -v pfx="$2" '
        length($0) < 4 { next }
        { st = substr($0, 1, 2); p = substr($0, 4)
          i = index(p, " -> "); if (i) p = substr(p, i + 4)
          if (index(p, pfx) != 1) next
          isnew = (st ~ /\?/ || st ~ /A/)
          if (want == "new" && !isnew) next
          if (want == "mod" &&  isnew) next
          print p }'
}

_sr_count() { grep -c . <<<"$1"; }

save_report() {
    vault="${1:-}"; project="${2:-}"
    [ -n "$vault" ] && [ -n "$project" ] || {
        echo "save-report: need <vault> <project>" >&2; return 1; }
    pdir="$vault/$project"
    [ -d "$pdir" ] || { echo "save-report: no such project: $pdir" >&2; return 1; }

    sr_missing=0; sr_answer=0
    verdict() {   # <verdict> <label> <detail>
        case "$1" in
            MISSING) sr_missing=$((sr_missing + 1)) ;;
            ANSWER)  sr_answer=$((sr_answer + 1)) ;;
        esac
        _sr_line "$1" "$2" "$3"
    }

    # ── what "this session" means here, said out loud ────────────────────────
    # `new` means untracked-or-added, which only git can tell. Under mtime every path
    # looks modified, so asking for `new` there would report a freshly written log as
    # absent — a MISSING invented by the measuring mode rather than by the save. Found
    # exactly that way while testing: the log existed, _PROJECT.md was reported updated
    # from the same list, and the log was still called untouched.
    sr_new=new
    if git -C "$vault" rev-parse --git-dir >/dev/null 2>&1; then
        sr_mode=git
        changes=$(git -C "$vault" -c core.quotePath=false status --porcelain -uall 2>/dev/null)
        _sr_line base "working tree" "uncommitted changes in $vault (run BEFORE the commit)"
    else
        # No git: mtime is all there is, and it cannot tell a new file from an edited
        # one. Say so rather than guessing — a vault without git is a supported setup.
        sr_mode=mtime
        sr_new=any
        sr_today=$(date +%Y-%m-%d)
        changes=$(find "$vault" -name '*.md' -not -path '*/.git/*' -newermt "$sr_today 00:00:00" 2>/dev/null |
                  sed "s|^$vault/||; s|^|M  |")
        _sr_line base "mtime" "no git in the vault — files touched today; created vs updated cannot be told apart"
    fi

    # ── 1. session log (Step 1) — owed unconditionally ───────────────────────
    logs=$(_sr_sel "$sr_new" "$project/sessions/" <<<"$changes" | grep '_session\.md$')
    n_logs=$(_sr_count "$logs")
    if [ "$n_logs" -gt 0 ]; then
        verdict ok "session log" "$(printf '%s' "$logs" | tr '\n' ' ')"
    else
        verdict MISSING "session log" "no new file under $project/sessions/ — Step 1 left no trace"
    fi

    # ── 2. wiki notes (Step 2) ───────────────────────────────────────────────
    w_new=$(_sr_sel "$sr_new" "$project/wiki/" <<<"$changes")
    w_mod=$(_sr_sel mod "$project/wiki/" <<<"$changes")
    n_wnew=$(_sr_count "$w_new"); n_wmod=$(_sr_count "$w_mod")
    # Conditional, so zero is ANSWER and not ok. Until 2026-08-19 the verdict was `ok` in
    # both branches — a green line, in the one command written to make a skipped step
    # visible, for the step whose own numbers say nothing happened. Its sibling below
    # (decision notes) already answered zero with ANSWER, and an asymmetry between two
    # conditional steps means one of them is wrong; the rule says which — a conditional
    # step with no trace is usually legitimate and must be answered in words. Answering
    # costs a sentence ("no note was worth writing this session") and buys the difference
    # between that and Step 2 never running.
    if [ "$sr_mode" = mtime ]; then
        if [ "$((n_wnew + n_wmod))" -gt 0 ]; then
            verdict ok "wiki" "$((n_wnew + n_wmod)) notes touched"
        else
            verdict ANSWER "wiki" "no note created or updated — say why in one line"
        fi
    elif [ "$((n_wnew + n_wmod))" -gt 0 ]; then
        verdict ok "wiki" "$n_wnew created, $n_wmod updated"
    else
        verdict ANSWER "wiki" "no note created or updated — say why in one line"
    fi

    # ── 3. decision notes (Step 2b) — conditional, and the one most often skipped ──
    d_new=$(printf '%s\n' "$w_new" | grep '/decision-[^/]*\.md$')
    n_dec=$(_sr_count "$d_new")
    if [ "$n_dec" -gt 0 ]; then
        verdict ok "decision notes" "$(printf '%s' "$d_new" | sed 's|.*/||' | tr '\n' ' ')"
    else
        verdict ANSWER "decision notes" "none created — say whether a decision was made and where it went"
    fi

    # ── 4. brain-version (Step 0b) — owed unconditionally ────────────────────
    # Equality of two strings, never an ordering: nine projects carry the literal `1.3`
    # left by an old template, and `1.3` against `v1.7.0-34-g0ad2e5c` is not a comparison
    # at all (preflight 19). The question here is only "was it re-stamped this save".
    pm="$pdir/_PROJECT.md"
    if [ ! -f "$pm" ]; then
        verdict MISSING "brain-version" "no _PROJECT.md at $pm — nothing to stamp"
    else
        stamped=$(_lc_fm "$pm" brain-version | tr -d '"')
        installed=$(brain_version)
        if [ -z "$installed" ] || [ "$installed" = unknown ]; then
            # Nothing to compare against: this copy was never installed (no VERSION file
            # next to the script — normal when running straight out of the repo). Naming
            # a MISSING here would be a verdict about the project drawn from a fact about
            # the caller, which is the "diagnosis whose premise was never checked" class.
            _sr_line "n/a" "brain-version" "the running copy reports no version — nothing to compare '$stamped' against"
        elif [ -z "$stamped" ]; then
            verdict MISSING "brain-version" "_PROJECT.md carries no brain-version: field; installed is $installed"
        elif [ "$stamped" = "$installed" ]; then
            verdict ok "brain-version" "$stamped"
        else
            # States the difference, never why it exists. The report knows the two values
            # differ; it does NOT know whether Step 0b ran — the stamp is also stale when
            # the package was updated since the last save, which is the normal case for a
            # project not touched today. Saying "Step 0b did not run" is a diagnosis whose
            # premise was never checked, the class preflight 19 exists for. Caught
            # 2026-08-16 by previewing the report against goprofi, where 0b had run fine.
            verdict MISSING "brain-version" "_PROJECT.md says '$stamped', installed is '$installed' — re-stamp it (Step 0b)"
        fi

        # Step 0b stamps TWO fields, and only one of them was ever checked here. Found
        # 2026-08-16 by the owner asking why a save had felt quick: that save had run
        # `stamp-field brain-version` and not `stamp-field updated`, and this report said
        # `ok` twice — once for the version, once for "_PROJECT.md updated", which only
        # means the file changed. On a fixture carrying `updated: 2020-01-01` the report
        # was equally green. Half a step, invisible, inside the very command written to
        # make skipped steps visible. The lint catches it later (stale-project compares
        # the record to the last session); at write time nothing did.
        upd=$(_lc_fm "$pm" updated)
        newest_log=$(printf '%s\n' "$logs" | sed 's|.*/||; s|_.*||' | LC_ALL=C sort | tail -1)
        if [ -z "$upd" ]; then
            verdict MISSING "updated" "_PROJECT.md carries no updated: field"
        elif [ -n "$newest_log" ] &&
             [ "$(printf '%s\n%s\n' "$upd" "$newest_log" | LC_ALL=C sort | head -1)" = "$upd" ] &&
             [ "$upd" != "$newest_log" ]; then
            # sort, never `[ a \< b ]`: that form fails in zsh with "condition expected",
            # and this package does not use a construct it forbids elsewhere just because
            # this file happens to run under bash.
            verdict MISSING "updated" "_PROJECT.md says '$upd', this session's log is '$newest_log' — stamp the date too (Step 0b)"
        else
            _sr_line ok "updated" "$upd"
        fi
    fi

    # ── 5. _PROJECT.md (Step 3) — owed unconditionally ───────────────────────
    if [ -n "$(_sr_sel any "$project/_PROJECT.md" <<<"$changes")" ]; then
        verdict ok "_PROJECT.md" "updated"
    else
        verdict MISSING "_PROJECT.md" "unchanged — Step 3 left no trace"
    fi

    # ── 6. taskboard (Step 4) ────────────────────────────────────────────────
    if [ -n "$(_sr_sel any "$project/taskboard.md" <<<"$changes")" ]; then
        verdict ok "taskboard" "updated"
    elif [ ! -f "$pdir/taskboard.md" ]; then
        verdict ANSWER "taskboard" "no taskboard.md in this project — say whether one is due"
    else
        verdict ANSWER "taskboard" "unchanged — say whether nothing opened, closed or moved"
    fi

    # ── 7. architecture map (Step 5) — owed by code and mixed projects only ──
    ptype=$(_lc_fm "$pm" type)
    amap="$project/architecture-map.md"
    case "$ptype" in
        code|mixed)
            if [ -n "$(_sr_sel any "$amap" <<<"$changes")" ]; then
                verdict ok "architecture map" "updated"
            elif [ ! -f "$vault/$amap" ]; then
                verdict MISSING "architecture map" "type: $ptype and no architecture-map.md exists"
            else
                verdict ANSWER "architecture map" "unchanged (type: $ptype) — say whether the structure moved"
            fi ;;
        "") verdict ANSWER "architecture map" "_PROJECT.md declares no type: — say whether the map applies" ;;
        *)  _sr_line "n/a" "architecture map" "type: $ptype — Step 5 does not apply" ;;
    esac

    # ── 8. index.md (Step 6) — owed WHEN notes were created ──────────────────
    idx_touched=$(_sr_sel any "00-system/index.md" <<<"$changes")
    if [ -n "$idx_touched" ]; then
        verdict ok "index.md" "updated"
    elif [ "$n_wnew" -gt 0 ]; then
        verdict MISSING "index.md" "$n_wnew new notes and no entry in 00-system/index.md — Step 6 left no trace"
    else
        _sr_line "n/a" "index.md" "no new notes to register"
    fi

    # ── 9. connections.md (Step 7) ───────────────────────────────────────────
    if [ -n "$(_sr_sel any "00-system/connections.md" <<<"$changes")" ]; then
        verdict ok "connections.md" "updated"
    else
        verdict ANSWER "connections.md" "unchanged — say whether anything applies to another project"
    fi

    # ── 10. local conventions (Step 0c) ──────────────────────────────────────
    # The step that leaves the least trace of all: it does not write a file, it makes the
    # session write the right keys. So check the RESULT — does the new log carry the keys
    # this project's earlier logs carry? Keys only, never values: the same session wrote
    # `zone: root` on a log and `zone: backend` on a decision note, and a copied value is
    # silently wrong where an absent one is merely missing.
    if [ "$n_logs" -eq 0 ]; then
        _sr_line "n/a" "local conventions" "no new log to check the keys of"
    else
        newlog="$vault/$(printf '%s\n' "$logs" | head -1)"
        conv=$(_conv_keys "$pdir/sessions" '*_session.md' "$newlog")
        if [ -z "$conv" ]; then
            _sr_line "n/a" "local conventions" "fewer than 3 earlier logs — no convention to compare against"
        else
            have=$(_fm_keys_valued "$newlog")
            lack=""
            while read -r k; do
                [ -n "$k" ] || continue
                grep -qxF "$k" <<<"$have" || lack="$lack $k"
            done <<<"$conv"
            if [ -n "$lack" ]; then
                verdict MISSING "local conventions" "the new log lacks the key(s) its predecessors carry:$lack"
            else
                verdict ok "local conventions" "the new log carries every key its predecessors do"
            fi
        fi
    fi

    # ── the line the session cannot skip reading ─────────────────────────────
    if [ "$sr_missing" -gt 0 ]; then
        printf 'save-report: %s step(s) left no trace, %s need a stated answer\n' "$sr_missing" "$sr_answer"
        return 2
    fi
    printf 'save-report: every owed step left a trace, %s need a stated answer\n' "$sr_answer"
    return 0
}

# ── catalog ──────────────────────────────────────────────────────────────────
# A generated index of the vault's notes: what exists, and — for decisions — what is
# still the authority.
#
# Borrowed from the nf-content skill stack (`catalog-records`), where the argument is
# stated plainly: read a compact catalogue and pull only the relevant records, instead
# of reading the base. Our open 🔴 task said the same thing from the other side — there
# is no path from a file to the notes about it, only a grep on a luckily remembered word.
#
# Two things had to change in the borrowing, and they are the reason this is not a copy:
#   * SCALE. Their catalogue indexes 52 records in 265 lines, so reading it whole is
#     cheap. We hold 511 notes (383 of them decisions), and goprofi-voronka alone has
#     220 — an index of everything would cost more than the grep it replaces. So the
#     default is a per-project summary (one line each) and the full list is per project.
#   * OWNERSHIP. Theirs is maintained by a skill and can therefore drift; their own
#     limitation 2.3.2 says it does not re-sync a record edited by hand. Ours is
#     GENERATED on every call and never stored, so it cannot drift — and it is not a
#     second copy of knowledge, which our own rule forbids.
# What it adds over `ls`: a decision's state. 383 decisions exist and some are retired;
# today the only way to know which is to open the file.
_cat_fm() {
    # Print `date<TAB>status<TAB>superseded-by<TAB>corrected-by` of one note, reading the
    # frontmatter only: the first block between the opening and closing `---`.
    awk '
        NR == 1 && $0 != "---" { exit }
        NR > 1 && /^---[[:space:]]*$/ { exit }
        /^date:/         { sub(/^date:[[:space:]]*/, "");         d = $0 }
        /^status:/       { sub(/^status:[[:space:]]*/, "");       s = $0 }
        /^superseded-by:/{ sub(/^superseded-by:[[:space:]]*/, ""); sb = $0 }
        /^corrected-by:/ { sub(/^corrected-by:[[:space:]]*/, ""); cb = $0 }
        END { printf "%s\t%s\t%s\t%s\n", d, s, sb, cb }
    ' "$1" 2>/dev/null
}

catalog() {
    vault="${1:-}"; only="${2:-}"
    [ -d "$vault" ] || { echo "catalog: no vault at '${vault:-}'" >&2; return 1; }
    cd "$vault" || return 1

    projects=$(find . -name '_PROJECT.md' -not -path './.git/*' |
        sed 's|/_PROJECT.md$||; s|^\./||' | LC_ALL=C sort -u)
    # Empty input must fail, never print a clean catalogue: "no projects" and "I could not
    # enumerate them" are different facts and only one deserves an exit 0.
    if [ -z "$projects" ]; then
        echo "catalog: no _PROJECT.md anywhere under $vault — refusing to print an empty catalogue" >&2
        return 1
    fi
    if [ -n "$only" ]; then
        grep -qxFe "$only" <<<"$projects" ||
            { echo "catalog: no project '$only' in $vault" >&2; return 1; }
        projects="$only"
    fi

    if [ -z "$only" ]; then
        printf 'notes\tdecs\tinforce\tretired\tnewest\tproject\n'
        # `while read` over find, never `for f in $(find …)`: a filename with a space would
        # split into two words and the note would be read as two missing files.
        printf '%s\n' "$projects" | while IFS= read -r p; do
            [ -n "$p" ] && [ -d "$p/wiki" ] || continue
            n_all=0; n_dec=0; n_force=0; n_ret=0; dates=""
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                n_all=$((n_all + 1))
                fm=$(_cat_fm "$f")
                d=$(printf '%s' "$fm" | cut -f1); s=$(printf '%s' "$fm" | cut -f2)
                case "$(basename "$f")" in
                    decision-*)
                        n_dec=$((n_dec + 1))
                        case "$s" in
                            superseded|deprecated) n_ret=$((n_ret + 1)) ;;
                            *) n_force=$((n_force + 1)) ;;
                        esac ;;
                esac
                case "$d" in
                    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) dates="$dates$d
" ;;
                esac
            done <<EOF
$(find "$p/wiki" -maxdepth 1 -name '*.md')
EOF
            # Newest date via sort, never `[ "$a" \> "$b" ]` — that form fails in zsh, and
            # this package does not use what it forbids others (taskboard, 2026-08-16).
            newest=$(printf '%s' "$dates" | grep -v '^$' | LC_ALL=C sort -r | head -1)
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$n_all" "$n_dec" "$n_force" "$n_ret" "${newest:-—}" "$p"
        done
        return 0
    fi

    # Per-project index: one line per note, newest first.
    p="$only"
    [ -d "$p/wiki" ] || { echo "catalog: $p has no wiki/ — nothing to index" >&2; return 1; }
    # Counted BEFORE the loop: the loop's output goes through a pipe to sort, so anything
    # it increments lives in a subshell and reads as 0 outside — the same defect that made
    # a prose-budget counter report `ok` for a section it never measured.
    n=$(find "$p/wiki" -maxdepth 1 -name '*.md' | grep -c .)
    if [ "$n" -eq 0 ]; then
        echo "catalog: $p/wiki holds no notes" >&2
        return 1
    fi
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        fm=$(_cat_fm "$f")
        d=$(printf '%s' "$fm" | cut -f1)
        s=$(printf '%s' "$fm" | cut -f2)
        sb=$(printf '%s' "$fm" | cut -f3)
        cb=$(printf '%s' "$fm" | cut -f4)
        base=$(basename "$f" .md)
        state="-"
        case "$base" in
            decision-*)
                state="${s:-?}"
                # A note can be in force AND carry a correction to one of its facts; the
                # marker says "trust it, but read the correction" and must not be lost in
                # a listing, or the reader is misled by exactly the note that was fixed.
                [ -n "$cb" ] && [ "$cb" != "~" ] && state="$state+corrected"
                [ -n "$sb" ] && [ "$sb" != "~" ] && state="${state}→$(basename "$sb" .md)"
                ;;
            *) [ -n "$s" ] && state="$s" ;;
        esac
        printf '%s\t%s\t%s\n' "${d:-0000-00-00}" "$state" "$base"
    done <<EOF | LC_ALL=C sort -r
$(find "$p/wiki" -maxdepth 1 -name '*.md')
EOF
    return 0
}

# ── connections-add ──────────────────────────────────────────────────────────
# Insert one cross-project entry at the TOP of the knowledge-transfers section.
#
# Why the address is code and not an instruction. Step 7 of /brain-save said "add
# entry to connections.md" and gave the entry's format, but never said WHERE in the
# file it goes — so a session appended to the end, and the end of that file was
# inside a heading dated 2026-07-29. Measured 2026-08-17 on the live vault: 89
# August entries, three written that same day, sat under a July heading announcing a
# different topic, while the section a reader opens carried nothing newer than 08-16.
# The heading was wrong about its date, its size and its subject at once, and every
# save made it wronger. A format named in prose leaves "where" to be re-derived by
# every session; this one was re-derived wrongly for three weeks and nothing saw it,
# because appending to a file is never an error.
#
# It writes immediately, with NO --apply, deliberately unlike `archive`,
# `sweep-closed` and `backfill-dates`. Those move existing content and a dry run
# shows what would move; an append has nothing to preview but the line the caller
# just wrote. And a default that does nothing would fail twice here: the session
# reports the connection recorded, then `save-report` reads connections.md as
# unchanged and prints ANSWER — which that same session explains away as "nothing
# crossed into another project". That is the package's headline class, manufactured
# by its own defaults. One appended entry is small and reversible; a silent no-op
# that reads as success is not.
#
# Both section spellings are matched, never switched between: a live vault holds
# `## Перетоки знаний` while install.sh seeds `## Knowledge transfers`, and one run
# has to see both. A matched name is an identifier — new files write the English one.
connections_add() {
    file="${1:-}"; day="${2:-}"
    [ -f "$file" ] || { echo "connections-add: no connections file at '${file:-}'" >&2; return 1; }
    case "$day" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) echo "connections-add: needs a date as YYYY-MM-DD, got '${day:-}'" >&2; return 1 ;;
    esac

    hdr=$(awk '/^## (Перетоки знаний|Knowledge transfers)/ { print FNR; exit }' "$file")
    # Refuse rather than create the section: a file without it is either the wrong
    # file or a vault whose registry was renamed, and appending a fresh heading to
    # either one buries the entry exactly as the defect above did.
    # The message names the English heading only: this file emits English data, and the
    # Russian spelling is matched by the pattern above, not spoken about. Check 36 caught
    # the first draft, which quoted both — a section name is an identifier, but a
    # sentence built around it is speech, and lib/ does not speak.
    [ -n "$hdr" ] ||
        { echo "connections-add: no '## Knowledge transfers' section in $file" >&2; return 1; }

    body=$(cat)
    # An empty entry must fail loudly. "The author had nothing to say" and "the
    # heredoc never reached the command" are different facts, and appending a bare
    # date would record the second as the first.
    [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] ||
        { echo "connections-add: empty entry on stdin — nothing to add" >&2; return 1; }

    work="${TMPDIR:-/tmp}/brain-connadd.$$"
    mkdir -p "$work" || return 1
    printf '%s\n' "$body" | awk -v day="$day" '
        NR == 1 { sub(/^[ \t]+/, ""); sub(/^-[ \t]*/, ""); print "- " day " | " $0; next }
        { sub(/^[ \t]+/, ""); print ($0 == "" ? "" : "  " $0) }
    ' > "$work/entry"
    # A trailing blank inside the entry would double up against the file's own.
    awk 'BEGIN{n=0} {l[n++]=$0} END{while (n>0 && l[n-1]=="") n--; for (i=0;i<n;i++) print l[i]}' \
        "$work/entry" > "$work/entry.trim" && mv "$work/entry.trim" "$work/entry"

    head1=$(sed -n '1p' "$work/entry")
    # `-e` is load-bearing: the pattern starts with "- ", which grep reads as an option
    # otherwise. Caught by the fixture on the first run — the duplicate check reported
    # the error to stderr, added the duplicate anyway and exited 0.
    if grep -qxFe "$head1" "$file"; then
        echo "connections-add: refused — this exact entry is already in $(basename "$file")" >&2
        rm -rf "$work"; return 1
    fi

    n_before=$(grep -c '^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] |' "$file" || true)
    # Insert after the heading, and after the blank line that follows it if there is
    # one, so the result reads the same whether or not the file keeps that blank.
    nextline=$(sed -n "$((hdr + 1))p" "$file")
    at="$hdr"
    [ -z "$(printf '%s' "$nextline" | tr -d '[:space:]')" ] && at=$((hdr + 1))
    awk -v at="$at" -v ins="$work/entry" '
        { print }
        FNR == at {
            if (at == FNR && substr($0, 1, 3) == "## ") print ""
            while ((getline l < ins) > 0) print l
            print ""
        }
    ' "$file" > "$work/out" || { rm -rf "$work"; return 1; }

    n_after=$(grep -c '^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] |' "$work/out" || true)
    if [ "$n_after" -ne "$((n_before + 1))" ]; then
        echo "connections-add: refused — entry count went $n_before -> $n_after, expected one more" >&2
        rm -rf "$work"; return 1
    fi
    # Verify the POSITION, do not just claim it. Found by the negative test on check 46:
    # with the insertion point mutated to the end of the file, this command still printed
    # "added at the top of the section" — a true action carrying a false sentence, which
    # is the one thing a report here must never do.
    first_now=$(grep -m1 -Ee '^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \|' "$work/out")
    if [ "$first_now" != "$head1" ]; then
        echo "connections-add: refused — the entry did not land first; top is: $first_now" >&2
        rm -rf "$work"; return 1
    fi
    cat "$work/out" > "$file" || { rm -rf "$work"; return 1; }
    rm -rf "$work"
    echo "connections-add: added at the top of the section, $n_after entries"
}

# ── lint-collect ─────────────────────────────────────────────────────────────
# Every check /brain-lint used to describe in prose, as code that actually runs.
#
# Why it moved: the prompt's checks were re-implemented from scratch by each
# session, so their false positives differed every run and could not be told from
# findings without reading each one by hand. Measured 2026-08-04 on the soak run:
# a from-scratch implementation of the decision-reference check produced 11
# findings, all 11 false — 9 `supersedes: ~` (YAML null, not a note name), one
# `corrected-by: ../sessions/...` (a relative path, the file is there), and one
# quotation of the legacy form inside a fenced block of the note documenting that
# very bug. Zero real. A step whose output cannot be compared between runs gives
# `lint-diff` nothing to diff.
#
# Output contract: one finding per line, `key<TAB>detail`. The key is stable —
# type plus object, never a changing number — and is what lint-diff compares.
# Keys must be unique; lint-diff refuses a set that repeats one.
#
# READ THIS BEFORE EDITING ANY printf BELOW. The two halves of a finding line are
# governed differently, and only one of them is safe to touch:
#   - the DETAIL (after the tab) is display text. Rewrite it freely, in English —
#     it is data a session renders, never a sentence shown to the owner as written.
#   - the KEY (before the tab) is a contract with `00-system/lint-baseline.txt`,
#     which lives in the vault and is shared across machines. Renaming one emits a
#     GONE for the old name and a NEW for the new one, for a finding that did not
#     change — a fabricated regression on one side and a fabricated fix on the
#     other, in the same run. Dropping a check silently retires every finding it
#     owned, which is indistinguishable from those findings being fixed.
#     So: changing a key is a deliberate act that must be announced to the user and
#     followed by an explicit re-seal, never folded into an unrelated edit.
# The rule was written only in `commands/brain-lint.md` until 2026-08-04 — read by
# the session RUNNING a lint, while keys are renamed by the session editing this
# file. A warning in the wrong file is not a warning.
#
# NOT moved here, deliberately: the full YAML parse. It needs PyYAML, and this
# package promises no external dependencies — `install.sh` ships SKILL.md,
# commands/ and lib/ only. It stays in preflight.sh, where PyYAML is a dev-only
# dependency of the release gate. What survives here is the structural subset
# that needs no parser: an unterminated block, the legacy double-colon form, an
# off-schema `status:`. Findings that leave with the parser: none today — the
# vault has been at 0 invalid blocks since 2026-07-22.
lint_collect() {
    vault="${1:-}"; only=""
    shift 2>/dev/null || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --project) shift; only="${1:-}" ;;
            *) echo "lint-collect: unknown argument '$1'" >&2; return 1 ;;
        esac
        shift
    done
    if [ -z "$vault" ] || [ ! -d "$vault" ]; then
        echo "lint-collect: no vault at '${vault:-}'" >&2
        return 1
    fi
    cd "$vault" || return 1

    # An empty input must fail the check, never print a green. "Found nothing" and
    # "never looked" are different facts and only one of them deserves a pass —
    # this cost two weeks of a blind release gate twice already.
    # LC_ALL=C: the file list determines the order findings are emitted in, and the
    # baseline is a file compared across machines. Byte order is the same everywhere.
    ALL_MD=$(find . -name '*.md' -not -path './.git/*' | LC_ALL=C sort)
    if [ -z "$ALL_MD" ]; then
        echo "lint-collect: no markdown found under '$vault' — refusing to report a clean vault" >&2
        return 1
    fi

    # Scope for the file-level sweeps. Until now --project scoped only the per-project
    # loop, so a project-scoped lint still reported every other project's stale drafts
    # and missing backlinks — measured 2026-08-04: `--project nf-content` returned 12
    # findings about seven other projects. That is not a stricter check, it is a report
    # that does not mean what its header says, and it trains the reader to skim.
    # The one sweep that stays vault-wide is the ambiguous-link one, and by construction:
    # a bare link breaks because a name was duplicated ANYWHERE, so a scoped view of it
    # would produce only a lower bound. That exception is stated where it happens.
    # A scope matching nothing fails, never returns quiet: a typo'd project name would
    # otherwise read as a clean project.
    if [ -n "$only" ]; then
        SCOPED_MD=$(printf '%s\n' "$ALL_MD" | while read -r p; do
            [ "${p#./$only/}" != "$p" ] && echo "$p"
        done)
        if [ -z "$SCOPED_MD" ]; then
            echo "lint-collect: --project '$only' matched no markdown under $vault" >&2
            return 1
        fi
    else
        SCOPED_MD="$ALL_MD"
    fi

    LC_TMP=$(mktemp -d) || return 1
    mkdir -p "$LC_TMP/clean"
    # shellcheck disable=SC2064
    trap "rm -rf '$LC_TMP'" EXIT

    # Portable: GNU date first, BSD date second. Neither -> empty.
    # The BSD branch spells the time out. `date -j -f %Y-%m-%d` fills every field the
    # format does not name from the CURRENT clock, so the same date parses one second
    # later on every call while TODAY stays frozen at the top of the run: measured
    # 2026-08-04 on Darwin, `2026-07-20` was 15 days old at the start of a full
    # lint-collect and 14 days old by the time the loop reached it, and two projects
    # sitting exactly on the 14-day threshold vanished from the output. Exit 0, stderr
    # empty. GNU's `-d` means midnight, so the two implementations also disagreed by a
    # day even without the drift — a key set that differs per machine is precisely the
    # fake NEW/GONE the baseline exists to prevent.
    _lc_epoch() {
        date -d "$1" +%s 2>/dev/null ||
            date -j -f "%Y-%m-%d %H:%M:%S" "$1 00:00:00" +%s 2>/dev/null || true
    }
    # Strip fenced blocks and inline code, keeping the line count intact so a hit's
    # line number still addresses the same line after cleaning.
    #
    # Two things a `sed 's/`[^`]*`//g'` per line gets wrong, both measured on this
    # vault: a fenced block removed with `next` shifts every later line number, and
    # an inline span that *wraps* across a newline leaves its tail looking like
    # prose — line 29 of the bare-wikilink decision note ends a span opened on line
    # 28, so a per-line strip paired the wrong backticks and kept a quoted
    # `[[_PROJECT]]` as if it were a live link. Carrying the in-code flag across
    # lines is what fixes it; sed cannot, being line-oriented by construction.
    _lc_strip() {
        awk '
            /^[[:space:]]*```/ { fence = !fence; print ""; next }
            fence { print ""; next }
            # An inline span cannot cross a blank line in markdown, so reset there.
            # Without the reset a single unpaired backtick anywhere flips the reading
            # of the whole rest of the file: measured on 00-system/connections.md,
            # 831 inline backticks — an odd count — turned two quoted examples on
            # lines 319 and 1413 into "live" links. Bounding the state to a paragraph
            # keeps multi-line spans working and confines the damage to one paragraph.
            !NF { incode = 0; print ""; next }
            {
                n = split($0, part, "`"); out = ""
                for (i = 1; i <= n; i++) {
                    if (!incode) out = out part[i]
                    if (i < n) incode = !incode
                }
                print out
            }' "$1"
    }
    _lc_clean() {  # cached cleaned copy of a file; prints its path
        c="$LC_TMP/clean/$(printf '%s' "$1" | tr '/.' '__')"
        [ -f "$c" ] || _lc_strip "$1" > "$c"
        printf '%s\n' "$c"
    }
    TODAY=$(date +%s)

    # ── inventory ────────────────────────────────────────────────────────────
    # The registry is the authority on what a project is, not the filesystem
    # layout. Measured 2026-08-04: `find -maxdepth 2` sees 6 projects, the
    # registry lists 11, and a hand-built list produced 10 — `nf-content/MWR-Dima`
    # is nested inside another project, so every per-project check had silently
    # skipped it while the file-level sweeps saw it all along. A baseline whose
    # key set depends on how a session happened to enumerate projects reports the
    # difference as a regression.
    REG="00-system/index.md"
    REG_P=""
    [ -f "$REG" ] && REG_P=$(grep -oE '\[\[[^]|]*_PROJECT[^]]*\]\]' "$REG" |
        sed 's/\[\[//; s/\]\]//; s/|.*//; s|/_PROJECT$||' | LC_ALL=C sort -u)
    FS_P=$(find . -name '_PROJECT.md' -not -path './.git/*' |
        sed 's|/_PROJECT.md$||; s|^\./||' | LC_ALL=C sort -u)
    if [ -z "$FS_P" ]; then
        echo "lint-collect: no _PROJECT.md anywhere — refusing to report a clean vault" >&2
        return 1
    fi
    # These lists come from the FILESYSTEM, one path per line, so they are read line by
    # line and never word-split. `for p in $FS_P` split them on spaces and expanded globs:
    # measured 2026-08-19, a project directory named `my project` produced six fabricated
    # keys — project-unregistered, registry-stale and project-missing, twice each, for the
    # halves `my` and `project` — while the vault-wide sweeps in the same run named it
    # correctly, so the report contradicted itself; and a directory named `pj-*` beside
    # `pj-a` emitted the same key twice, which makes `lint-diff` refuse the whole run with
    # "keys are not unique", blaming the key design rather than the filename. The rule
    # about unquoted word-splitting was already written for prompt blocks (preflight 18);
    # nothing was checking `lib/`, where the input is untrusted vault content.
    while IFS= read -r p <&3; do
        [ -n "$p" ] || continue
        grep -qxF "$p" <<<"$REG_P" || \
            printf 'project-unregistered:%s\tin the vault, absent from %s\n' "$p" "$REG"
    done 3<<EOF
$FS_P
EOF
    while IFS= read -r p <&3; do
        [ -n "$p" ] || continue
        [ -f "$p/_PROJECT.md" ] || \
            printf 'registry-stale:%s\tlisted in %s, no such file\n' "$p" "$REG"
    done 3<<EOF
$REG_P
EOF
    PROJECTS="$FS_P"
    [ -n "$only" ] && PROJECTS="$only"

    # ── per project ──────────────────────────────────────────────────────────
    # A project that is not `active` is not held to the freshness rules. The schema is
    # `active` (the default when the field is absent) against anything else — `reference`,
    # `paused`, `archived` all mean the same thing to the tool: no work is expected here,
    # so "no work happened" is not a finding. The distinction between them is for the
    # reader, exactly as with a decision note's status.
    # The exclusion is never silent: excluded projects are named in the output, because a
    # check that quietly looks at less than it claims is the defect this file exists for.
    # Live case that forced this: puzzlebot-voronka is kept as a knowledge source for
    # goprofi-voronka and is deliberately not developed — reporting it as stale every run
    # is noise that cannot be acted on.
    NOT_ACTIVE=""
    while IFS= read -r P <&3; do
        [ -n "$P" ] || continue
        st=$(_lc_fm "$P/_PROJECT.md" status)
        case "$st" in
            ""|active) : ;;
            *) NOT_ACTIVE="$NOT_ACTIVE $P($st)" ;;
        esac
    done 3<<EOF
$PROJECTS
EOF
    [ -n "$NOT_ACTIVE" ] &&
        printf 'scope-note:not-active\tfreshness checks skipped for:%s\n' "$NOT_ACTIVE"

    # ── documents with a lifecycle, which live outside wiki/ and sessions/ ────
    # A brief, an audit request, a verification plan: not a wiki note (it dies when its
    # run closes) and not a session log (it is an instruction, not an account). Nothing
    # watched them. Measured 2026-08-16: two verification briefs stood at `status: open`
    # for twelve days while _PROJECT.md already announced their runs closed; 2026-08-17:
    # the Autopilot brief did the same for two days, and the brief's own text warns
    # against exactly that. A field has to be remembered; that is the whole defect.
    #
    # This is deliberately an INVENTORY, not a threshold. Measured before writing it:
    # the whole vault holds six such documents and five are already in a final state, so
    # a warning would fire on one draft that the baseline already carries — and a brief
    # legitimately stays open for weeks, which makes age the wrong measure (the same
    # reason `stale-project` stopped counting days). Printing the state of each on every
    # lint makes "open while the work is done" visible without inventing a deadline.
    # `scope-note:`-shaped key so the detail can change without a fake NEW/GONE.
    LIFECYCLE=""
    while IFS= read -r P <&3; do
        [ -n "$P" ] || continue
        while IFS= read -r lf; do
            [ -n "$lf" ] || continue
            case "$(basename "$lf")" in
                _PROJECT.md|taskboard.md|architecture-map.md|CLAUDE.md) continue ;;
            esac
            lst=$(_lc_fm "$lf" status)
            [ -n "$lst" ] || continue
            # `accepted`/`stable` mark knowledge, not a process — a concept note carries
            # them and has no lifecycle to report.
            case "$lst" in accepted|stable) continue ;; esac
            lcl=$(_lc_fm "$lf" closed)
            LIFECYCLE="$LIFECYCLE ${lf#./}=$lst${lcl:+@$lcl}"
        done <<EOF
$(find "$P" -maxdepth 2 -name '*.md' -not -path "*/wiki/*" -not -path "*/sessions/*" 2>/dev/null)
EOF
    done 3<<EOF
$PROJECTS
EOF
    [ -n "$LIFECYCLE" ] &&
        printf 'scope-note:lifecycle-docs\tstate is a field, not a location — verify each against the work:%s\n' "$LIFECYCLE"

    while IFS= read -r P <&3; do
        [ -n "$P" ] || continue
        f="$P/_PROJECT.md"
        [ -f "$f" ] || { printf 'project-missing:%s\tno _PROJECT.md\n' "$P"; continue; }
        p_status=$(_lc_fm "$f" status)
        case "$p_status" in ""|active) p_active=1 ;; *) p_active=0 ;; esac

        cur=$(_budget_current "$f")
        sess=$(_budget_sessions "$f")
        ffc=$(_budget_ffc "$f")
        [ "$cur" -gt "$BUDGET_CURRENT" ] && printf 'current-state:%s\t%s lines against ~%s — Current state holds status and open blockers only\n' "$P" "$cur" "$BUDGET_CURRENT"
        [ "$sess" -gt "$BUDGET_SESSIONS" ] && printf 'session-list:%s\t%s entries against ~%s — drop the oldest, the account stays in sessions/\n' "$P" "$sess" "$BUDGET_SESSIONS"
        [ "$ffc" -gt "$BUDGET_FFC" ] && printf 'ffc-budget:%s\t%s lines against ~%s — For future Claude\n' "$P" "$ffc" "$BUDGET_FFC"

        # A bullet in `Current state` that runs three lines or more is no longer a state —
        # it is an account of something, and an account without a `[[link]]` has no owner
        # elsewhere, which is how a recap ends up living in the one file that must not hold
        # recaps ([[decision-project-md-links-not-duplicates-wiki…]]).
        #
        # Length is the discriminator, and that is a measurement rather than taste: asking
        # every bullet for a link reports 16 across the vault and would fire on a one-line
        # status ("1.8.0 in progress, steps 1-4 closed") that legitimately cites nothing;
        # asking only the long ones reports exactly **1** in the whole vault today. Borrowed
        # from nf-content, where the obligation to link is attached to a record TYPE whose
        # purpose is to point at detail rather than restate it, never to every line.
        retell=$(awk '
            /^## (Current state|Статус)/ { f = 1; next }
            /^## / { f = 0 }
            f && /^- / {
                if (n > 0 && lines >= 3 && !haslink) bad++
                n++; lines = 1; haslink = ($0 ~ /\[\[/); next
            }
            f && n > 0 { lines++; if ($0 ~ /\[\[/) haslink = 1 }
            END { if (n > 0 && lines >= 3 && !haslink) bad++; print bad + 0 }
        ' "$f")
        [ "$retell" -gt 0 ] && printf 'retelling-no-source:%s\t%s bullet(s) of 3+ lines carry no [[link]] — an account needs an owner elsewhere\n' "$P" "$retell"

        upd=$(_lc_fm "$f" updated)
        if [ -z "$upd" ]; then
            printf 'missing-updated:%s\t_PROJECT.md has no updated: field\n' "$P"
        else
            us=$(_lc_epoch "$upd")
            if [ -z "$us" ]; then
                echo "lint-collect: cannot parse date '$upd' in $f (no working date(1))" >&2
                return 1
            fi
            # THE RECORD LAGGING THE WORK, not the calendar. This used to fire at 14 days
            # since the last `updated:`, which measures how recently the owner chose to
            # work on a project — not whether anything is wrong with it. Measured
            # 2026-08-16 on the live vault: 7 findings, all noise. Six of those projects
            # are simply not the current priority ("I work by need, not by schedule") and
            # the seventh is kept as a reference source; every one of them had
            # `updated:` exactly equal to the date of its own last session, i.e. every
            # record was correct. A finding nobody can act on trains the reader to skim.
            # What IS worth reporting is the opposite direction: a session was written and
            # the project file was not updated with it — the save skipped Step 0b, or the
            # file was edited by hand. That is the same class `save-report` catches at
            # write time, caught here for every machine and every past save.
            last_s=$(find "$P/sessions" -name '*_session.md' 2>/dev/null |
                     sed 's|.*/||; s|_.*||' | LC_ALL=C sort | tail -1)
            if [ -n "$last_s" ] && [ "$p_active" -eq 1 ]; then
                ls_e=$(_lc_epoch "$last_s")
                if [ -n "$ls_e" ] && [ "$ls_e" -gt "$us" ]; then
                    printf 'stale-project:%s\tlast session %s, _PROJECT.md updated %s — the save did not stamp it\n' \
                        "$P" "$last_s" "$upd"
                fi
            fi
        fi

        tb="$P/taskboard.md"
        if [ -f "$tb" ]; then
            # Both markers, always: projects use `- [x]` and `- ✅` interchangeably
            # and a counter that knows one reports zero for a project using the other.
            # Count inside Done only — a closed sub-item under an open task is not
            # an archivable entry (65 file-wide against 5 in Done, measured).
            dn=$(_budget_done "$tb")
            prog=$(_budget_prog "$tb")
            # The detail names the ACTIONABLE part: archive only moves dated entries,
            # and "archive it" is useless advice when not one entry carries a date.
            dnd=$(_budget_done_dated "$tb")
            [ "$dn" -gt "$BUDGET_DONE" ] && printf 'taskboard-done:%s\t%s closed entries in Done, %s dated — archive can move only those\n' "$P" "$dn" "$dnd"
            [ "$prog" -gt "$BUDGET_PROG" ] && printf 'taskboard-inprogress:%s\t%s open items\n' "$P" "$prog"
        fi

        am="$P/architecture-map.md"
        [ "$p_active" -eq 0 ] && am=""   # not active: no work, so no map drift to report
        if [ -f "$am" ]; then
            mu=$(_lc_fm "$am" updated)
            ls_=$(find "$P/sessions" -maxdepth 1 -name '*_session.md' 2>/dev/null |
                  sed 's|.*/||' | cut -c1-10 | LC_ALL=C sort | tail -1)
            if [ -n "$mu" ] && [ -n "$ls_" ]; then
                a=$(_lc_epoch "$mu"); b=$(_lc_epoch "$ls_")
                [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && \
                    printf 'map-stale:%s\tmap %s against session %s\n' "$P" "$mu" "$ls_"
            fi
        fi

        _lc_keys "$P/sessions" '*.md' "$P/sessions"
        _lc_keys "$P/wiki" 'decision-*.md' "$P/decisions"
    done 3<<EOF
$PROJECTS
EOF

    # ── stale drafts ─────────────────────────────────────────────────────────
    printf '%s\n' "$SCOPED_MD" | grep -v '/raw/' | while read -r p; do
        [ "$(_lc_fm "$p" status)" = "draft" ] || continue
        d=$(_lc_fm "$p" date); [ -n "$d" ] || continue
        ds=$(_lc_epoch "$d"); [ -n "$ds" ] || continue
        days=$(( (TODAY - ds) / 86400 ))
        [ "$days" -gt 14 ] && printf 'stale-draft:%s\t%s days\n' "$(echo "${p#./}" | sed 's|\.md$||')" "$days"
    done

    # ── decision-note schema ─────────────────────────────────────────────────
    # `~` is YAML null, not a filename; a value may be a relative path; and the
    # legacy form is quoted inside the note that documents it. All three produced
    # false positives on the 2026-08-04 soak run — the whole reason this is code.
    # Matched by FILENAME, not by folder: a decision note is a decision note wherever it
    # lives. Measured 2026-08-17 on a fixture — with the old `/wiki/decision-` filter, a
    # note in `00-shared/concepts/` carrying an off-schema status was invisible, while
    # `frontmatter` and `ambiguous-link` (vault-wide sweeps) saw the same folder fine. Zero
    # live instances today (no decision-* outside wiki/), so this closes a gap between the
    # report's claim of "entire vault" and what part of it was actually read, rather than
    # fixing a present defect. `raw/` stays excluded: it is untrusted input, not our record.
    printf '%s\n' "$SCOPED_MD" | grep -Ee '/decision-[^/]*\.md$' | grep -v '/raw/' | while read -r p; do
        st=$(_lc_fm "$p" status)
        case "$st" in
            accepted|superseded|deprecated) ;;
            "") printf 'decision-schema:%s\tno status:\n' "${p#./}" ;;
            *)  printf 'decision-schema:%s\tstatus off-schema: %s\n' "${p#./}" "$st" ;;
        esac
        # legacy one-line form, frontmatter only (a fenced quote of it is not one)
        awk '/^---[[:space:]]*$/ { c++; next } c == 1 && /^status:[[:space:]]*superseded-by:/ { found = 1 }
             END { exit !found }' "$p" && \
            printf 'decision-legacy:%s\tone-line status: superseded-by: — invalid YAML\n' "${p#./}"
        for k in supersedes superseded-by corrected-by; do
            v=$(_lc_fm "$p" "$k")
            case "$v" in ""|"~"|"null"|"[]") continue ;; esac
            v=$(printf '%s' "$v" | sed 's/^\[\[//; s/\]\]$//; s/|.*//; s/\.md$//')
            base=$(printf '%s' "$v" | sed 's|.*/||')
            # Output into a variable, not `find | grep -q .`: under pipefail grep -q
            # exits on the first line, find dies of SIGPIPE with 141, and the pipeline
            # status then says "not found" about a file that exists. It fires exactly
            # where a basename is duplicated — the very class this vault carries
            # (see ambiguous-link).
            hits=$(find . -name "$base.md" -not -path './.git/*')
            [ -n "$hits" ] || \
                printf 'decision-ref:%s\t%s → %s does not exist\n' "${p#./}" "$k" "$v"
        done
    done

    # ── frontmatter structure (no parser needed) ─────────────────────────────
    printf '%s\n' "$SCOPED_MD" | while read -r p; do
        [ "$(head -1 "$p")" = "---" ] || continue
        awk 'NR == 1 { next } /^---[[:space:]]*$/ { ok = 1; exit } END { exit ok }' "$p" && \
            printf 'frontmatter:%s\tblock not terminated\n' "${p#./}"
    done

    # ── ambiguous bare links ─────────────────────────────────────────────────
    # A link breaks by the *existence of a duplicate name anywhere*, so this runs
    # over the whole vault whatever the scope: a name unique when the link was
    # written stops being unique the moment another project reuses the basename,
    # and every already-correct link in the older project turns ambiguous with no
    # edit to it. sessions/ and archive-* are history and are not rewritten.
    printf '%s\n' "$ALL_MD" | sed 's|.*/||; s|\.md$||' | LC_ALL=C sort | uniq -d > "$LC_TMP/dup"
    : > "$LC_TMP/amb"
    while read -r name; do
        [ -n "$name" ] || continue
        grep -rnF --include='*.md' "[[$name]]" . 2>/dev/null |
            grep -v '/sessions/' | grep -v '/archive-' |
            while IFS= read -r hit; do
                hf=${hit%%:*}; rest=${hit#*:}; ln=${rest%%:*}
                # A quoted example inside a note that documents this very bug is not
                # a link. Check the *line*, not the file: this vault explains the bug
                # in prose, so a file almost always contains both forms — a file-wide
                # test passes every hit in it. And never just drop lines containing a
                # backtick: a real bare link and an unrelated backtick share a line
                # often enough (confirmed live in goprofi-voronka/_PROJECT.md).
                grep -qF "[[$name]]" <<<"$(sed -n "${ln}p" "$(_lc_clean "$hf")")" || continue
                echo "${hf#./}" >> "$LC_TMP/amb"
            done
    done < "$LC_TMP/dup"
    # One key per file, count in the detail: the key must be stable, and a per-hit
    # key would repeat — lint-diff refuses a set with duplicate keys.
    LC_ALL=C sort "$LC_TMP/amb" | uniq -c | while read -r n hf; do
        printf 'ambiguous-link:%s\t%s bare links\n' "$hf" "$n"
    done

    # ── links per wiki note ──────────────────────────────────────────────────
    printf '%s\n' "$ALL_MD" | while read -r p; do cat "$(_lc_clean "$p")"; done |
        grep -oE '\[\[[^]|]+' | sed 's/^\[\[//; s|.*/||' | LC_ALL=C sort | uniq -c > "$LC_TMP/inc"
    : > "$LC_TMP/links"
    printf '%s\n' "$SCOPED_MD" | grep '/wiki/' | while read -r p; do
        base=$(basename "$p" .md)
        case "$base" in archive-*) continue ;; esac
        proj=$(printf '%s' "${p#./}" | sed 's|/wiki/.*||')
        tg=$(grep -oE '\[\[[^]|]+' "$(_lc_clean "$p")" | sed 's/^\[\[//')
        sib=$(printf '%s\n' "$tg" | grep -v '_PROJECT$' | grep -c .)
        bl=$(printf '%s\n' "$tg" | grep -c '_PROJECT$')
        if [ "$sib" -eq 0 ] && [ "$bl" -eq 0 ]; then echo "no-links	$proj" >> "$LC_TMP/links"
        elif [ "$bl" -eq 0 ];                   then echo "no-backlink	$proj" >> "$LC_TMP/links"
        elif [ "$sib" -eq 0 ];                  then echo "no-sibling	$proj" >> "$LC_TMP/links"
        fi
    done
    # Counted per project, not per note: 29 one-line fixes are one debt, and a
    # per-note key would rewrite the baseline on every note anyone touches.
    LC_ALL=C sort "$LC_TMP/links" | uniq -c | while read -r n cls proj; do
        case "$cls" in
            no-links)    printf 'wiki-no-links:%s\t%s notes\n' "$proj" "$n" ;;
            no-backlink) printf 'wiki-no-backlink:%s\t%s notes\n' "$proj" "$n" ;;
            no-sibling)  printf 'wiki-no-sibling:%s\t%s notes\n' "$proj" "$n" ;;
        esac
    done
}

# Frontmatter key uniformity within one project. A key counts as a convention
# only when it carries a VALUE in most entries: a key emitted empty by a template
# and filled by nobody is an artefact, not a rule — `supersedes:` is empty in 29
# of 32 cadrika notes, and counting presence alone made the three that lack the
# empty line look like violations. A false finding costs more than a missed one:
# it teaches the reader to skim.
# Value of one frontmatter key, first block only. Top-level, not nested inside
# lint_collect: save-report reads the same fields, and a helper reachable from one caller
# only is how prose-budget once printed "ok" for a measurement that never ran.
_lc_fm() {     # <file> <key>
    # The delimiter is matched with trailing whitespace allowed, everywhere. Until
    # 2026-08-19 five readers used a strict /^---$/ while stamp_field and _fm_keys used the
    # tolerant form, so a CRLF file or a `--- ` line made the strict half see an EMPTY
    # frontmatter. Measured on a fixture: two notes carrying `status: accepted` were
    # reported `decision-schema … no status:` — fabricated keys that go into the shared
    # baseline, and acting on one adds a SECOND status: key to a live note; a genuinely
    # off-schema note (`partially-superseded-by`) was reported as "no status" instead of
    # its real violation; a CRLF note with an unterminated block produced no
    # `frontmatter: block not terminated` finding while its byte-identical LF twin did;
    # and `catalog` listed both as `0000-00-00 ?`, sorting them below everything in an
    # index whose whole claim is "newest first".
    awk -v k="$2" '/^---[[:space:]]*$/ { c++; next }
         c == 1 && index($0, k ":") == 1 {
             sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, "")
             gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' "$1"
}

# The keys of one entry that actually carry a value. One implementation, three callers
# (_lc_keys twice, save-report once): a second copy of "what counts as a filled key"
# would let the lint and the save disagree about the same file.
_fm_keys_valued() {
    awk '/^---[[:space:]]*$/ { c++; next }
         c == 1 && /^[A-Za-z_-]+:/ {
             k = $0; sub(/:.*/, "", k)
             v = $0; sub(/^[A-Za-z_-]+:[[:space:]]*/, "", v)
             gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
             if (v != "" && v != "[]" && v != "\"\"" && v != "~" && v != "null") print k
         }' "$1" | LC_ALL=C sort -u
}

# The keys a project treats as a convention: carried with a value by more than 60% of
# entries of that kind. Same threshold for the lint and for the save, for the same
# reason as above. `exclude` leaves the entry under test out of its own baseline.
_conv_keys() {   # <dir> <pattern> [exclude-file]
    _ck_dir="$1"; _ck_pat="$2"; _ck_skip="${3:-}"
    [ -d "$_ck_dir" ] || return 0
    _ck_files=$(find "$_ck_dir" -maxdepth 1 -name "$_ck_pat" | LC_ALL=C sort)
    [ -n "$_ck_skip" ] && _ck_files=$(grep -vxF "$_ck_skip" <<<"$_ck_files")
    _ck_n=$(grep -c . <<<"$_ck_files")
    [ "$_ck_n" -lt 3 ] && return 0
    printf '%s\n' "$_ck_files" | while read -r f; do
        [ -n "$f" ] && _fm_keys_valued "$f"
    done | LC_ALL=C sort | uniq -c | awk -v n="$_ck_n" '$1 > n * 0.6 { print $2 }'
}

_lc_keys() {
    dir="$1"; pat="$2"; label="$3"
    [ -d "$dir" ] || return 0
    files=$(find "$dir" -maxdepth 1 -name "$pat" | LC_ALL=C sort)  # not ls: it may be a
    n=$(printf '%s\n' "$files" | grep -c .)                # shell function (eza)
    [ "$n" -lt 3 ] && return 0
    kt=$(mktemp); ct=$(mktemp)
    _conv_keys "$dir" "$pat" > "$ct"
    printf '%s\n' "$files" | while read -r f; do
        have=$(_fm_keys_valued "$f")
        while read -r k; do
            [ -n "$k" ] || continue
            grep -qxF "$k" <<<"$have" || echo "$k"
        done < "$ct"
    done | LC_ALL=C sort | uniq -c | while read -r cnt k; do
        printf 'key-uniformity:%s\t%s entries lack %s (of %s)\n' "$label" "$cnt" "$k" "$n"
    done
    rm -f "$kt" "$ct"
}

case "${1:-}" in
    obsidian-available) shift; obsidian_available "${1:-}" ;;
    vault-name)         _timeout 2 obsidian vault info=name 2>/dev/null || true ;;
    rename)             shift; rename_note "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    vault-sync)         shift; vault_sync "${1:-}" ;;
    stamp-field)        shift; stamp_field "${1:-}" "${2:-}" "${3:-}" ;;
    version)            brain_version ;;
    lint-diff)          shift; lint_diff "$@" ;;
    release-check)      shift; release_check "${1:-}" ;;
    local-conventions)  shift; local_conventions "${1:-}" "${2:-}" "${3:-./CLAUDE.md}" ;;
    vault-language)     shift; vault_language "${1:-}" ;;
    prose-budget)       shift; prose_budget "${1:-}" "${2:-}" ;;
    claude-md-audit)    shift; claude_md_audit "${1:-}" ;;
    sweep-closed)       shift; sweep_closed "${1:-}" "${2:-}" ;;
    save-report)        shift; save_report "${1:-}" "${2:-}" ;;
    backfill-dates)     shift; backfill_dates "${1:-}" "${2:-}" ;;
    lint-collect)       shift; lint_collect "$@" ;;
    connections-add)    shift; connections_add "${1:-}" "${2:-}" ;;
    catalog)            shift; cat_v="${1:-}"; cat_p=""
                        shift 2>/dev/null || true
                        while [ $# -gt 0 ]; do
                            case "$1" in
                                --project) shift; cat_p="${1:-}" ;;
                                *) echo "catalog: unknown option '$1'" >&2; exit 64 ;;
                            esac
                            shift
                        done
                        catalog "$cat_v" "$cat_p" ;;
    archive)            shift
                        a_tb="${1:-}"; a_ar="${2:-}"; a_before=""; a_apply=""
                        shift 2 2>/dev/null
                        while [ $# -gt 0 ]; do
                            case "$1" in
                                --before) shift; a_before="${1:-}" ;;
                                --apply)  a_apply="--apply" ;;
                                *) echo "archive: unknown option '$1'" >&2; exit 64 ;;
                            esac
                            shift
                        done
                        archive_done "$a_tb" "$a_ar" "$a_before" "$a_apply" ;;
    -h|--help|help|"")  usage ;;
    *)                  echo "brain.sh: unknown command '$1'" >&2; usage >&2; exit 64 ;;
esac
