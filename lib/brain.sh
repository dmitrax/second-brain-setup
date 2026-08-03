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
USAGE
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

case "${1:-}" in
    obsidian-available) shift; obsidian_available "${1:-}" ;;
    vault-name)         timeout 2 obsidian vault info=name 2>/dev/null || true ;;
    vault-sync)         shift; vault_sync "${1:-}" ;;
    stamp-field)        shift; stamp_field "${1:-}" "${2:-}" "${3:-}" ;;
    version)            brain_version ;;
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
