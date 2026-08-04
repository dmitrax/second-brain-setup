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
  lint-collect <vault> [--project P]
                               run every mechanical vault check and print each
                               finding as `key<TAB>detail` on stdout. Fails, never
                               prints a green, when its input is empty.
  lint-diff <baseline> [--seal]
                               read findings on stdin (one per line, `key<TAB>detail`),
                               print what is NEW and what is GONE against the baseline,
                               and how many are unchanged. --seal rewrites the baseline.
USAGE
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
    base="${1:-}"; seal="${2:-}"
    [ -n "$base" ] || { echo "lint-diff: need a baseline path" >&2; return 1; }

    cur="${TMPDIR:-/tmp}/brain-lint-cur.$$"
    cat > "$cur"
    # Ключи обязаны быть уникальными: тип + объект. Два разных объекта под одним
    # ключом («stale-draft» на три разных файла) схлопываются, и починка одного из
    # них диффу не видна — ключ остаётся на месте. Поймано на первом же живом
    # baseline, где я сам написал тип без объекта.
    dup=$(cut -f1 "$cur" | sort | uniq -d)
    if [ -n "$dup" ]; then
        echo "lint-diff: ключи не уникальны — добавьте объект в ключ:" >&2
        printf '%s\n' "$dup" | sed 's/^/  /' >&2
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

    cut_keys() { cut -f1 "$1" | sort -u; }
    new_keys="${TMPDIR:-/tmp}/brain-lint-new.$$"
    gone_keys="${TMPDIR:-/tmp}/brain-lint-gone.$$"
    comm -23 <(cut_keys "$cur") <(cut_keys "$base") > "$new_keys"
    comm -13 <(cut_keys "$cur") <(cut_keys "$base") > "$gone_keys"

    n_new=$(grep -c . "$new_keys"); n_gone=$(grep -c . "$gone_keys")
    n_same=$(( $(cut_keys "$cur" | grep -c .) - n_new ))

    if [ "$n_new" -gt 0 ]; then
        echo "NEW since last lint ($n_new):"
        while read -r k; do
            [ -n "$k" ] || continue
            awk -F'\t' -v k="$k" '$1 == k { print "  + " $1 (NF > 1 ? " — " $2 : "") }' "$cur"
        done < "$new_keys"
    fi
    if [ "$n_gone" -gt 0 ]; then
        echo "GONE since last lint ($n_gone):"
        sed 's/^/  - /' "$gone_keys"
    fi
    echo "known and unchanged: $n_same (parked debt, not this session's regression)"

    if [ "$seal" = "--seal" ]; then
        cp "$cur" "$base"
        echo "baseline updated: $base"
    fi
    rm -f "$cur" "$new_keys" "$gone_keys"
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
    [ -f "$ar" ] || { echo "archive: no archive note at '${ar:-}'" >&2; return 1; }
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
            # New entry? `- [x] 2026-08-03` / `- ✅ 2026-08-03`
            if ($0 ~ /^[[:space:]]*-[[:space:]]*(\[x\]|✅)/) {
                d = ""
                if (match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
                    d = substr($0, RSTART, RLENGTH)
                # No date -> keep. Never move what we cannot date.
                dest = (d != "" && d < before) ? "moved" : "kept"
                n[dest]++
            }
            if (dest == "") { print > (w "/head"); next }   # prose before the first entry
            print > (w "/" dest)
        }
        END {
            print n["moved"] + 0 > (w "/n_moved")
            print n["kept"]  + 0 > (w "/n_kept")
        }
    ' "$tb" || { rm -rf "$work"; return 1; }

    for f in head kept moved tail n_moved n_kept; do : > "$work/$f.z"; done
    for f in head kept moved tail; do [ -f "$work/$f" ] || : > "$work/$f"; done
    n_moved=$(cat "$work/n_moved" 2>/dev/null || echo 0)
    n_kept=$(cat "$work/n_kept" 2>/dev/null || echo 0)

    # Balance check before touching anything. The first hand-rolled archiving in
    # this repo duplicated three entries; a count that does not add up means stop.
    # Count inside the Done section only, by a separate pass: closed items also
    # appear under In progress (sub-items of an open task), and counting the whole
    # file compares two different populations — which is exactly what the first
    # version of this check did, and it refused on a perfectly good taskboard.
    total_before=$(awk '
        /^## / { done_sec = ($0 ~ /^## (Done|Завершено)/); next }
        done_sec && /^[[:space:]]*-[[:space:]]*(\[x\]|✅)/ { n++ }
        END { print n + 0 }
    ' "$tb")
    if [ "$((n_moved + n_kept))" -ne "$total_before" ]; then
        echo "archive: refused — $n_moved moved + $n_kept kept != $total_before in file" >&2
        rm -rf "$work"; return 1
    fi

    echo "archive: $n_moved entries older than $before, $n_kept stay (of $total_before)"
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
    [ "$(timeout 2 obsidian vault info=name 2>/dev/null)" = "$(basename "$vault")" ]
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
    git -C "$vault" remote | grep -q . || {
        echo "sync skipped: no remote"; return 0; }

    out=$(timeout 30 git -C "$vault" pull --rebase --autostash 2>&1)
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
    head -1 "$file" | grep -q '^---$' || {
        echo "stamp-field: $file has no frontmatter block" >&2; return 1; }

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
    ALL_MD=$(find . -name '*.md' -not -path './.git/*' | sort)
    if [ -z "$ALL_MD" ]; then
        echo "lint-collect: no markdown found under '$vault' — refusing to report a clean vault" >&2
        return 1
    fi

    LC_TMP=$(mktemp -d) || return 1
    mkdir -p "$LC_TMP/clean"
    # shellcheck disable=SC2064
    trap "rm -rf '$LC_TMP'" EXIT

    _lc_epoch() {  # portable: GNU date first, BSD date second. Neither -> empty.
        date -d "$1" +%s 2>/dev/null || date -j -f %Y-%m-%d "$1" +%s 2>/dev/null || true
    }
    _lc_fm() {     # value of one frontmatter key, first block only
        awk -v k="$2" '/^---$/ { c++; next }
             c == 1 && index($0, k ":") == 1 {
                 sub(/^[^:]*:[[:space:]]*/, ""); gsub(/"/, "")
                 gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' "$1"
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
    _lc_section() { # non-blank lines of one '## ' section, heading excluded
        awk -v pat="$2" '/^## /{ p = ($0 ~ pat); next } p && NF' "$1" | grep -c .
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
        sed 's/\[\[//; s/\]\]//; s/|.*//; s|/_PROJECT$||' | sort -u)
    FS_P=$(find . -name '_PROJECT.md' -not -path './.git/*' |
        sed 's|/_PROJECT.md$||; s|^\./||' | sort -u)
    if [ -z "$FS_P" ]; then
        echo "lint-collect: no _PROJECT.md anywhere — refusing to report a clean vault" >&2
        return 1
    fi
    for p in $FS_P; do
        printf '%s\n' "$REG_P" | grep -qxF "$p" || \
            printf 'project-unregistered:%s\tесть в vault, нет в %s\n' "$p" "$REG"
    done
    for p in $REG_P; do
        [ -f "$p/_PROJECT.md" ] || \
            printf 'registry-stale:%s\tчислится в %s, файла нет\n' "$p" "$REG"
    done
    PROJECTS="$FS_P"
    [ -n "$only" ] && PROJECTS="$only"

    # ── per project ──────────────────────────────────────────────────────────
    for P in $PROJECTS; do
        f="$P/_PROJECT.md"
        [ -f "$f" ] || { printf 'project-missing:%s\t_PROJECT.md отсутствует\n' "$P"; continue; }

        prose=$(_lc_section "$f" '^## (Current state|Статус|Последняя сессия|For future Claude)')
        ffc=$(_lc_section "$f" '^## For future Claude')
        [ "$prose" -gt 60 ] && printf 'prose-budget:%s\t%s строк при бюджете ~60\n' "$P" "$prose"
        [ "$ffc" -gt 20 ] && printf 'ffc-budget:%s\tFor future Claude %s строк\n' "$P" "$ffc"

        upd=$(_lc_fm "$f" updated)
        if [ -z "$upd" ]; then
            printf 'missing-updated:%s\t_PROJECT.md без поля updated:\n' "$P"
        else
            us=$(_lc_epoch "$upd")
            if [ -z "$us" ]; then
                echo "lint-collect: cannot parse date '$upd' in $f (no working date(1))" >&2
                return 1
            fi
            days=$(( (TODAY - us) / 86400 ))
            [ "$days" -gt 14 ] && printf 'stale-project:%s\t%s дней без обновления _PROJECT.md\n' "$P" "$days"
        fi

        tb="$P/taskboard.md"
        if [ -f "$tb" ]; then
            # Both markers, always: projects use `- [x]` and `- ✅` interchangeably
            # and a counter that knows one reports zero for a project using the other.
            # Count inside Done only — a closed sub-item under an open task is not
            # an archivable entry (65 file-wide against 5 in Done, measured).
            dn=$(awk '/^## / { d = ($0 ~ /^## (Done|Завершено)/); next }
                      d && /^[[:space:]]*-[[:space:]]*(\[x\]|✅)/ { n++ }
                      END { print n + 0 }' "$tb")
            tot=$(grep -c . "$tb")
            prog=$(awk '/^## /{ p = ($0 ~ /In progress|В работе/) } p' "$tb" | grep -c .)
            [ "$dn" -gt 20 ] && printf 'taskboard-done:%s\t%s закрытых записей в Done\n' "$P" "$dn"
            [ "$prog" -gt 300 ] && printf 'taskboard-inprogress:%s\t%s строк\n' "$P" "$prog"
            [ "$tot" -gt 600 ] && printf 'taskboard-size:%s\t%s строк, In progress %s\n' "$P" "$tot" "$prog"
        fi

        am="$P/architecture-map.md"
        if [ -f "$am" ]; then
            mu=$(_lc_fm "$am" updated)
            ls_=$(find "$P/sessions" -maxdepth 1 -name '*_session.md' 2>/dev/null |
                  sed 's|.*/||' | cut -c1-10 | sort | tail -1)
            if [ -n "$mu" ] && [ -n "$ls_" ]; then
                a=$(_lc_epoch "$mu"); b=$(_lc_epoch "$ls_")
                [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && \
                    printf 'map-stale:%s\tкарта %s против сессии %s\n' "$P" "$mu" "$ls_"
            fi
        fi

        _lc_keys "$P/sessions" '*.md' "$P/sessions"
        _lc_keys "$P/wiki" 'decision-*.md' "$P/decisions"
    done

    # ── stale drafts ─────────────────────────────────────────────────────────
    printf '%s\n' "$ALL_MD" | grep -v '/raw/' | while read -r p; do
        [ "$(_lc_fm "$p" status)" = "draft" ] || continue
        d=$(_lc_fm "$p" date); [ -n "$d" ] || continue
        ds=$(_lc_epoch "$d"); [ -n "$ds" ] || continue
        days=$(( (TODAY - ds) / 86400 ))
        [ "$days" -gt 14 ] && printf 'stale-draft:%s\t%s дней\n' "$(echo "${p#./}" | sed 's|\.md$||')" "$days"
    done

    # ── decision-note schema ─────────────────────────────────────────────────
    # `~` is YAML null, not a filename; a value may be a relative path; and the
    # legacy form is quoted inside the note that documents it. All three produced
    # false positives on the 2026-08-04 soak run — the whole reason this is code.
    find . -path '*/wiki/decision-*.md' -not -path './.git/*' | sort | while read -r p; do
        st=$(_lc_fm "$p" status)
        case "$st" in
            accepted|superseded|deprecated) ;;
            "") printf 'decision-schema:%s\tнет status:\n' "${p#./}" ;;
            *)  printf 'decision-schema:%s\tstatus вне схемы: %s\n' "${p#./}" "$st" ;;
        esac
        # legacy one-line form, frontmatter only (a fenced quote of it is not one)
        awk '/^---$/ { c++; next } c == 1 && /^status:[[:space:]]*superseded-by:/ { found = 1 }
             END { exit !found }' "$p" && \
            printf 'decision-legacy:%s\tодностроч. status: superseded-by: — невалидный YAML\n' "${p#./}"
        for k in supersedes superseded-by corrected-by; do
            v=$(_lc_fm "$p" "$k")
            case "$v" in ""|"~"|"null"|"[]") continue ;; esac
            v=$(printf '%s' "$v" | sed 's/^\[\[//; s/\]\]$//; s/|.*//; s/\.md$//')
            base=$(printf '%s' "$v" | sed 's|.*/||')
            find . -name "$base.md" -not -path './.git/*' | grep -q . || \
                printf 'decision-ref:%s\t%s → %s не существует\n' "${p#./}" "$k" "$v"
        done
    done

    # ── frontmatter structure (no parser needed) ─────────────────────────────
    printf '%s\n' "$ALL_MD" | while read -r p; do
        head -1 "$p" | grep -qx -- '---' || continue
        awk 'NR == 1 { next } /^---$/ { ok = 1; exit } END { exit ok }' "$p" && \
            printf 'frontmatter:%s\tблок не закрыт\n' "${p#./}"
    done

    # ── ambiguous bare links ─────────────────────────────────────────────────
    # A link breaks by the *existence of a duplicate name anywhere*, so this runs
    # over the whole vault whatever the scope: a name unique when the link was
    # written stops being unique the moment another project reuses the basename,
    # and every already-correct link in the older project turns ambiguous with no
    # edit to it. sessions/ and archive-* are history and are not rewritten.
    printf '%s\n' "$ALL_MD" | sed 's|.*/||; s|\.md$||' | sort | uniq -d > "$LC_TMP/dup"
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
                sed -n "${ln}p" "$(_lc_clean "$hf")" | grep -qF "[[$name]]" || continue
                echo "${hf#./}" >> "$LC_TMP/amb"
            done
    done < "$LC_TMP/dup"
    # One key per file, count in the detail: the key must be stable, and a per-hit
    # key would repeat — lint-diff refuses a set with duplicate keys.
    sort "$LC_TMP/amb" | uniq -c | while read -r n hf; do
        printf 'ambiguous-link:%s\t%s голых ссылок\n' "$hf" "$n"
    done

    # ── links per wiki note ──────────────────────────────────────────────────
    printf '%s\n' "$ALL_MD" | while read -r p; do cat "$(_lc_clean "$p")"; done |
        grep -oE '\[\[[^]|]+' | sed 's/^\[\[//; s|.*/||' | sort | uniq -c > "$LC_TMP/inc"
    : > "$LC_TMP/links"
    printf '%s\n' "$ALL_MD" | grep '/wiki/' | while read -r p; do
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
    sort "$LC_TMP/links" | uniq -c | while read -r n cls proj; do
        case "$cls" in
            no-links)    printf 'wiki-no-links:%s\t%s заметок\n' "$proj" "$n" ;;
            no-backlink) printf 'wiki-no-backlink:%s\t%s заметок\n' "$proj" "$n" ;;
            no-sibling)  printf 'wiki-no-sibling:%s\t%s заметок\n' "$proj" "$n" ;;
        esac
    done
}

# Frontmatter key uniformity within one project. A key counts as a convention
# only when it carries a VALUE in most entries: a key emitted empty by a template
# and filled by nobody is an artefact, not a rule — `supersedes:` is empty in 29
# of 32 cadrika notes, and counting presence alone made the three that lack the
# empty line look like violations. A false finding costs more than a missed one:
# it teaches the reader to skim.
_lc_keys() {
    dir="$1"; pat="$2"; label="$3"
    [ -d "$dir" ] || return 0
    files=$(find "$dir" -maxdepth 1 -name "$pat" | sort)   # not ls: it may be a
    n=$(printf '%s\n' "$files" | grep -c .)                # shell function (eza)
    [ "$n" -lt 3 ] && return 0
    kt=$(mktemp); ct=$(mktemp)
    printf '%s\n' "$files" | while read -r f; do
        awk '/^---$/ { c++; next }
             c == 1 && /^[A-Za-z_-]+:/ {
                 k = $0; sub(/:.*/, "", k)
                 v = $0; sub(/^[A-Za-z_-]+:[[:space:]]*/, "", v)
                 gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                 if (v != "" && v != "[]" && v != "\"\"" && v != "~" && v != "null") print k
             }' "$f" | sort -u
    done | sort | uniq -c | awk -v n="$n" '$1 > n * 0.6 { print $2 }' > "$ct"
    printf '%s\n' "$files" | while read -r f; do
        have=$(awk '/^---$/ { c++; next }
                    c == 1 && /^[A-Za-z_-]+:/ {
                        k = $0; sub(/:.*/, "", k)
                        v = $0; sub(/^[A-Za-z_-]+:[[:space:]]*/, "", v)
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                        if (v != "" && v != "[]" && v != "\"\"" && v != "~" && v != "null") print k
                    }' "$f" | sort -u)
        while read -r k; do
            [ -n "$k" ] || continue
            printf '%s\n' "$have" | grep -qxF "$k" || echo "$k"
        done < "$ct"
    done | sort | uniq -c | while read -r cnt k; do
        printf 'key-uniformity:%s\t%s записей без %s (всего %s)\n' "$label" "$cnt" "$k" "$n"
    done
    rm -f "$kt" "$ct"
}

case "${1:-}" in
    obsidian-available) shift; obsidian_available "${1:-}" ;;
    vault-name)         timeout 2 obsidian vault info=name 2>/dev/null || true ;;
    vault-sync)         shift; vault_sync "${1:-}" ;;
    stamp-field)        shift; stamp_field "${1:-}" "${2:-}" "${3:-}" ;;
    version)            brain_version ;;
    lint-diff)          shift; lint_diff "${1:-}" "${2:-}" ;;
    lint-collect)       shift; lint_collect "$@" ;;
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
