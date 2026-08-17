#!/usr/bin/env bash
# preflight.sh — the release gate. Run it BEFORE tagging.
#
# It checks the repository against its own rules from CLAUDE.md Block 2. Every rule
# here was added after a live incident — none of this list is speculative. Three of the
# four bugs in the v1.4.3/v1.5.0 releases would have been caught by a one-line grep that
# did not exist; this script is that grep.
#
# Usage:
#   bash preflight.sh          # every check
#   bash preflight.sh --fast   # skip the install into a temp $HOME (quick loop while editing)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAST=0
[ "${1:-}" = "--fast" ] && FAST=1
# Guard for check 49, which runs this script against itself to prove the coverage
# block actually prints. One level only: the nested run sees 1 and skips the check.
PF_NESTED="${PF_NESTED:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FAILED=0
PASSED=0

# ─── Locale self-test, before any check that uses a Cyrillic character class ─────
# Checks 32 and 33 match `[А-Яа-яЁё]`, and that class is only a class in a UTF-8
# locale. Measured 2026-08-04 on Arch: under LC_ALL=C it does not go blind — it
# degrades into a byte range matching ANY non-ASCII, so `café`, `naïve` and `Müller`
# all read as Cyrillic. Same in grep, in awk and in a bash `case` glob. A commit
# message naming a French word would then fail a check about Russian, in CI or cron
# where a C locale is the norm — and the failure would be argued with, not believed.
# So: state the locale this file needs instead of assuming it, and fail loudly when it
# is absent. "The environment cannot run this check" and "the repo is clean" are
# different facts, and only one deserves a green — the same rule as the PyYAML
# provisioning below (check 7) and the empty-input rule (check 14).
# Detected by behaviour, not by reading $LANG: the variable can name a locale the
# machine does not actually have, and it is the behaviour that the checks depend on.
if grep -qE '[А-Яа-яЁё]' <<<"$(printf 'caf\303\251')"; then   # \ooo is POSIX, \xHH is not
    echo -e "${RED}✗${NC} the locale makes [А-Яа-яЁё] match any non-ASCII byte"
    echo "  Checks 32 and 33 would flag 'café' and 'Müller' as Russian."
    echo "  Current: LANG=${LANG:-unset} LC_ALL=${LC_ALL:-unset} LC_CTYPE=${LC_CTYPE:-unset}"
    echo "  Re-run under a UTF-8 locale, e.g.: LC_ALL=en_US.UTF-8 bash preflight.sh"
    exit 1
fi

# Fixture dates. Freshness is COMPUTED, staleness is written ancient — a literal date
# meaning "recent" decays into a red on a fixed calendar day with nobody touching the
# code (measured 2026-08-16, see check 40). PF_FRESH sits at 13 days so it also proves
# the stale threshold is `> 14` rather than `>= 1`; PF_ANCIENT can only get older.
PF_FRESH=$(date -d '-13 days' +%Y-%m-%d 2>/dev/null || date -v-13d +%Y-%m-%d)
PF_ANCIENT=2020-01-01

# Scan targets. preflight.sh is deliberately NOT among them: it holds the forbidden
# patterns as search strings and would match itself — the same class of mistake as
# `pgrep -f`, which made the guard find its own process (v1.3 -> 2026-07-11).
TARGETS=("$SCRIPT_DIR/SKILL.md" "$SCRIPT_DIR"/commands/brain-*.md)

pass() { PASSED=$((PASSED + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
# gap <what was not verified here> — record a hole in this run's COVERAGE.
#
# Green must mean "ran and found nothing". Some checks legitimately cannot run on the
# machine at hand: check 38 verifies the BSD branch of a date fallback and this machine has
# no BSD `date`, so it prints "GNU branch only" — a true statement, dissolved among 66
# green lines and collected nowhere. That is why "check 41 has never executed under BSD
# date" lives as a task on the board instead of coming out of the gate that knows it.
#
# Borrowed from nf-content, where a missing component of a record becomes an explicit
# «вопрос для интервью» in a list rather than a silence: absence is recorded next to
# presence. Deliberately does NOT touch FAILED — an uncovered branch is not a red, and a
# warning that fires on every ordinary run stops being read (measured three times here:
# prose-budget's permanent OVER, the Done counter's unactionable advice, ANSWER at 40%).
GAPS=""
gap() { GAPS="$GAPS$1"$'\n'; }
fail() {
    FAILED=$((FAILED + 1))
    echo -e "  ${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /'
    return 0
}

# code_blocks <file> — prints the contents of ``` fenced blocks only.
# Prose is skipped on purpose: the files describe forbidden calls in words ("Do not use
# obsidian property:set here"), and a blunt grep over the whole file would make
# documenting a prohibition a violation of it.
code_blocks() {
    awk '/^[[:space:]]*```/ { inblock = !inblock; next } inblock { print }' "$1"
}

# exec_blocks <file> — code_blocks minus the blocks declared markdown or yaml, which are
# note templates rather than commands, prefixed with the source line number.
# Why the distinction is load-bearing: several prohibitions in this file are about naming
# a call ("never `obsidian property:set`"), and /brain-init states them INSIDE the
# ```markdown template it writes into a new project's CLAUDE.md. Scanned as executable,
# the file cannot state the rule it is required to state. Checks 1 and 2 read as green
# today only because their wording happens to miss by one word: adding `obsidian ` in
# front of `property:set` in that template turned check 2 red — found 2026-08-04 by the
# differentiating negative test for check 39, not by a failure.
exec_blocks() {
    awk '
        FNR == 1 { inb = 0; lang = "" }
        /^[[:space:]]*```/ {
            if (!inb) { inb = 1; lang = $0; sub(/^[[:space:]]*```[[:space:]]*/, "", lang) }
            else      { inb = 0; lang = "" }
            next
        }
        !inb               { next }
        lang == "markdown" { next }
        lang == "yaml"     { next }
        { print FNR ":" $0 }' "$1"
}

# unquoted_globs <file> — prints lines of shell blocks where `*` is not quoted.
# Blocks declared markdown/yaml are skipped on purpose: those are note templates, not
# commands, and an asterisk there is markup.
# Why character by character rather than by grep: a quoted glob (`find -name "*.md"`) is
# the required FIX, not the violation, and telling it from a bare one needs the quote
# state carried along the line. A grep for `*` would go red on its own remedy.
unquoted_globs() {
    awk '
        BEGIN { SQ = sprintf("%c", 39) }
        FNR == 1 { inb = 0; lang = "" }
        /^[[:space:]]*```/ {
            if (!inb) { inb = 1; lang = $0; sub(/^[[:space:]]*```[[:space:]]*/, "", lang) }
            else      { inb = 0; lang = "" }
            next
        }
        !inb               { next }
        lang == "markdown" { next }
        lang == "yaml"     { next }
        {
            line = $0
            sub(/[[:space:]]#.*/, "", line)
            n = length(line); q = ""
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (q == "") {
                    if (c == "\"" || c == SQ) { q = c; continue }
                    if (c != "*") continue
                    prev = (i > 1) ? substr(line, i-1, 1) : ""
                    nxt  = (i < n) ? substr(line, i+1, 1) : ""
                    if (prev == "*" || nxt == "*") continue    # **bold**
                    if (prev ~ /[A-Za-z0-9_.\/"-]/ || nxt ~ /[A-Za-z0-9_.\/"]/) {
                        print FILENAME ":" FNR ": " $0; next
                    }
                    # A bare `*` standing as a whole word: `for f in *`, `cat *`,
                    # `-name *`, `--include=*`. Measured 2026-08-05, all four missed by
                    # the neighbour test above, which needs a suffix or a path prefix.
                    # This class fails only on an EMPTY directory -- a bare `*` matches
                    # anything else -- and that is precisely the case this repo was
                    # already burned by: the first save of a project with no session
                    # logs. Rarer, not harmless: zsh cancels the WHOLE line, so a
                    # trailing `echo` on it does not run either.
                    # Two carve-outs, both measured against real false positives: a line
                    # carrying `((` is arithmetic, where `*` multiplies; and a `*` that
                    # opens the line is a markdown bullet, which matters because 63 of
                    # the fenced blocks in this package declare no language and are read
                    # as executable. A command can never start with a glob.
                    if (line !~ /\(\(/ && substr(line, 1, i-1) ~ /[^[:space:]]/ &&
                        (prev == "" || prev ~ /[[:space:]=]/) &&
                        (nxt == "" || nxt ~ /[[:space:]]/)) {
                        print FILENAME ":" FNR ": " $0; next
                    }
                } else if (c == q) { q = "" }
            }
        }
    ' "$1"
}

# strip_inline_code <file...> — prints the files with `inline-code` spans removed, in
# grep -n form (file:line:text). Needed wherever a pattern is searched across a whole
# file, templates included: the prose documents prohibitions by quoting them in backticks
# ("never `status: superseded-by: x`"), and without this the documentation of a rule
# would count as breaking it. Fenced blocks contain no backticks, so the real templates
# stay visible.
strip_inline_code() {
    for f in "$@"; do
        [ -f "$f" ] || continue
        awk -v F="$f" '
            # Fenced blocks are left as they are: the real templates live there, and the
            # inline-span state is not tracked inside a block.
            /^[[:space:]]*```/ { infence = !infence; print F ":" NR ":"; next }
            infence            { print F ":" NR ":" $0; next }
            {
                out = ""
                n = length($0)
                for (i = 1; i <= n; i++) {
                    c = substr($0, i, 1)
                    if (c == "`") { incode = !incode; continue }
                    if (!incode) out = out c
                }
                print F ":" NR ":" out
            }
            # incode is deliberately NOT reset at a line boundary: markdown allows an
            # inline span to wrap, and those spans were the source of false positives.
        ' "$f"
    done
}

echo -e "${BLUE}━━━ preflight: pre-release check ━━━${NC}"
echo ""
echo -e "${BLUE}[1/3] Our own prohibitions (CLAUDE.md Block 2)${NC}"

# ─── 1. How the obsidian CLI addresses files ─────────────────────────────────
# Incident 2026-07-22: /brain-save stamped updated: into another project's _PROJECT.md.
# `file=` resolves by name like a bare wikilink, takes the first match, exits 0.
hits=""
for f in "${TARGETS[@]}"; do
    h=$(exec_blocks "$f" | grep "obsidian .*[^a-z_]file=" || true)
    [ -n "$h" ] && hits+="$(basename "$f"): $h"$'\n'
done
if [ -n "$hits" ]; then
    fail "obsidian CLI addressed by file= (must be path=)" "$hits"
else
    pass "obsidian CLI: addressed by path= only"
fi

# ─── 2. property:set ─────────────────────────────────────────────────────────
# Measured 2026-07-22: it re-serialises the whole frontmatter — strips quotes, expands
# inline lists, turns 007 into 7. Data loss without a warning, exit 0.
hits=""
for f in "${TARGETS[@]}"; do
    h=$(exec_blocks "$f" | grep "obsidian property:set" || true)
    [ -n "$h" ] && hits+="$(basename "$f"): $h"$'\n'
done
if [ -n "$hits" ]; then
    fail "obsidian property:set called in an executable block (forbidden — it rewrites the frontmatter)" "$hits"
else
    pass "property:set is not called in any code block"
fi

# ─── 3. pgrep -f ─────────────────────────────────────────────────────────────
# Incident 2026-07-11: the guard matched its own shell process.
hits=""
for f in "${TARGETS[@]}"; do
    h=$(code_blocks "$f" | grep -n "pgrep -f" || true)
    [ -n "$h" ] && hits+="$(basename "$f"): $h"$'\n'
done
if [ -n "$hits" ]; then
    fail "pgrep -f used to detect a running GUI (it matches its own process)" "$hits"
else
    pass "pgrep -f is not used"
fi

# ─── 4. The guard is called from lib/, never rewritten inline ────────────────
# Before v1.7.0 the guard existed as a fenced block in brain-lint.md while SKILL.md and
# brain-init.md referred to it as a library function that does not exist in their
# context — so /brain-init prescribed a mutating `obsidian move` under a protection it
# did not have. There is one copy of the code now. An inline definition would drift from
# the original again, so it is forbidden; the guard's SHAPE is no longer grepped here —
# it is verified by RUNNING it below.
for f in "${TARGETS[@]}"; do
    name=$(basename "$f")
    if grep -qE "_obsidian_available\(\)[[:space:]]*\{" "$f"; then
        fail "$name: defines _obsidian_available() inline" \
             "since v1.7.0 the guard lives in lib/brain.sh; an inline copy will drift"
        continue
    fi
    # Real calls are counted inside code blocks only: a grep cannot tell prose that
    # PRESCRIBES a call from prose that FORBIDS one ("Do not use obsidian property:set").
    calls=$(code_blocks "$f" | grep -cE "^[[:space:]]*(if |\[|.*\$\()?[[:space:]]*obsidian " || true)
    mentions=$(grep -c "obsidian-available" "$f" || true)
    # A file that touches the CLI nowhere is a legitimate outcome, but it is SAID rather
    # than skipped. `continue` here made the number of emitted checks depend on the text
    # of the files: measured 2026-08-04, rewriting SKILL.md's rename section dropped its
    # last `obsidian-available` mention, this file fell out of the loop, and the run went
    # from 53 checks to 52 with nothing red — a check that stops running looks exactly
    # like a check that never existed.
    if [ "$calls" -eq 0 ] && [ "$mentions" -eq 0 ]; then
        pass "$name: does not touch the Obsidian CLI, so no guard is owed"
    elif [ "$mentions" -eq 0 ]; then
        fail "$name calls obsidian in a code block without calling the guard from lib/brain.sh"
    else
        pass "$name: the guard is called from lib/brain.sh"
    fi
done

# ─── 4b. The guard WORKS — verified by running it, not by grep ───────────────
# This is why the guard was moved into code at all: before, only the shape of the text
# could be checked. Three states, all of which must complete without starting the GUI
# and without hanging.
LIBSH="$SCRIPT_DIR/lib/brain.sh"
if [ ! -f "$LIBSH" ]; then
    fail "lib/brain.sh is missing — the prompts refer to a file that does not exist"
else
    problems=""
    bash -n "$LIBSH" 2>/dev/null || problems+="syntax error in lib/brain.sh"$'\n'
    # Every CLI call must be under timeout: running it cannot catch this (the test rig
    # answers instantly), and a hung `obsidian` hangs the whole session — the same reason
    # the guard exists at all.
    # Only real invocations of the binary are counted, not the word "obsidian" in text:
    # lines carrying `obsidian vault ...` outside a comment must have a timeout. The first
    # version of this check grepped any occurrence of the word and went red on its own
    # usage text.
    # Output into a variable, not piped into `grep -q`: under `pipefail` (line 13) a
    # `grep -q*` exits on the first qualifying line, the producer takes SIGPIPE, and the
    # pipeline status becomes 141 — a successful match reads as a failure. Found
    # 2026-08-04 by the sweep this rule demanded; here it had not fired yet only because
    # there are few obsidian calls and the producer finishes first.
    ob_calls=$(grep -nE '(^|[^-a-z])obsidian +vault' "$LIBSH" | grep -v '^[0-9]*:[[:space:]]*#')
    if grep -qv 'timeout [0-9]' <<<"$ob_calls"; then
        problems+="an obsidian call without timeout in lib/brain.sh"$'\n'
    fi
    # (1) An empty argument must be refused, not compared empty against empty.
    bash "$LIBSH" obsidian-available "" >/dev/null 2>&1 &&
        problems+="the guard accepted an empty vault"$'\n'
    # (2) A deliberately foreign vault: even with the GUI open the name will not match.
    #     This is the case v1.5.0 added — an exit code only confirms "some vault is open".
    bash "$LIBSH" obsidian-available "/nonexistent/other-vault" >/dev/null 2>&1 &&
        problems+="the guard confirmed a foreign vault"$'\n'
    # (3) A HOME without SingletonLock — the GUI counts as closed, the CLI must not be touched.
    FAKEHOME=$(mktemp -d)
    HOME="$FAKEHOME" bash "$LIBSH" obsidian-available "$HOME/Workspace/second-brain-vault" \
        >/dev/null 2>&1 && problems+="the guard fired without a SingletonLock"$'\n'
    rm -rf "$FAKEHOME"
    # (4) An unknown subcommand must fail, not silently do nothing.
    bash "$LIBSH" definitely-not-a-command >/dev/null 2>&1 &&
        problems+="lib/brain.sh accepted an unknown subcommand"$'\n'
    # (5) The POSITIVE case, fully hermetic: a fake HOME with a SingletonLock pointing at
    #     a NON-existent target (exactly what Electron does), plus a fake `obsidian` on
    #     PATH. The guard must answer "available".
    #     Without this case the check is made of refusals only and cannot tell a working
    #     guard from one broken the other way — swapping `-L` for `-e` would pass
    #     unnoticed, although `-e` resolves the target and is therefore always false.
    #     Confirmed by a negative test.
    POSHOME=$(mktemp -d)
    mkdir -p "$POSHOME/.config/obsidian" "$POSHOME/bin" "$POSHOME/vaultdir/my-vault"
    ln -s "definitely-missing-$$" "$POSHOME/.config/obsidian/SingletonLock"
    printf '#!/bin/sh\necho my-vault\n' > "$POSHOME/bin/obsidian"
    chmod +x "$POSHOME/bin/obsidian"
    if ! HOME="$POSHOME" PATH="$POSHOME/bin:$PATH" \
         bash "$LIBSH" obsidian-available "$POSHOME/vaultdir/my-vault" >/dev/null 2>&1; then
        problems+="the guard denied availability in a known-good state (check -L against -e)"$'\n'
    fi
    rm -rf "$POSHOME"
    if [ -n "$problems" ]; then
        fail "lib/brain.sh: the guard misbehaves (verified by running it)" "$problems"
    else
        pass "lib/brain.sh: guard exercised — 3 refusals + a working state + timeout"
    fi
fi

# ─── 4c. vault-sync and stamp-field work on real files ───────────────────────
if [ -f "$LIBSH" ]; then
    problems=""
    TMPLIB=$(mktemp -d)
    # stamp-field must touch one line and reformat no neighbours — exactly what
    # property:set got wrong (quotes, inline lists, 007 -> 7).
    printf -- '---\ntags: [session, x]\nversion: "1.4.3"\nupdated: 2026-01-01\ncount: 007\n---\n\nbody\n' \
        > "$TMPLIB/a.md"
    bash "$LIBSH" stamp-field "$TMPLIB/a.md" updated 2026-02-03 >/dev/null 2>&1 ||
        problems+="stamp-field failed on a normal file"$'\n'
    grep -q '^updated: 2026-02-03$' "$TMPLIB/a.md" || problems+="stamp-field did not write the date"$'\n'
    grep -q '^tags: \[session, x\]$' "$TMPLIB/a.md" || problems+="stamp-field expanded an inline list"$'\n'
    grep -q '^version: "1.4.3"$' "$TMPLIB/a.md" || problems+="stamp-field stripped quotes"$'\n'
    grep -q '^count: 007$' "$TMPLIB/a.md" || problems+="stamp-field rewrote 007"$'\n'
    # A missing key is added; existing ones are left alone.
    bash "$LIBSH" stamp-field "$TMPLIB/a.md" brain-version '"v1.7.0"' >/dev/null 2>&1 ||
        problems+="stamp-field did not add a missing key"$'\n'
    grep -q '^brain-version: "v1.7.0"$' "$TMPLIB/a.md" || problems+="stamp-field did not write brain-version"$'\n'
    grep -q '^count: 007$' "$TMPLIB/a.md" || problems+="stamp-field damaged a neighbouring key while adding"$'\n'
    # A key with stray characters must be refused, or anything could be written into the block.
    bash "$LIBSH" stamp-field "$TMPLIB/a.md" 'weird: key' x >/dev/null 2>&1 &&
        problems+="stamp-field accepted a key with stray characters"$'\n'
    # A file without frontmatter must not be touched.
    printf -- '# no frontmatter\n' > "$TMPLIB/b.md"
    bash "$LIBSH" stamp-field "$TMPLIB/b.md" updated 2026-08-03 >/dev/null 2>&1 &&
        problems+="stamp-field accepted a file without frontmatter"$'\n'
    # version must always print something: no VERSION file -> "unknown", never empty.
    [ -n "$(bash "$LIBSH" version 2>/dev/null)" ] ||
        problems+="version prints nothing (it must at least say unknown)"$'\n'

    # archive: moving Done into the archive note. This tests exactly what it was written
    # for — nothing lost, nothing duplicated, no other section touched.
    printf -- '## In progress\n- [x] closed sub-item of a live task\n- [ ] the task itself\n\n## Done\n- [x] 2026-06-01 — old one\n      its second line\n- ✅ 2026-07-01 — tick marker\n- [x] 2026-12-01 — recent\n- [x] no date here\n\n## Backlog\n- [ ] tail\n' > "$TMPLIB/tb.md"
    printf -- '# Archive\n' > "$TMPLIB/ar.md"
    # a dry run must write nothing
    bash "$LIBSH" archive "$TMPLIB/tb.md" "$TMPLIB/ar.md" --before 2026-08-01 >/dev/null 2>&1 || true
    [ "$(grep -c . "$TMPLIB/ar.md")" -eq 1 ] ||
        problems+="archive: the dry run wrote into the archive"$'\n'
    bash "$LIBSH" archive "$TMPLIB/tb.md" "$TMPLIB/ar.md" --before 2026-08-01 --apply >/dev/null 2>&1 ||
        problems+="archive: failed on valid input"$'\n'
    grep -q '2026-06-01' "$TMPLIB/ar.md" || problems+="archive: did not move the old entry"$'\n'
    grep -q 'its second line' "$TMPLIB/ar.md" || problems+="archive: lost the continuation of an entry"$'\n'
    grep -q '2026-07-01' "$TMPLIB/ar.md" || problems+="archive: does not know the ✅ marker"$'\n'
    grep -q '2026-12-01' "$TMPLIB/tb.md" || problems+="archive: moved a recent entry"$'\n'
    grep -q 'no date here' "$TMPLIB/tb.md" || problems+="archive: moved an undated entry"$'\n'
    grep -q 'closed sub-item' "$TMPLIB/tb.md" || problems+="archive: touched the In progress section"$'\n'
    grep -q 'tail' "$TMPLIB/tb.md" || problems+="archive: lost the section after Done"$'\n'
    grep -q '2026-06-01' "$TMPLIB/tb.md" && problems+="archive: duplicated an entry (it is still in the taskboard)"$'\n'
    # Three states, three different words. "0 entries older than X" is TRUE and useless
    # when the dates are in the bodies: measured 2026-08-16 on the goprofi board as of
    # 08-07, 31 of 37 entries were dated only in the body and the run said "0 moved,
    # 42 stay", which was read for nine days as "nothing is due for archiving".
    printf -- '## Done\n- [x] dated in the body\n      closed on 2026-07-01 per the log\n- [x] nothing date-like at all\n      just prose\n' > "$TMPLIB/tb3.md"
    printf -- '# Archive\n' > "$TMPLIB/ar3.md"
    a3=$(bash "$LIBSH" archive "$TMPLIB/tb3.md" "$TMPLIB/ar3.md" --before 2026-08-01 2>&1)
    grep -q 'date in the BODY' <<<"$a3" ||
        problems+="archive: a body-dated entry is not distinguished from an undated one"$'\n'
    grep -q 'no date anywhere' <<<"$a3" ||
        problems+="archive: an entry with no date at all is not named as such"$'\n'
    grep -q 'backfill-dates' <<<"$a3" ||
        problems+="archive: does not say how to recover the missing dates"$'\n'
    # And it must NOT move by a body date: those mean different things (closed on / opened
    # on / due by), so archiving on them files entries under the wrong date, silently.
    grep -q 'dated in the body' "$TMPLIB/tb3.md" ||
        problems+="archive: moved an entry using a date from its body"$'\n'
    # A malformed date and a missing file must be refused, not read as "found nothing".
    bash "$LIBSH" archive "$TMPLIB/tb.md" "$TMPLIB/ar.md" --before yesterday >/dev/null 2>&1 &&
        problems+="archive: accepted a malformed date"$'\n'
    bash "$LIBSH" archive "$TMPLIB/nope.md" "$TMPLIB/ar.md" --before 2026-08-01 >/dev/null 2>&1 &&
        problems+="archive: accepted a taskboard that does not exist"$'\n'
    # lint-diff: the key is compared, the detail is only displayed. That is exactly what
    # is tested here — otherwise a known finding whose number moved would count as new
    # every time, and the whole point is telling a regression from parked debt.
    printf 'prose-budget\tgoprofi: 154\nmap-stale\tcadrika\n' > "$TMPLIB/f1.txt"
    command cat "$TMPLIB/f1.txt" | bash "$LIBSH" lint-diff "$TMPLIB/base.txt" --seal >/dev/null 2>&1 ||
        problems+="lint-diff: failed on the first run"$'\n'
    [ -s "$TMPLIB/base.txt" ] || problems+="lint-diff: --seal did not write the baseline"$'\n'
    # detail changed, key unchanged -> the finding is NOT new
    printf 'prose-budget\tgoprofi: 999\nmap-stale\tcadrika\n' > "$TMPLIB/f2.txt"
    out=$(command cat "$TMPLIB/f2.txt" | bash "$LIBSH" lint-diff "$TMPLIB/base.txt" 2>&1)
    case "$out" in
        *NEW*) problems+="lint-diff: a changed number made a known finding new"$'\n' ;;
    esac
    # a new key -> a new finding; a vanished one -> GONE
    printf 'prose-budget\tgoprofi: 154\nzone-missing\tgoprofi\n' > "$TMPLIB/f3.txt"
    out=$(command cat "$TMPLIB/f3.txt" | bash "$LIBSH" lint-diff "$TMPLIB/base.txt" 2>&1)
    case "$out" in
        *"+ zone-missing"*) : ;;
        *) problems+="lint-diff: missed a new finding"$'\n' ;;
    esac
    case "$out" in
        *"- map-stale"*) : ;;
        *) problems+="lint-diff: missed a vanished finding"$'\n' ;;
    esac
    # without --seal the baseline must stay as it was
    grep -q 'zone-missing' "$TMPLIB/base.txt" &&
        problems+="lint-diff: wrote the baseline without --seal"$'\n'
    # the step must exist in the prompt, or the code is there with nobody to call it
    LINTMD="$SCRIPT_DIR/commands/brain-lint.md"
    # The pattern carries the colon rather than a bare "Step 12": a substring also matches
    # "Step 12z", which is why the negative test for renaming the step passed green (the
    # third substring trap of that session — see also vault-sync-DISABLED).
    grep -qiE '^## Step [0-9]+[a-z]?: Report the delta' "$LINTMD" ||
        problems+="brain-lint.md: no step comparing against the baseline"$'\n'
    grep -qF 'lint-diff' "$LINTMD" || problems+="brain-lint.md: the delta step does not call lint-diff"$'\n'
    grep -qF 'lint-collect' "$LINTMD" ||
        problems+="brain-lint.md: the checks are not called from lib (prose again)"$'\n'
    # The completeness requirement moved into the code along with the checks: lint-collect
    # must fail on empty input, and the prompt must not substitute hand-written greps.
    grep -qiE 'do not fall back to' "$LINTMD" ||
        problems+="brain-lint.md: lost the ban on replacing lint-collect with hand greps"$'\n'
    grep -qiE 'refusing to report a clean vault' "$LIBSH" ||
        problems+="lint-collect does not fail on empty input"$'\n'

    # Both guards are present — checked by grep.
    grep -q 'refused — .*moved.*kept' "$LIBSH" ||
        problems+="archive: the entry-count reconciliation was removed"$'\n'
    grep -q 'refused — line balance off' "$LIBSH" ||
        problems+="archive: the line-count reconciliation was removed"$'\n'
    grep -qE 'done_sec && /\^' "$LIBSH" ||
        problems+="archive: entries are counted outside the Done section"$'\n'
    # An entry is anchored at column 0, in every place that defines one. An INDENTED
    # closed item is a sub-item — one line of the body of the entry above it — and the
    # four definitions must agree, or the splitter, its own balance check, the budget
    # counter and the lint report different populations of the same file.
    # Measured 2026-08-04 on a fixture with `^[[:space:]]*`: `archive --apply` moved a
    # dated parent into the archive note and left its two closed sub-items behind in Done,
    # orphaned. Exit 0, no warning, and the balance check agreed because it was counting
    # the same wrong population. The previous form of this check pinned the indentation
    # prefix as a literal, so it asserted the defect rather than the property.
    n_loose=$(grep -cE '\^\[\[:space:\]\]\*-\[\[:space:\]\]\*\(\\\[x\\\]\|✅\)' "$LIBSH")
    [ "$n_loose" -eq 0 ] ||
        problems+="archive/budget: $n_loose entry pattern(s) still count an indented sub-item as an entry"$'\n'
    n_anchored=$(grep -cE '\^-\[\[:space:\]\]\*\(\\\[x\\\]\|✅\)' "$LIBSH")
    [ "$n_anchored" -ge 4 ] ||
        problems+="archive/budget: only $n_anchored of the 4 entry definitions are anchored at column 0"$'\n'
    # And prove it by running: a dated parent with two closed sub-items must archive as
    # ONE entry, taking its children with it, leaving Done empty.
    nest=$(mktemp -d)
    printf '# t\n\n## In progress\n\n## Done\n- [x] 2026-08-01 parent\n  - [x] sub one\n  - [x] sub two\n' > "$nest/taskboard.md"
    printf -- '---\nproject: t\n---\n# archive\n' > "$nest/archive-2026.md"
    bash "$LIBSH" archive "$nest/taskboard.md" "$nest/archive-2026.md" --before 2026-08-03 --apply >/dev/null 2>&1
    left=$(grep -c '\[x\]' "$nest/taskboard.md")
    took=$(grep -c 'sub one' "$nest/archive-2026.md")
    { [ "$left" -eq 0 ] && [ "$took" -eq 1 ]; } ||
        problems+="archive: a nested entry was torn apart ($left closed lines left behind, sub-item archived: $took)"$'\n'
    rm -rf "$nest"
    # Whether they WORK is verified by RUNNING a deliberately broken copy. Otherwise a
    # guard is unverifiable by construction: while the rest of the code is correct,
    # disabling it produces no observable effect, and "it is there" rests on a line of
    # code being present. Break the parser so one entry disappears, then demand both a
    # refusal (non-zero) AND two untouched files.
    # The sed delimiter is `#`: the replacement text contains `||`, and with `|` sed dies
    # leaving an empty file. An empty "broken copy" does nothing, exits 0, and reads as
    # "the guard let it through" — caught the hard way 2026-08-03. Hence the three
    # assertions below: the copy is non-empty, differs from the original, and parses.
    sed 's#print > (w "/" dest)#if (!(dest == "moved" \&\& n["moved"] == 1)) print > (w "/" dest)#' \
        "$LIBSH" > "$TMPLIB/broken.sh" 2>/dev/null
    if [ ! -s "$TMPLIB/broken.sh" ] ||
       cmp -s "$TMPLIB/broken.sh" "$LIBSH" ||
       ! bash -n "$TMPLIB/broken.sh" 2>/dev/null; then
        problems+="archive: could not build the broken copy — the guard went untested"$'\n'
    fi
    printf -- '## Done\n- [x] 2026-01-01 — first\n- [x] 2026-02-01 — second\n- [x] 2026-12-01 — recent\n' > "$TMPLIB/tb2.md"
    printf -- '# Archive\n' > "$TMPLIB/ar2.md"
    tb2_sum=$(command cksum < "$TMPLIB/tb2.md"); ar2_sum=$(command cksum < "$TMPLIB/ar2.md")
    if bash "$TMPLIB/broken.sh" archive "$TMPLIB/tb2.md" "$TMPLIB/ar2.md" \
            --before 2026-08-01 --apply >/dev/null 2>&1; then
        problems+="archive: the broken parser LOSES an entry and the guard let it through"$'\n'
    fi
    [ "$(command cksum < "$TMPLIB/tb2.md")" = "$tb2_sum" ] ||
        problems+="archive: the taskboard changed despite the refusal"$'\n'
    [ "$(command cksum < "$TMPLIB/ar2.md")" = "$ar2_sum" ] ||
        problems+="archive: the archive changed despite the refusal"$'\n'
    # vault-sync: a local vault with no remote is a supported setup and must skip with 0.
    mkdir -p "$TMPLIB/v" && git -C "$TMPLIB/v" init -q 2>/dev/null
    bash "$LIBSH" vault-sync "$TMPLIB/v" >/dev/null 2>&1 ||
        problems+="vault-sync did not skip a vault without a remote"$'\n'
    # A non-repository is also a skip, not a refusal.
    mkdir -p "$TMPLIB/plain"
    bash "$LIBSH" vault-sync "$TMPLIB/plain" >/dev/null 2>&1 ||
        problems+="vault-sync did not skip a non-git vault"$'\n'
    # A non-existent path must be refused, or "synced" would mean "did nothing".
    bash "$LIBSH" vault-sync "$TMPLIB/nope" >/dev/null 2>&1 &&
        problems+="vault-sync accepted a path that does not exist"$'\n'
    rm -rf "$TMPLIB"
    if [ -n "$problems" ]; then
        fail "lib/brain.sh: vault-sync/stamp-field misbehave" "$problems"
    else
        pass "lib/brain.sh: stamp-field spares neighbouring fields, vault-sync tells its outcomes apart"
    fi
fi

# ─── 4e. lint-collect works on a fixture vault ───────────────────────────────
# Verified by RUNNING it on a vault where every class of finding is present exactly once,
# the same way 4b/4c verify the guard and archive. Grepping for shape would be doubly
# useless here: before these checks moved into lib/ they lived as prose, every session
# rewrote them, and a measurement on 2026-08-04 found 11 false positives out of 11 in one
# such implementation. The fixture also pins down what must NOT be a finding.
if [ -f "$LIBSH" ]; then
    problems=""
    LCV=$(mktemp -d)
    mkdir -p "$LCV/proj/wiki" "$LCV/proj/sessions" "$LCV/other/wiki" "$LCV/00-system"

    # The registry knows both projects — plus one that is not on disk.
    printf -- '# Index\n- [[proj/_PROJECT|proj]]\n- [[other/_PROJECT|other]]\n- [[ghost/_PROJECT|ghost]]\n' \
        > "$LCV/00-system/index.md"

    # proj: prose over budget, For future Claude over budget, updated gone stale.
    {
        printf -- '---\nproject: proj\nupdated: 2020-01-01\n---\n\n## Current state\n'
        i=0; while [ $i -lt 55 ]; do echo "state line $i"; i=$((i + 1)); done
        printf -- '\n## Последняя сессия\n'
        i=0; while [ $i -lt 6 ]; do echo "2026-01-0$((i + 1)) — entry $i"; i=$((i + 1)); done
        printf -- '\n## For future Claude\n'
        i=0; while [ $i -lt 25 ]; do echo "constant $i"; i=$((i + 1)); done
    } > "$LCV/proj/_PROJECT.md"

    # Taskboard: past all three thresholds, both closure markers.
    {
        printf -- '## In progress\n'
        i=0; while [ $i -lt 320 ]; do echo "- [ ] task $i"; i=$((i + 1)); done
        printf -- '\n## Done\n'
        i=0; while [ $i -lt 12 ]; do echo "- [x] 2026-01-01 — done $i"; i=$((i + 1)); done
        i=0; while [ $i -lt 12 ]; do echo "- ✅ 2026-01-02 — done ✅ $i"; i=$((i + 1)); done
        i=0; while [ $i -lt 300 ]; do echo "tail $i"; i=$((i + 1)); done
    } > "$LCV/proj/taskboard.md"

    # The map is older than the last session.
    printf -- '---\nupdated: 2019-01-01\n---\n# map\n' > "$LCV/proj/architecture-map.md"
    # Three sessions: two carry zone, the third does not -> key-uniformity.
    printf -- '---\ndate: 2026-06-01\nzone: root\n---\nx\n'  > "$LCV/proj/sessions/2026-06-01_1000_session.md"
    printf -- '---\ndate: 2026-06-02\nzone: back\n---\nx\n'  > "$LCV/proj/sessions/2026-06-02_1000_session.md"
    printf -- '---\ndate: 2026-02-01\n---\nx\n'              > "$LCV/proj/sessions/2026-02-01_1000_session.md"

    # Notes: one without a backlink, one without a sibling, one with no links at all.
    printf -- '---\ndate: 2026-06-01\n---\nbody [[note-sibling]]\n'         > "$LCV/proj/wiki/note-backless.md"
    printf -- '---\ndate: 2026-06-01\n---\nbody [[../_PROJECT|_PROJECT]]\n' > "$LCV/proj/wiki/note-sibling.md"
    printf -- '---\ndate: 2026-06-01\n---\nno links at all\n'              > "$LCV/proj/wiki/note-alone.md"

    # A draft older than 14 days.
    printf -- '---\ndate: 2026-01-01\nstatus: draft\n---\ndraft body\n' > "$LCV/proj/wiki/draft-old.md"

    # Decision notes: off-schema status, a broken reference, the legacy form — plus TWO
    # cases that must NOT be findings: `supersedes: ~` (YAML null) and a quotation of the
    # legacy form inside a fenced block.
    printf -- '---\nstatus: partially-superseded-by x\ndate: 2026-06-01\n---\n[[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/proj/wiki/decision-offschema.md"
    printf -- '---\nstatus: accepted\nsuperseded-by: decision-nowhere\n---\n[[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/proj/wiki/decision-brokenref.md"
    printf -- '---\nstatus: superseded-by: decision-x.md\n---\n[[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/proj/wiki/decision-legacyform.md"
    printf -- '---\nstatus: accepted\nsupersedes: ~\n---\n[[../_PROJECT|_PROJECT]]\n```\nstatus: superseded-by: decision-x.md\n```\n' \
        > "$LCV/proj/wiki/decision-clean.md"

    # An unterminated frontmatter block.
    printf -- '---\ndate: 2026-06-01\nbody with no closing rule\n' > "$LCV/proj/wiki/broken-fm.md"

    # A key a template emits EMPTY almost everywhere is not a convention. Measured
    # 2026-08-04: `supersedes:` is empty in 29 of cadrika's 32 notes, and a threshold
    # counting the key's presence declared the three lacking the empty line to be the
    # violators. Here: `supersedes:` is empty in three of four and absent in one. That
    # must not be a finding; if the threshold ever counts presence again, it will be.
    i=1; while [ $i -le 3 ]; do
        printf -- '---\nstatus: accepted\ndate: 2026-06-0%s\nsupersedes:\n---\n[[../_PROJECT|_PROJECT]] [[decision-empty-1]]\n' \
            "$i" > "$LCV/other/wiki/decision-empty-$i.md"
        i=$((i + 1))
    done
    printf -- '---\nstatus: accepted\ndate: 2026-06-04\n---\n[[../_PROJECT|_PROJECT]] [[decision-empty-1]]\n' \
        > "$LCV/other/wiki/decision-nosupersedes.md"

    # other: it IS in the registry; what it contributes is a duplicate basename
    # note-alone, which makes the bare [[note-alone]] in its note ambiguous.
    # Its `updated:` is COMPUTED, never a literal. A fixture asserting "this project is
    # NOT stale" against a hardcoded date decays into a red on a fixed calendar day with
    # nobody touching the code: written 2026-08-04 as `2026-08-01`, it crossed the 14-day
    # threshold on 2026-08-16 and failed the whole gate. Every other date here is
    # deliberately ancient (2020, 2026-01), so only the freshness assertion needs this.
    # 13 days, not 0: it must also prove the threshold is `> 14` and not `>= 1`.
    printf -- '---\nproject: other\nupdated: %s\n---\n## Current state\nbrief\n' "$PF_FRESH" \
        > "$LCV/other/_PROJECT.md"
    printf -- '---\ndate: 2026-06-01\n---\nlink [[note-alone]] and [[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/other/wiki/note-alone.md"
    # A quotation of that same bare link in backticks must NOT be a finding. Plus an
    # unpaired backtick earlier in the file: without resetting the state on a blank line
    # it inverted the reading of everything after it (measured on the live connections.md).
    printf -- '---\ndate: 2026-06-01\n---\nparagraph with an unpaired backtick `here\n\nquoted `[[note-alone]]` in backticks [[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/other/wiki/note-quotes.md"

    # A project the registry does not know.
    mkdir -p "$LCV/unreg"
    printf -- '---\nproject: unreg\nupdated: %s\n---\n## Current state\nbrief\n' "$PF_FRESH" \
        > "$LCV/unreg/_PROJECT.md"

    # A project NESTED inside another project. This is the class the inventory kept
    # losing: measured 2026-08-04, `nf-content/MWR-Dima` — its own _PROJECT.md, its own
    # taskboard, its own wiki, an entry in the registry — was invisible to every
    # per-project check, because the project list was built from the top level. The file
    # sweeps always saw it, so the discrepancy read as a regression rather than a gap in
    # coverage.
    mkdir -p "$LCV/other/nested/sessions"
    printf -- '---\nproject: nested\nupdated: 2020-01-01\n---\n## Current state\nbrief\n' \
        > "$LCV/other/nested/_PROJECT.md"
    # A session the project file never recorded — that, not the calendar, is what
    # stale-project reports since 2026-08-16 (see check 45).
    printf -- '---\ndate: 2020-06-01\n---\nx\n' \
        > "$LCV/other/nested/sessions/2020-06-01_1000_session.md"

    # A file under .gitignore must still be found: the sweep walks the filesystem, not
    # the git index. The session shell on macOS replaces grep with ugrep --ignore-files,
    # which skips such a file silently — that must not happen here.
    printf -- 'ignored/\n' > "$LCV/.gitignore"
    mkdir -p "$LCV/ignored"
    printf -- '---\ndate: 2026-01-01\nstatus: draft\n---\nhidden draft\n' > "$LCV/ignored/hidden-draft.md"

    out="$LCV/out.txt"
    if bash "$LIBSH" lint-collect "$LCV" > "$out" 2>"$LCV/err.txt"; then :; else
        problems+="lint-collect failed on the fixture: $(head -1 "$LCV/err.txt")"$'\n'
    fi
    want() { grep -q "^$1	" "$out" || problems+="class not found: $1"$'\n'; }
    nope() { grep -q "^$1	" "$out" && problems+="false finding: $1"$'\n'; }

    # Three independent limits since 2026-08-16, never their sum: Current state (lines),
    # the session list (ENTRIES) and For future Claude (lines).
    want 'current-state:proj'
    want 'session-list:proj'
    want 'ffc-budget:proj'
    nope 'prose-budget:proj'   # the summed metric was removed — it double-counted two
                               # sections that already carry their own limits
    want 'stale-project:proj'
    want 'taskboard-inprogress:proj'
    nope 'taskboard-size:proj'   # the metric was removed 2026-08-04 — it must not come back
    want 'taskboard-done:proj'
    want 'map-stale:proj'
    want 'key-uniformity:proj/sessions'
    want 'stale-draft:proj/wiki/draft-old'
    want 'stale-draft:ignored/hidden-draft'
    want 'wiki-no-backlink:proj'
    want 'wiki-no-sibling:proj'
    want 'wiki-no-links:proj'
    want 'decision-schema:proj/wiki/decision-offschema.md'
    want 'decision-ref:proj/wiki/decision-brokenref.md'
    want 'decision-legacy:proj/wiki/decision-legacyform.md'
    want 'frontmatter:proj/wiki/broken-fm.md'
    want 'ambiguous-link:other/wiki/note-alone.md'
    want 'project-unregistered:unreg'
    want 'registry-stale:ghost'
    # The nested project must reach the per-project checks, not only the file sweeps.
    want 'stale-project:other/nested'
    want 'project-unregistered:other/nested'
    # What must not appear.
    nope 'decision-ref:proj/wiki/decision-clean.md'
    nope 'decision-legacy:proj/wiki/decision-clean.md'
    nope 'ambiguous-link:other/wiki/note-quotes.md'
    nope 'stale-project:other'
    nope 'key-uniformity:other/decisions'
    # The Done counter must see both markers: 12 + 12 = 24 > 20; either alone would miss.
    grep -q '^taskboard-done:proj	24 ' "$out" ||
        problems+="the Done counter did not add [x] and ✅ together (expected 24)"$'\n'
    # Output contract: keys are unique, or lint-diff refuses to run.
    d=$(cut -f1 "$out" | sort | uniq -d)
    [ -z "$d" ] || problems+="keys are not unique: $(printf '%s' "$d" | tr '\n' ' ')"$'\n'
    # Every line must be key<TAB>detail.
    grep -qv "	" "$out" && problems+="lines without a tab — the output contract is broken"$'\n'

    # Empty input must fail, never print a green. That has twice cost two weeks of a
    # blind release gate (mapfile, except ImportError).
    mkdir -p "$LCV/nothing"
    bash "$LIBSH" lint-collect "$LCV/nothing" >/dev/null 2>&1 &&
        problems+="lint-collect printed a green for an empty directory"$'\n'
    mkdir -p "$LCV/nomd" && printf -- '# x\n' > "$LCV/nomd/a.md"
    bash "$LIBSH" lint-collect "$LCV/nomd" >/dev/null 2>&1 &&
        problems+="lint-collect did not require a single _PROJECT.md"$'\n'
    bash "$LIBSH" lint-collect "$LCV/nope" >/dev/null 2>&1 &&
        problems+="lint-collect accepted a path that does not exist"$'\n'

    rm -rf "$LCV"
    if [ -n "$problems" ]; then
        fail "lint-collect is wrong on the fixture" "$problems"
    else
        pass "lint-collect exercised on a fixture: 20 finding classes, 4 non-findings, empty input fails"
    fi
fi

# ─── 4d. The version is never hardcoded in a template ────────────────────────
# `brain-version:` was a dead field: a literal in the brain-init template that had to be
# edited by hand at every release — and was not. Measured 2026-08-03: 8 projects carry
# "1.3", two carry "1.5.0", none carry 1.6.0, and no command read the field at all.
# The version now comes from the installed VERSION, and /brain-save stamps it.
missing=""
if grep -qE '^brain-version:[[:space:]]*"[0-9]' "$SCRIPT_DIR/commands/brain-init.md"; then
    missing+="brain-init.md: brain-version hardcoded as a literal — it will drift silently at release"$'\n'
fi
grep -q 'BRAIN_VERSION' "$SCRIPT_DIR/commands/brain-init.md" ||
    missing+="brain-init.md: the template does not substitute the version"$'\n'
grep -qE 'brain\.sh" version|brain\.sh version' "$SCRIPT_DIR/commands/brain-init.md" ||
    missing+="brain-init.md: does not say where the version comes from (call brain.sh version)"$'\n'
grep -q 'stamp-field .*brain-version' "$SCRIPT_DIR/commands/brain-save.md" ||
    missing+="brain-save.md: brain-version is not stamped — the field goes dead again"$'\n'
for s in install.sh update.sh; do
    grep -q 'lib/VERSION' "$SCRIPT_DIR/$s" ||
        missing+="$s: does not write lib/VERSION — the installed system will not know its version"$'\n'
    # The stamp must tell a clean tree from a dirty one. The normal order of work is
    # edit -> update.sh (try it) -> commit, so without --dirty VERSION records `describe`
    # from BEFORE the commit and lags silently: measured 2026-08-03, _PROJECT.md received
    # -10-g34f5287 while -12-g9a657fe was actually installed.
    grep -qE 'describe[^|]*--dirty' "$SCRIPT_DIR/$s" ||
        missing+="$s: describe without --dirty — the version stamp lags when editing before a commit"$'\n'
done
if [ -n "$missing" ]; then
    fail "the system version is not tracked (brain-version is a dead field)" "$missing"
else
    pass "the version comes from the installed VERSION and is stamped on save"
fi

# ─── 5. The legacy supersession form ─────────────────────────────────────────
# `status: superseded-by: x` — a double colon, invalid YAML: Obsidian cannot read that
# note's frontmatter at all and it drops out of every property query.
# The list is read without `mapfile`: that arrived in bash 4.0, and macOS ships
# /bin/bash 3.2. Until 2026-08-02 mapfile stood here, and on the Mac checks 5-6 did not
# run AT ALL: the array stayed unbound, grep received empty input, and both printed ✓.
# The release gate was itself falsely green on one of the two working machines.
ALL_MD=()
while IFS= read -r _f; do ALL_MD+=("$_f"); done < <(find "$SCRIPT_DIR" -name '*.md' -not -path '*/.git/*')
if [ "${#ALL_MD[@]}" -eq 0 ]; then
    fail "no .md found — checks 5-6 did not run (empty input, not a clean repository)"
fi
hits=$(strip_inline_code "${ALL_MD[@]}" | grep "status:[[:space:]]*superseded-by:" || true)
if [ -n "$hits" ]; then
    fail "one-line legacy supersession form (invalid YAML)" "$hits"
else
    pass "supersession is two fields everywhere (status + superseded-by)"
fi

# ─── 6. Bare wikilinks to non-unique names ───────────────────────────────────
# A class of bug that recurred three times (2026-07-14/15): _PROJECT.md,
# architecture-map.md, and wiki notes duplicated across projects. Obsidian resolves a
# bare link to the first shortest-path match — silently, into another project.
NONUNIQUE="_PROJECT|architecture-map|taskboard|index|connections"
hits=$(strip_inline_code "${ALL_MD[@]}" | grep -E "\[\[($NONUNIQUE)(\|[^]]*)?\]\]" || true)
if [ -n "$hits" ]; then
    fail "bare [[wikilink]] to a name that is not unique in the vault (needs an explicit path)" "$hits"
else
    pass "non-unique names are always addressed by an explicit path"
fi

# ─── 7. Frontmatter YAML validity ────────────────────────────────────────────
# A check must fail when there is nothing to run it with, or nothing to run it on. Until
# 2026-08-03 a missing python3 skipped it silently and entirely, and a missing PyYAML hit
# `sys.exit(0)` — on macOS, where the module is not installed, it printed ✓ having parsed
# not a single block. Exactly the same class as `mapfile` in checks 5-6, and found the
# same week, one function below it. Green must mean "ran and is clean", never "did not
# run". Compare check 14 and the empty-input rule.
# Interpreter candidates in order: an explicit $PYTHON, the repo's .venv, the system
# python3. The first one that can actually import PyYAML wins — "python3 exists" and
# "the check can be run" are different facts, and the script used to confuse them in
# favour of green. .venv is in .gitignore and is created once:
# python3 -m venv .venv && .venv/bin/pip install pyyaml
PYBIN=""
for cand in "${PYTHON:-}" "$SCRIPT_DIR/.venv/bin/python" python3; do
    [ -n "$cand" ] || continue
    command -v "$cand" >/dev/null 2>&1 || continue
    "$cand" -c 'import yaml' >/dev/null 2>&1 || continue
    PYBIN="$cand"
    break
done
if [ -z "$PYBIN" ]; then
    fail "no interpreter with PyYAML — the YAML check did not run" \
         "create one: python3 -m venv .venv && .venv/bin/pip install pyyaml"
else
    out=$("$PYBIN" - "$SCRIPT_DIR" 2>/dev/null <<'PY'
import sys, pathlib
import yaml
root = pathlib.Path(sys.argv[1])
n = 0
for p in sorted(root.rglob("*.md")):
    if ".git" in p.parts or ".venv" in p.parts:
        continue
    text = p.read_text(encoding="utf-8", errors="replace")
    if not text.startswith("---"):
        continue
    end = text.find("\n---", 3)
    if end == -1:
        continue
    n += 1
    try:
        yaml.safe_load(text[3:end])
    except Exception as e:
        print(f"{p.relative_to(root)}: {str(e).splitlines()[0]}")
print("PARSED %d" % n)
PY
)
    parsed=$(echo "$out" | sed -n 's/^PARSED //p')
    bad=$(echo "$out" | grep -v '^PARSED ')
    if [ -n "$bad" ]; then
        fail "invalid YAML in frontmatter" "$bad"
    elif [ -z "$parsed" ] || [ "$parsed" -eq 0 ]; then
        fail "the YAML check found no frontmatter block at all — empty input, not a clean repo"
    else
        pass "frontmatter parses in every .md ($parsed blocks)"
    fi
fi

# ─── 8. The distributed zip has not fallen behind its source ─────────────────
# Found 2026-07-22: brain-onboard.zip had not been rebuilt since 06-27 and was shipping
# v1.3 to outside users — along with the `status: superseded-by: x` form that v1.5.0
# declared invalid YAML. The artefact is built by hand, so it drifts silently.
ZIP="$SCRIPT_DIR/chat-skills/brain-onboarding/brain-onboard.zip"
ZIP_SRC="$SCRIPT_DIR/chat-skills/brain-onboarding/SKILL.md"
if [ -f "$ZIP" ] && [ -f "$ZIP_SRC" ] && command -v unzip >/dev/null 2>&1; then
    if diff -q <(unzip -p "$ZIP" 'brain-onboarding/SKILL.md' 2>/dev/null) "$ZIP_SRC" >/dev/null 2>&1; then
        pass "brain-onboard.zip matches its source SKILL.md"
    else
        fail "brain-onboard.zip has drifted from chat-skills/brain-onboarding/SKILL.md — rebuild it"
    fi
fi

# ─── 9. Conventional Commits since the rule was adopted ──────────────────────
# Adopted 2026-07-23. History before that date is not rewritten retroactively — the same
# principle as semver above. `release:` is this repo's own type for tag commits (see
# `release: adopt semver, tag v1.4.0`).
CC_CUTOFF="2026-07-23"
CC_TYPES='feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert|release'
hits=""
while IFS= read -r line; do
    [ -z "$line" ] && continue
    hash="${line%% *}"
    msg="${line#* }"
    grep -qE "^($CC_TYPES)(\([a-zA-Z0-9_.-]+\))?!?: .+" <<<"$msg" || \
        hits+="$hash: $msg"$'\n'
done < <(git -C "$SCRIPT_DIR" log --no-merges --since="$CC_CUTOFF 00:00:00" --format="%h %s" 2>/dev/null)
if [ -n "$hits" ]; then
    fail "commits since $CC_CUTOFF do not follow Conventional Commits" "$hits"
else
    pass "commits since $CC_CUTOFF follow Conventional Commits"
fi

# ─── 10. The CLAUDE.md template opens no state section ───────────────────────
# Found 2026-07-25 on the live dimarch: `## Current state` in a project CLAUDE.md had
# grown to 490 lines of dated chronicle and carried 6 facts the vault had already
# corrected. The file is loaded in full every session, before the topic is known — state
# does not belong there. The check reads the Step 4 fenced block specifically (the
# CLAUDE.md template): in the _PROJECT.md template in the same file, `## Current state`
# is legitimate.
CLAUDE_TPL=$(awk '
    /^## Step 4: Create CLAUDE.md/ { seen = 1; next }
    !seen { next }
    /^[[:space:]]*```/ { fence++; if (fence == 2) exit; next }
    fence == 1 { print }
' "$SCRIPT_DIR/commands/brain-init.md")
if [ -z "$CLAUDE_TPL" ]; then
    fail "the CLAUDE.md template was not found in brain-init.md Step 4 — the check did not run"
elif grep -qE '^#{2,3} +(Current state|Статус)' <<<"$CLAUDE_TPL"; then
    fail "the CLAUDE.md template in brain-init.md opened a state section — that belongs to _PROJECT.md"
else
    pass "the CLAUDE.md template opens no state section"
fi

# ─── 10b. The CLAUDE.md template opens no third copy of the inventory ────────
# Sibling of check 10, reading the same Step 4 fenced block. The answer to question 5
# (the stack) used to be written into three files at once: _PROJECT.md (Step 3),
# architecture-map.md (Step 3c) and CLAUDE.md (Step 4). /brain-save maintains the first
# two; nobody maintains the third, and for a public repo Step 5 puts it in .gitignore, so
# it is the one copy never seen changing. Measured 2026-08-04 on second-brain-setup
# itself: the copy still named three bash scripts six weeks after lib/brain.sh became the
# fourth, while the vault copy was correct throughout. An empty $CLAUDE_TPL is already
# handled by check 10 above.
if [ -z "$CLAUDE_TPL" ]; then
    : # check 10 already failed on this; no need to say it twice
elif grep -qE '^#{2,3} +(Stack|Стек)' <<<"$CLAUDE_TPL"; then
    fail "the CLAUDE.md template in brain-init.md opened an inventory section — that belongs to _PROJECT.md and architecture-map.md"
elif grep -qF 'ANSWER TO QUESTION 5' <<<"$CLAUDE_TPL"; then
    fail "the CLAUDE.md template in brain-init.md pastes answer 5 whole — only the constraints from it belong in Rules"
else
    pass "the CLAUDE.md template does not duplicate the stack inventory"
fi

# ─── 11. The criterion separating the three memories is present ──────────────
# The rule exists only while its text is in the prompts: SKILL.md carries the criterion
# itself, brain-save applies it in Step 0a when editing CLAUDE.md Block 2.
missing=""
grep -qi 'What belongs where' "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: no 'What belongs where' section"$'\n'
grep -qi 'can this be false tomorrow' "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: no expiry test"$'\n'
grep -qi 'expiry test' "$SCRIPT_DIR/commands/brain-save.md" || missing+="brain-save.md: Step 0a does not refer to the expiry test"$'\n'
# The fourth home, added 2026-08-05. The criterion named three memories and was silent on
# the global ~/.claude/CLAUDE.md, so a session in one project wrote a lesson from that
# project into the file every project loads — and it sat there for two days before anyone
# asked where it came from. That directory is not version-controlled, does not travel
# between machines, and no check in this package reaches it: widest reach, weakest
# guarantees. Silence in a criterion about homes reads as "no opinion", which is how the
# one place with no guard at all became a plausible place to write.
grep -qF '~/.claude/CLAUDE.md' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md: the global CLAUDE.md is not named among the homes — the one with no guard"$'\n'
grep -qi 'never written to the global\|is ever written to the global' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md: nothing forbids writing a project lesson into the global CLAUDE.md"$'\n'
# A deferral recorded as a condition expires in the world, not in the file: no date moves,
# so nothing looks stale. The rule has to be stated where every session reads it, because
# there is nothing mechanical to notice it.
grep -qi 'against its CONDITION' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md: a deferral is not stated to be checked by its condition"$'\n'
if [ -n "$missing" ]; then
    fail "lost the criterion for what lives in CLAUDE.md and what lives in the vault" "$missing"
else
    pass "the memory-separation criterion is present (SKILL.md + brain-save Step 0a)"
fi

# ─── 12. The vault is synced before writing ──────────────────────────────────
# The shared registries 00-system/*.md are edited by every session on every machine, so
# writing on top of a stale checkout guarantees a conflict at push. The step must sit
# BEFORE the first write (otherwise it is useless) and must never block the save when the
# network is down — an unsaved session costs more than a deferred sync.
# Since v1.7.0 the pull itself lives in lib/brain.sh, so the requirement is checked where
# it belongs: the mechanics in the library, the call order in the prompt. That is not a
# weakening — both halves are required and the absence of either fails the check.
BS="$SCRIPT_DIR/commands/brain-save.md"
missing=""
if [ -f "$LIBSH" ]; then
    grep -q 'pull --rebase --autostash' "$LIBSH" || missing+="lib/brain.sh: no pull --rebase --autostash"$'\n'
    grep -qE 'timeout [0-9]+ git .*pull' "$LIBSH" || missing+="lib/brain.sh: the pull is not under timeout — an unreachable remote will hang the session"$'\n'
    grep -q 'return 3' "$LIBSH" || missing+="lib/brain.sh: a conflict is not told apart from other refusals (no exit 3)"$'\n'
    grep -q 'return 2' "$LIBSH" || missing+="lib/brain.sh: an unreachable remote is not told apart from success (no exit 2)"$'\n'
else
    missing+="lib/brain.sh is missing — there is nothing to sync with"$'\n'
fi
# All four commands touch the vault, so all four sync it. Until v1.7.0 this check looked
# at brain-save only, so the gap between the Block 2 rule ("a command that writes to the
# vault") and the implementation (one command of four) was machine-invisible — the rule
# existed, three commands ignored it, and nothing showed that.
# Each pair is "command -> its first write": the sync must sit strictly above. A step
# placed after the first write is not weaker, it is inert.
for pair in \
    "brain-save.md:^## Step 0b" \
    "brain-init.md:^## Step 2" \
    "brain-ingest.md:^## Step 3" \
    "brain-lint.md:^## Step 5"; do
    cmd_name="${pair%%:*}"
    write_marker="${pair#*:}"
    cf="$SCRIPT_DIR/commands/$cmd_name"
    if [ ! -f "$cf" ]; then
        missing+="$cmd_name is missing — the sync check did not run"$'\n'
        continue
    fi
    sync_ln=$(grep -n 'vault-sync' "$cf" | head -1 | cut -d: -f1)
    write_ln=$(grep -n "$write_marker" "$cf" | head -1 | cut -d: -f1)
    if [ -z "$sync_ln" ]; then
        missing+="$cmd_name: does not call vault-sync"$'\n'
    elif [ -z "$write_ln" ]; then
        missing+="$cmd_name: first-write marker not found ($write_marker) — the ordering check did not run"$'\n'
    elif [ "$sync_ln" -ge "$write_ln" ]; then
        missing+="$cmd_name: the sync sits after the first write (line $sync_ln against $write_ln)"$'\n'
    fi
done
if [ -n "$missing" ]; then
    fail "the vault-sync-before-write step was lost" "$missing"
else
    pass "all 4 commands sync the vault before their first write, pull under timeout"
fi

# ─── 12b. Syncing before READING (the session-start protocol) ────────────────
# Symmetric to 12 and added for the same reason with the sign reversed: writing was
# closed first because a push conflict is loud, while reading is silent. A session
# routinely opens _PROJECT.md and taskboard.md in the state they had at its last visit to
# THIS machine, giving nothing away — the files are there and look current. Hence false
# conclusions that a task is open when another machine closed it yesterday.
# Two places, both required: SKILL.md reaches every project (including the 9 created
# before the rule, which no template will ever reach), and the brain-init template
# guarantees execution in new ones.
missing=""
sk="$SCRIPT_DIR/SKILL.md"
sync_ln=$(grep -n 'vault-sync' "$sk" | head -1 | cut -d: -f1)
read_ln=$(grep -n 'Always load at session start' "$sk" | head -1 | cut -d: -f1)
if [ -z "$sync_ln" ]; then
    missing+="SKILL.md: the start protocol does not sync the vault before reading"$'\n'
elif [ -z "$read_ln" ]; then
    missing+="SKILL.md: start-of-session load marker not found — the check did not run"$'\n'
fi
grep -q 'vault-sync' "$SCRIPT_DIR/commands/brain-init.md" ||
    missing+="brain-init.md: the CLAUDE.md template carries no sync step at session start"$'\n'
# In the template the step must sit above the line telling the session to read _PROJECT.md.
tpl_sync=$(grep -n 'At session start' -A6 "$SCRIPT_DIR/commands/brain-init.md" | grep 'vault-sync' | head -1 | cut -d: -f1)
[ -n "$tpl_sync" ] ||
    missing+="brain-init.md: vault-sync exists but not inside the 'At session start' block"$'\n'
if [ -n "$missing" ]; then
    fail "reading the vault is not synced — a stale checkout reads as current" "$missing"
else
    pass "session start syncs the vault before reading (SKILL.md + the brain-init template)"
fi

# ─── 13. A vault search always carries -F or -E ──────────────────────────────
# Measured 2026-08-02 on the live vault: the literal `[[architecture-map]]` without -F
# returned 304 files instead of 17 (the brackets read as a character class), and
# `docker|colima` without -E returned 1 file instead of 37 (in a basic regex `|` is not an
# operator). Both misses are silent and return a normal exit code, so the session believes
# the answer: one way it drowns in noise, the other it concludes the vault holds nothing
# and moves on. The rule is deliberately stricter than the defect — the flag is required
# even where the pattern is obviously harmless: "does this pattern contain a metacharacter"
# needs judgement, "is the flag there" needs none.
# The broken form must not be documented in these files — describe it in words, or without -r.
#
# The third silent-empty mode, added 2026-08-05 after a session in another project hit it:
# the flags above decide how a pattern is READ, the quoting decides whether the command RUNS.
# In zsh a glob matching no file is fatal — the command never starts, the shell's complaint
# is printed before any redirection reaches the command (so `2>/dev/null` cannot hide it),
# and through a pipe the status is still 0. An unquoted file-type filter therefore cancels
# the search and returns nothing, which reads exactly like a clean vault. Check 18 keeps this
# form out of the package's own prompt blocks; it cannot reach a search a session types by
# hand, and that is where it was measured — so the only defence is the rule in SKILL.md,
# which every session loads. Hence a check on the rule's presence and on its premise.
missing=""
grep -qi 'Searching the vault' "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: no section about searching the vault"$'\n'
for flag in '`grep -rF`' '`grep -rE`'; do
    grep -qF "$flag" "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: $flag is not prescribed"$'\n'
done
grep -qF -- "--include='*.md'" "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md: the quoted-glob form is not prescribed (an unquoted one cancels the search)"$'\n'
# Premise, not prose: assert the two outcomes on this machine rather than trusting the
# paragraph. Absence of zsh fails instead of skipping — "the shell is missing" and "the rule
# holds" are different facts, and only one is worth a green (same class as check 7's PyYAML).
if ! command -v zsh >/dev/null 2>&1; then
    missing+="zsh is absent — the premise of the quoting rule cannot be verified here"$'\n'
else
    zg=$(mktemp -d)
    printf 'colima\n' > "$zg/a.md"
    # Empty output is NOT the signal to assert on: a glob that expands and then matches no
    # file leaves stdout just as empty as a command the shell refused to start. Measured
    # here 2026-08-05 by planting a file the bare glob matches — the first draft of this
    # check stayed green through it, which is the "presence is not equivalence" class again.
    # What separates the two is stderr: a cancelled command leaves the shell's complaint
    # there, a grep that merely found nothing leaves it empty. Piped, so the 0 that hides
    # the failure downstream is exercised as well.
    zu=$(cd "$zg" && zsh -c 'grep -rF --include=*.md colima . | cat' 2>"$zg/err")
    zerr=$(cat "$zg/err")
    # Quoted: must find the line. Guards against a green that only means grep is broken.
    zq=$(cd "$zg" && zsh -c "grep -rF --include='*.md' colima . | cat" 2>/dev/null)
    [ -n "$zu" ] && missing+="zsh ran an unquoted glob and it matched — the premise is gone"$'\n'
    [ -z "$zerr" ] && missing+="zsh did not refuse the unquoted glob — the rule's premise no longer holds"$'\n'
    grep -qF colima <<<"$zq" ||
        missing+="the quoted form found nothing either — the test proves nothing"$'\n'
    rm -rf "$zg"
fi
for f in "${TARGETS[@]}"; do
    h=$(grep -no 'grep -r[a-zA-Z]*' "$f" | grep -vE ':grep -r[a-zA-Z]*[EF]' || true)
    [ -n "$h" ] && missing+="$(basename "$f"): bare grep -r without -F/-E on lines $(echo "$h" | cut -d: -f1 | tr '\n' ' ')"$'\n'
done
if [ -n "$missing" ]; then
    fail "a vault search is prescribed without -F/-E (silently wrong result)" "$missing"
else
    pass "vault searches always carry -F or -E, and the rule is present in SKILL.md"
fi

# ─── 14. The scripts are bash 3.2 compatible ─────────────────────────────────
# macOS ships /bin/bash 3.2 — one of the two working machines, not an exotic case.
# Incident 2026-08-02: this very file used mapfile (bash 4.0); on the Mac the array stayed
# unbound, checks 5-6 received empty input and printed ✓ without ever running. The release
# gate was blind on half the fleet for ten days.
# `bash -n` does not catch this: the syntax is valid, only the builtin is missing at
# runtime. The literals are assembled from pieces on purpose — otherwise the file would
# match itself, the same reason TARGETS excludes preflight.sh (see the header).
B4="(map""file|read""array|declare -""A|local -""A|\\\$\\{[A-Za-z_][A-Za-z0-9_]*(\\^\\^|,,)\\})"
hits=""
for s in "$SCRIPT_DIR"/*.sh; do
    h=$(grep -nE "$B4" "$s" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [ -n "$h" ] && hits+="$(basename "$s"): $h"$'\n'
done
if [ -n "$hits" ]; then
    fail "a bash 4+ construct in a script (macOS /bin/bash is 3.2)" "$hits"
else
    pass "the scripts are bash 3.2 compatible (4 bash 4+ constructs absent)"
fi

# ─── 15. /brain-lint sweeps the whole vault for ambiguous links ──────────────
# Check 6 above greps the REPOSITORY — the templates in SKILL.md and commands/. This class
# had no auditor of the vault itself: all four repairs (135+ links, 07-14, 07-15, 07-26 and
# today) were done by one-off scripts, which is why the class kept returning — no standing
# instrument could see it.
# Worse: measured 2026-08-03, authoring discipline has nothing to do with it. Five
# puzzlebot-voronka notes from 06-28…07-04 carried 33 CORRECT bare links until
# goprofi-voronka appeared on 07-29 reusing those five names — the links became ambiguous
# retroactively, with no edit to them, three days after a lint had declared the vault clean
# of this class. So it is caught only by a recurring vault-wide sweep asking "is this name
# still unique", and Step 4b must exist.
missing=""
LINT="$SCRIPT_DIR/commands/brain-lint.md"
[ -s "$LINT" ] || fail "commands/brain-lint.md is empty or missing — check 15 did not run"
LIB="$SCRIPT_DIR/lib/brain.sh"
grep -qF 'ambiguous-link:' "$LIB" || missing+="lib: no ambiguous-link sweep"$'\n'
grep -qF 'uniq -d' "$LIB" || missing+="lib: the sweep does not look for duplicate basenames (uniq -d)"$'\n'
grep -qE 'grep -rn?F' "$LIB" || missing+="lib: the sweep searches without -F"$'\n'
grep -qiE 'whatever the scope|whole vault' "$LIB" ||
    missing+="lib: the sweep is not declared vault-wide (scoped to a project it is blind)"$'\n'
grep -qF 'ambiguous-link' "$LINT" ||
    missing+="brain-lint.md: the ambiguous-link finding is undescribed — the session will not know what to do"$'\n'
grep -qiE 'already exists in another project|not unique across the whole vault' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md: the rule is narrowed to _PROJECT.md — the retroactive case is lost"$'\n'
if [ -n "$missing" ]; then
    fail "ambiguous links are not checked in the vault (this class returned 4 times)" "$missing"
else
    pass "/brain-lint Step 4b sweeps the vault for ambiguous links, and SKILL.md states the rule generally"
fi

# ─── 16. Frontmatter templates declare themselves a minimum + a lookup step ──
# A project may require keys the package cannot know (goprofi-voronka: `zone:` on session
# logs and decision notes — a monorepo split into zones). The defect was not "the template
# forgot a field": the rule sat in that project's CLAUDE.md and was loaded every session,
# but at the moment of writing a fenced block with three keys reads as exhaustive.
# An explicit template at hand beats a rule read two hundred messages ago — so the template
# must declare itself incomplete out loud, and a lookup step must sit before the write.
# Measured 2026-08-03: 4 logs of 55 and 2 decision notes of 100 without `zone:`, the last
# two on 08-01, twice in one day.
missing=""
BS="$SCRIPT_DIR/commands/brain-save.md"
grep -qF 'Step 0c' "$BS" || missing+="brain-save.md: no local-conventions lookup step (0c)"$'\n'
# The step must precede both templates, or it is inert — like a sync after the write.
c_ln=$(grep -n '^## Step 0c' "$BS" | head -1 | cut -d: -f1)
s1_ln=$(grep -n '^## Step 1:' "$BS" | head -1 | cut -d: -f1)
if [ -z "$c_ln" ] || [ -z "$s1_ln" ]; then
    missing+="brain-save.md: Step 0c or Step 1 not found — the ordering check did not run"$'\n'
elif [ "$c_ln" -ge "$s1_ln" ]; then
    missing+="brain-save.md: the lookup step sits after the first template (line $c_ln against $s1_ln)"$'\n'
fi
# Both templates — the log and the decision note — must call themselves a minimum.
grep -qiE 'minimum, not the full list' "$BS" ||
    missing+="brain-save.md: the session-log template is not declared a minimum"$'\n'
grep -qiE 'Minimum frontmatter' "$BS" ||
    missing+="brain-save.md: the decision-note template is not declared a minimum"$'\n'
# The value is derived per entry while the key carries over — a copied value lies silently.
grep -qiE 'derive each .*value|value derived' "$BS" ||
    missing+="brain-save.md: lost the rule that the key carries over and the value is derived"$'\n'
grep -qF 'key-uniformity' "$SCRIPT_DIR/lib/brain.sh" ||
    missing+="lib: no frontmatter key-uniformity check"$'\n'
grep -qF 'key-uniformity' "$SCRIPT_DIR/commands/brain-lint.md" ||
    missing+="brain-lint.md: the key-uniformity finding is undescribed"$'\n'
if [ -n "$missing" ]; then
    fail "local frontmatter conventions are unprotected (the template reads as exhaustive)" "$missing"
else
    pass "templates declare themselves a minimum, the lookup step precedes the write, lint 10b present"
fi

# ─── 17. The taskboard counter sees both markers and measures more than Done ─
# Two defects of the same "green is not the same as checked" class, found 2026-08-03.
# (1) The counter looked for `- [x]` only, while cadrika writes `- ✅` — its 16 closed
#     items were invisible, and the threshold would not have fired at a hundred either.
# (2) The threshold counted Done only, so goprofi-voronka passed as healthy at 2131 lines
#     with 1074 of them in `## In progress` — a section a session cannot hold in context,
#     which is how tasks get appended blind and duplicated.
# The same distortion was fixed for _PROJECT.md by replacing total size with a prose
# budget.
missing=""
BL="$SCRIPT_DIR/lib/brain.sh"
grep -qF '✅' "$BL" || missing+="lib: the Done counter does not know the ✅ marker"$'\n'
grep -qF '[x]' "$BL" || missing+="lib: the Done counter does not know the [x] marker"$'\n'
# This looks for the measurement itself, not the words "In progress" in prose: the first
# version of this check matched the description of the finding and would not have noticed
# the code being deleted.
grep -qE '^[[:space:]]*prog=\$\(' "$BL" ||
    missing+="lib: no measurement of the In progress section size (the prog= variable)"$'\n'
# The Done counter must count INSIDE the Done section. Measured 2026-08-03: counted
# file-wide, goprofi-voronka gave 83 against 19, dimarch 31 against 8, this repo's own
# taskboard 65 against 5 — closed sub-items of open tasks were counted as archivable
# entries.
# The counters moved into _budget_* (one implementation for the lint and for the write,
# check 25), so this reads their bodies rather than the call site. The required property
# is the same and is not weakened: the Done counter must carry a section filter.
done_body=$(awk '/^_budget_done\(\)/ { f = 1 } f { print } f && /^}/ { exit }' "$BL")
if [ -z "$done_body" ]; then
    missing+="lib: no _budget_done function — nowhere to check the Done counter"$'\n'
else
    grep -qF '## (Done|Завершено)' <<<"$done_body" ||
        missing+="lib: the Done counter does not know where the Done section is"$'\n'
    # The section pattern being present is not enough: it can sit in the body without
    # taking part in the count. The counting line must be GUARDED by that flag. Caught by
    # a negative test 2026-08-04: removing the flag from the condition left this green.
    grep -qE '^[[:space:]]*d &&' <<<"$done_body" ||
        missing+="lib: the Done counter counts file-wide, not within the Done section"$'\n'
fi
grep -qE '^BUDGET_PROG=[0-9]{2,}' "$BL" ||
    missing+="lib: the In progress section has no threshold (BUDGET_PROG)"$'\n'
grep -qF '"$prog" -gt "$BUDGET_PROG"' "$BL" ||
    missing+="lib: the In progress size is not compared against its threshold"$'\n'
grep -qF 'taskboard-inprogress:' "$BL" ||
    missing+="lib: the In progress metric was lost — only Done is measured again"$'\n'
if [ -n "$missing" ]; then
    fail "the taskboard counter is blind again (a marker or a metric)" "$missing"
else
    pass "the taskboard counter sees [x] and ✅, and measures Done + In progress + size"
fi

# ─── 18. Prompt code blocks run in the session's shell (zsh on macOS) ────────
# The bash 3.2 floor (check 14) covers *.sh — they carry their own shebang. But fenced
# blocks inside SKILL.md and commands/*.md are executed by the session's shell, and on the
# Mac that is zsh.
# Measured 2026-08-03, both silently green: `[ "$a" \< "$b" ]` fails in zsh with
# `condition expected` (a map-freshness step printed "ok" for every project, including one
# that was behind), and `for p in $LIST` does not word-split in zsh (the whole list was
# processed as a single string). The boundary drawn: anything needing shell specifics
# lives in lib/brain.sh (its own shebang, guaranteed bash); what stays in a prompt block
# must behave identically in bash and zsh.
hits=""
for f in "${TARGETS[@]}"; do
    blocks=$(code_blocks "$f")
    h=""
    # `\<` / `\>` inside [ ]: in zsh that is a redirection, not a string comparison
    echo "$blocks" | grep -nE '\[[^]]*\\[<>]' >/dev/null 2>&1 &&
        h+="  \\< or \\> inside [ ] — in zsh that is not a comparison"$'\n'
    # word-splitting an unquoted variable: zsh does not do it
    echo "$blocks" | grep -nE 'for [A-Za-z_]+ in \$[A-Za-z_{]' >/dev/null 2>&1 &&
        h+="  for ... in \$VAR — in zsh the variable is not split into words"$'\n'
    # ${var:0:1} — the indexing semantics differ
    echo "$blocks" | grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*:[0-9]+:[0-9]+\}' >/dev/null 2>&1 &&
        h+="  \${var:N:M} — the indexing differs"$'\n'
    # arrays: 0-indexed in bash, 1-indexed in zsh
    echo "$blocks" | grep -nE '\$\{[A-Za-z_]+\[[@*]\]\}' >/dev/null 2>&1 &&
        h+="  arrays — 0-indexed in bash, 1-indexed in zsh; move this into lib/"$'\n'
    # builtins zsh does not have at all
    echo "$blocks" | grep -nE '\b(map''file|read''array|declare -''A|shopt)\b' >/dev/null 2>&1 &&
        h+="  bash-only builtin — move it into lib/brain.sh"$'\n'
    # The sixth class, found 2026-08-04: the unmatched glob. In zsh that is a fatal
    # error — the command does not run AT ALL — and `2>/dev/null` does not silence it,
    # because the shell prints it before the redirection applies to the command; in bash
    # the same glob is passed through as a literal argument. Neither outcome is an empty
    # list, and the pipeline's exit code stays 0.
    # Measured on /brain-save Step 0c: `ls -1 ".../sessions/"*.md` on a project with no
    # logs — that is, on the very first save of a new project, which is what the step
    # exists for — silently produced nothing. The remedy: `find <dir> -name "<pat>"`,
    # where the pattern is quoted and find expands it, not the shell.
    g=$(unquoted_globs "$f")
    [ -n "$g" ] && h+="  unquoted glob — in zsh a non-match cancels the command:"$'\n'"$(printf '%s\n' "$g" | sed 's/^/    /')"$'\n'
    [ -n "$h" ] && hits+="$(basename "$f"):"$'\n'"$h"
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
    fail "check 18 received no files — empty input, not a clean repo"
elif [ -n "$hits" ]; then
    fail "a construct that differs between bash and zsh in a prompt code block" "$hits"
else
    pass "prompt code blocks are portable between bash and zsh (6 classes absent)"
fi

# ─── 19. A conclusion about state must verify its own premise ────────────────
# One class, found 2026-08-03 on the first save under the new code: a command performs the
# right action and attaches to it a claim whose premise nobody checked. Both instances are
# in /brain-save, and both are silent.
# (1) The version warning called projects holding `1.3` "machines that skipped update.sh".
#     That is not a stamp but a literal from the old /brain-init template: written at
#     project creation, evidence about no machine at all. Five projects were declared
#     behind when they simply had not been saved since 08-03. The formats `1.3` and
#     `v1.6.0-10-g34f5287` are not even ordered against each other.
# (2) "Delete older entries, they remain in sessions/" is a claim about one entry, not a
#     property of the section. The dropped `_mac/mac-setup` entry from 07-15 had no log
#     and still has none; its facts survived in architecture-map.md by luck, not by check.
#     The same case was caught by hand on 07-26 in goprofi-voronka and never reached the
#     rule's text.
missing=""
BS="$SCRIPT_DIR/commands/brain-save.md"
grep -qF 'Compare only real stamps' "$BS" ||
    missing+="brain-save.md: the version comparison does not require both values to be stamps"$'\n'
grep -qF 'v<MAJOR>.<MINOR>.<PATCH>' "$BS" ||
    missing+="brain-save.md: the format of a real stamp is not described"$'\n'
grep -qF 'the old `/brain-init` literal' "$BS" ||
    missing+="brain-save.md: legacy values are not named as the /brain-init literal"$'\n'
grep -qF 'not ordered against each other' "$BS" ||
    missing+="brain-save.md: the two version formats are compared as if ordered"$'\n'
grep -qF 'have not been saved since stamping' "$BS" ||
    missing+="brain-save.md: lost the correct conclusion for a legacy value (not 'an old install')"$'\n'
grep -qF 'Before deleting an entry' "$BS" ||
    missing+="brain-save.md: deleting an entry from the session list carries no precondition"$'\n'
grep -qF 'must exist. If it does not' "$BS" ||
    missing+="brain-save.md: does not require the session log of a deleted entry to exist"$'\n'
if [ -n "$missing" ]; then
    fail "a conclusion about state is drawn without checking its premise (version / entry deletion)" "$missing"
else
    pass "brain-save compares version formats and deletes no entry without a live session log"
fi

# ─── 20. A command name does not guarantee the tool ──────────────────────────
# Check 18 covers shell syntax. This one covers what a command name RESOLVES TO.
# Measured 2026-08-03 on the working Mac: `date` and `xargs` are GNU builds from Homebrew
# (gnubin on PATH), while `ls` and `grep` are shell functions from the Claude Code
# snapshot. One name, three sources, and prompt code cannot know which it gets.
# The failure looks the same every time: the command ran, the output is empty, the check
# is green. That day `date -j` (the BSD form) did not exist at all, and two lint steps
# silently returned zero findings instead of an error; caught only by diffing the baseline.
# A shebang does NOT fix this, unlike the class in check 18: `#!/bin/bash` sets the shell,
# not PATH — lib/brain.sh receives the very same binaries. So the remedy is different:
# flags that mean the same in GNU and BSD, or an explicit fallback in the code.
missing=""
# The patterns are assembled from pieces, or the check would match itself.
NONPORTABLE="date -""j|date -""d|date --""date|stat -""f |stat -""c |sed -""i|readlink -""f|grep -""P"
scanned=0
for f in "$SCRIPT_DIR/SKILL.md" "$SCRIPT_DIR"/commands/*.md "$SCRIPT_DIR"/lib/*.sh \
         "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh"; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    # a line with an explicit fallback (two forms joined by ||) is the required remedy.
    # The comment filter is anchored past the `NNN:` that -n prepends: written as `^\s*#`
    # it could never match anything, so the exclusion was dead from the first line it was
    # meant to skip, and `\s` is a GNU extension besides. Found 2026-08-04, when a comment
    # explaining check 38's defect became the first comment this check ever saw.
    h=$(grep -nE "$NONPORTABLE" "$f" | grep -v '||' | grep -vE '^[0-9]+:[[:space:]]*#')
    [ -n "$h" ] && missing+="$(basename "$f"):"$'\n'"$(printf '%s\n' "$h" | sed 's/^/  /')"$'\n'
done
# The second half of the same class, and it is about the name rather than a flag: `ls` in
# a prompt block is executed by the session's shell, where it can be anything. Measured
# 2026-08-04 on this machine: `ls` is the function `eza --icons=auto` from ~/.zshrc, picked
# up into the Claude Code snapshot. The comment above named `ls` as an example of the
# problem from the start, while the pattern list did not contain it, because the check was
# looking for flags. Parsing the formatted output of somebody else's `ls` is not what a
# command step should rest on: `find` expands the pattern itself and has no output variants.
# Scope is prompts only: a script run as `bash lib/brain.sh` does not inherit shell
# functions (they are not exported), so there `ls` is the real binary.
for f in "${TARGETS[@]}"; do
    [ -f "$f" ] || continue
    h=$(code_blocks "$f" | grep -nE '(^|[|;(&]|[[:space:]])ls([[:space:]]|$)')
    [ -n "$h" ] && missing+="$(basename "$f") — an ls call in a prompt block (in the session shell it may be a function):"$'\n'"$(printf '%s\n' "$h" | sed 's/^/  /')"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "check 20 opened no files — empty input, not a clean repo"
elif [ -n "$missing" ]; then
    fail "a name that resolves unpredictably, with no fallback (a shebang does not fix it)" "$missing"
else
    pass "non-portable flags and command names are absent or have a fallback ($scanned files)"
fi

# ─── 21. The lint declares its coverage instead of assuming it ───────────────
# A sync makes a checkout CURRENT, not WHOLE: sparse-checkout leaves tracked paths outside
# the working tree, and every lint check then measures a subset while still calling the
# result a pass over the vault. From inside a check, "the file is absent" and "the file was
# never checked out" are indistinguishable — only this step can tell them apart.
# Measured 2026-08-04 on the Mac with /_arch excluded (228 files): `obsidian unresolved`
# reported 93 broken links, 91 of which pointed at files that exist and are correct on the
# other machine; with the exclusion removed, 1 remained. Plus three baseline findings went
# GONE without being fixed: the baseline is shared across machines while visibility is
# per-machine, so --seal from a partial checkout erases the other machine's findings and
# the next run there reports them as NEW. There is no saving in it either — ~4% of the
# checkout — and no privacy: the objects are in .git and readable via `git cat-file`.
lf="$SCRIPT_DIR/commands/brain-lint.md"
if [ ! -f "$lf" ]; then
    fail "check 21: commands/brain-lint.md is missing — empty input, not a clean repo"
else
    missing=""
    grep -qF 'core.sparseCheckout' "$lf" || missing+="does not detect sparse-checkout"$'\n'
    grep -qF 'ls-files -v' "$lf" || missing+="does not catch skip-worktree (the config alone is not enough)"$'\n'
    grep -qF 'PARTIAL' "$lf" || missing+="nothing marks partial coverage"$'\n'
    grep -qE 'Coverage:' "$lf" || missing+="the report template has no coverage line"$'\n'
    grep -qE 'Do not .*--seal|не .*--seal' "$lf" || missing+="does not forbid --seal from a partial checkout"$'\n'
    if [ -n "$missing" ]; then
        fail "brain-lint does not declare its actual coverage — the report will pretend to be complete" "$missing"
    else
        pass "the lint detects a partial checkout, declares coverage, and does not seal from one"
    fi
fi

# ─── 22. The rule about links in notes is meetable and measured ──────────────
# The rule demanded "at least 2 [[wikilinks]] per note", while the decision-note template
# in brain-save produced `[[../_PROJECT]]` plus an optional placeholder — so a note that is
# first on its topic was born in violation, and 6 of 383 were (measured 2026-08-04).
# A bar the project's own template cannot clear is not a standard but a permanent
# violation; it also pushes people to invent links, and a fabricated relation costs more
# than a missing one, because the graph is read as evidence that a relation holds. The rule
# was rewritten as "the backlink is mandatory, a sibling when one exists" and got lint step
# 4c.
missing=""
if [ ! -f "$SCRIPT_DIR/SKILL.md" ] || [ ! -f "$SCRIPT_DIR/commands/brain-lint.md" ]; then
    fail "check 22: no SKILL.md or brain-lint.md — empty input, not a clean repo"
else
    grep -qE 'Minimum 2 \[\[|minimum 2 \[\[' "$SCRIPT_DIR/SKILL.md" \
        && missing+="SKILL.md still demands the unmeetable minimum of 2 links"$'\n'
    grep -qF 'backlink is mandatory' "$SCRIPT_DIR/SKILL.md" \
        || missing+="SKILL.md does not declare the backlink mandatory"$'\n'
    grep -qF 'wiki-no-backlink' "$SCRIPT_DIR/lib/brain.sh" \
        || missing+="lib: the rule has no machine check (no wiki-no-backlink)"$'\n'
    grep -qF 'wiki-no-links' "$SCRIPT_DIR/lib/brain.sh" \
        || missing+="lib: terminal notes are not identified"$'\n'
    grep -qF '_lc_strip' "$SCRIPT_DIR/lib/brain.sh" \
        || missing+="lib: inline code is not stripped — literals will be counted as links"$'\n'
    grep -qF 'wiki-no-sibling' "$SCRIPT_DIR/commands/brain-lint.md" \
        || missing+="brain-lint.md: does not say that a missing sibling link is not a defect"$'\n'
    if [ -n "$missing" ]; then
        fail "the link rule is unmeetable or unmeasured" "$missing"
    else
        pass "the link rule is meetable (backlink + a sibling when one exists) and measured by step 4c"
    fi
fi

# ─── 23. A convention is a key with a VALUE, not the key itself ──────────────
# Step 10b treated a key as a convention by mere presence. The decision-note template emits
# `supersedes:` empty and hardly anyone fills it in — so it counted as a convention, after
# which notes lacking that empty line were declared violators. Measured 2026-08-04: empty or
# absent in 29 of 32 in cadrika, 95 of 100 in goprofi-voronka, 33 of 34 here. The finding was
# noise sitting in a shared baseline, where a green line beside it reads as verified.
# A false finding costs more than a missed one: it trains the reader to skim the list.
# Along the way: `ls` in the old code is the same class as `date -j` (on the Mac it is a
# wrapper function around eza), so counting files moved to find.
lb="$SCRIPT_DIR/lib/brain.sh"
if [ ! -f "$lb" ]; then
    fail "check 23: lib/brain.sh is missing — empty input, not a clean repo"
else
    missing=""
    grep -qF 'only when it carries a VALUE' "$lb" \
        || missing+="10b does not require a non-empty value — an empty template key becomes a convention"$'\n'
    # The pattern is assembled from pieces: otherwise the check would match itself, as
    # check 20 already did on prose where the broken form was quoted verbatim.
    LSCOUNT="ls"" -1 \*\.md"
    grep -qE "$LSCOUNT" "$lb" \
        && missing+="10b counts files with ls (on the Mac that is a wrapper function)"$'\n'
    if [ -n "$missing" ]; then
        fail "Step 10b mistakes a template artefact for a convention" "$missing"
    else
        pass "Step 10b counts only a key with a value as a convention, and counts files with find"
    fi
fi

# ─── Shell script syntax ─────────────────────────────────────────────────────
echo ""
# ─── 25. Budgets are measured at write time, by the lint's own code ──────────
# A threshold only /brain-lint measures is measured a day later by whoever happens to run
# it: the session that CREATED the overrun never learns of it, and it is attributable to
# nobody. Measured 2026-08-03: `_mac/mac-setup` grew 51->62 and 28->35 in a save at 22:03
# and surfaced an hour later on another machine; in the single session 2240 this project's
# own `_PROJECT.md` crossed its budget FOUR times through ordinary status edits, each time
# announced only by a hand-run lint.
# The second half of the check is about there being one implementation. Two copies of a
# threshold drift, and then a "finding" becomes something only one of the two callers can
# see; this project has met that exact shape in four checks already.
bs="$SCRIPT_DIR/commands/brain-save.md"
lb="$SCRIPT_DIR/lib/brain.sh"
missing=""
if [ ! -f "$bs" ] || [ ! -f "$lb" ]; then
    fail "check 25: no brain-save.md or lib/brain.sh — empty input, not a clean repo"
else
    grep -qF 'prose-budget' "$bs" || missing+="brain-save does not call prose-budget"$'\n'
    # Ordering: measuring the taskboard before Step 4 edits it measures the wrong thing.
    n_tb=$(grep -n '^## Step 4:' "$bs" | head -1 | cut -d: -f1)
    n_pb=$(grep -n 'brain-budget\|prose-budget' "$bs" | head -1 | cut -d: -f1)
    if [ -n "$n_tb" ] && [ -n "$n_pb" ]; then
        [ "$n_pb" -gt "$n_tb" ] || missing+="the prose-budget call sits ABOVE the taskboard edit — it measures the previous state"$'\n'
    else
        missing+="Step 4 or the prose-budget call not found — the ordering could not be checked"$'\n'
    fi
    grep -qE 'не заканчивать молча|Never finish the save silently' "$bs" ||
        missing+="an overrun is allowed to finish silently"$'\n'
    # One implementation: the thresholds are variables, and lint_collect reads the same ones.
    for v in BUDGET_CURRENT BUDGET_SESSIONS BUDGET_FFC BUDGET_DONE BUDGET_PROG; do
        n=$(grep -c "^$v=" "$lb")
        [ "$n" -eq 1 ] || missing+="$v is defined $n time(s), it must be exactly one"$'\n'
        grep -qF "\$$v" "$lb" || missing+="$v is used nowhere"$'\n'
    done
    # Verified by RUNNING it on a fixture rather than grepping shape: three outcomes must differ.
    fx=$(mktemp -d)
    printf -- '---\nupdated: %s\n---\n## Current state\none line\n' "$PF_ANCIENT" > "$fx/_PROJECT.md"
    printf -- '# tb\n## In progress\n- [ ] one\n## Done\n- [x] 2020-08-01 done\n' > "$fx/taskboard.md"
    bash "$lb" prose-budget "$fx/_PROJECT.md" "$fx/taskboard.md" >/dev/null 2>&1
    [ $? -eq 0 ] || missing+="within budget the exit code is not 0"$'\n'
    # over budget: inflate For future Claude past its threshold
    { printf -- '---\nupdated: %s\n---\n## For future Claude\n' "$PF_ANCIENT"
      i=0; while [ $i -lt 40 ]; do echo "- line $i"; i=$((i + 1)); done; } > "$fx/_PROJECT.md"
    bash "$lb" prose-budget "$fx/_PROJECT.md" "$fx/taskboard.md" >/dev/null 2>&1
    [ $? -eq 2 ] || missing+="an overrun does not give exit 2"$'\n'
    # The three sections are limited independently, never as a sum. A file whose sections
    # are each within their own limit must pass even when they add up past the old 60:
    # `For future Claude` carries its own threshold and `Последняя сессия` is governed by
    # an entry count, so summing them punished a project twice for one thing and left the
    # only unregulated section — Current state — with whatever remained.
    { printf -- '---\nupdated: %s\n---\n## Current state\n' "$PF_ANCIENT"
      i=0; while [ $i -lt 25 ]; do echo "state line $i"; i=$((i + 1)); done
      printf -- '\n## Последняя сессия\n'
      i=0; while [ $i -lt 5 ]; do echo "2026-01-0$((i + 1)) — entry $i"; echo "  wrapped line"; i=$((i + 1)); done
      printf -- '\n## For future Claude\n'
      i=0; while [ $i -lt 18 ]; do echo "- constant $i"; i=$((i + 1)); done; } > "$fx/_PROJECT.md"
    out=$(bash "$lb" prose-budget "$fx/_PROJECT.md" "$fx/taskboard.md" 2>&1); rc=$?
    [ "$rc" -eq 0 ] ||
        missing+="53 lines across three sections, each within its own limit, still reads as an overrun"$'\n'
    grep -q 'session list (entries): 5/' <<<"$out" ||
        missing+="the session list is not measured in entries"$'\n'
    # Six entries must trip it even though they are fewer lines than five wordy ones.
    { printf -- '---\nupdated: %s\n---\n## Последняя сессия\n' "$PF_ANCIENT"
      i=0; while [ $i -lt 6 ]; do echo "2026-01-0$((i + 1)) — entry $i"; i=$((i + 1)); done; } > "$fx/_PROJECT.md"
    bash "$lb" prose-budget "$fx/_PROJECT.md" "$fx/taskboard.md" >/dev/null 2>&1
    [ $? -eq 2 ] || missing+="a sixth session entry does not trip the limit"$'\n'
    # a counter did not run: that is an error, not "within budget"
    sed 's|^_budget_ffc()   { _lc_section|_budget_ffc()   { _no_such_counter|' "$lb" > "$fx/broken.sh"
    if cmp -s "$fx/broken.sh" "$lb" || [ ! -s "$fx/broken.sh" ] || ! bash -n "$fx/broken.sh" 2>/dev/null; then
        missing+="META: the counter breakage did not apply — the test would be checking its own typo"$'\n'
    else
        bash "$fx/broken.sh" prose-budget "$fx/_PROJECT.md" "$fx/taskboard.md" >/dev/null 2>&1
        [ $? -eq 1 ] || missing+="a counter that did not run gives no exit 1 (green instead of an error)"$'\n'
    fi
    rm -rf "$fx"
    if [ -n "$missing" ]; then
        fail "the budget is not measured at write time, or is measured by a second implementation" "$missing"
    else
        pass "prose-budget runs after the writes, tells three outcomes apart, thresholds in one place"
    fi
fi

# ─── 35. Key comparison is locale-independent ────────────────────────────────
# The baseline is written on one machine and compared on another, and `comm` requires both
# inputs sorted the same way. Collation is locale-dependent: measured 2026-08-04, the C
# locale orders `Note-Alone.md` before `note-alone.md` while en_US.UTF-8 orders them the
# other way. Feed comm two differently-ordered lists and it reports the SAME key as both
# NEW and GONE in one run — the exact fake delta lint-diff exists to prevent — while its
# "input is not in sorted order" warning goes to stderr, which nothing surfaces.
# Found before a cross-machine verification run, where it would have poisoned every
# comparison and been read as regressions.
# The fix is per-command, never global: under LC_ALL=C the Cyrillic character classes that
# match a Russian vault stop working, so exporting it for the whole script would trade one
# silent blindness for another. This check enforces exactly that shape.
missing=""
LBK="$SCRIPT_DIR/lib/brain.sh"
if [ ! -f "$LBK" ]; then
    fail "check 35: no lib/brain.sh — empty input, not a clean repo"
else
    # Every sort or comm whose output is compared across machines must be pinned.
    unpinned=$(grep -nE '(^|[^C=])\b(sort|comm) ' "$LBK" |
               grep -vE '^[0-9]+:[[:space:]]*#' |
               grep -vE 'LC_ALL=C (sort|comm)' |
               grep -vE 'sort \| tail -1|sort$|\| sort -u \| tr')
    [ -n "$unpinned" ] &&
        missing+="  sort/comm без LC_ALL=C (порядок разойдётся между машинами):"$'\n'"$(printf '%s\n' "$unpinned" | cut -c1-90 | sed 's/^/    /')"$'\n'
    # And the reverse: it must NOT be global, or the Russian patterns go blind.
    grep -qE '^[[:space:]]*export LC_ALL' "$LBK" &&
        missing+="  LC_ALL экспортирован глобально — кириллические классы перестанут матчиться"$'\n'
    # Behavioural half: the same key set must diff clean against itself under either locale.
    kf=$(mktemp -d)
    printf 'ambiguous-link:other/Note-Alone.md\tx\nambiguous-link:other/note-alone.md\ty\nstale-project:_arch/dimarch\tz\n' > "$kf/f.txt"
    LC_ALL=C       bash "$LBK" lint-diff "$kf/base.txt" --seal < "$kf/f.txt" >/dev/null 2>&1
    out=$(LC_ALL=en_US.UTF-8 bash "$LBK" lint-diff "$kf/base.txt" < "$kf/f.txt" 2>&1)
    case "$out" in
        *NEW*|*GONE*) missing+="  тот же набор ключей дал дельту при смене локали: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90)"$'\n' ;;
    esac
    rm -rf "$kf"
    if [ -n "$missing" ]; then
        fail "key comparison depends on the locale — fake NEW and GONE between machines" "$missing"
    else
        pass "key comparison is locale-independent (sort/comm pinned to LC_ALL=C, never exported)"
    fi
fi

# ─── 36. lib/ prints data, not prose: everything it emits is English ─────────
# The companion to check 34. That one says a REPORT is in the owner's language; this one
# says the strings `lib/brain.sh` emits are not a report — they are data a session renders.
# The boundary is drawn by who prints it, which a check can see, rather than by what kind
# of text it is, which needs a judgement per string.
# Why it matters beyond tidiness: a finding detail is written into
# `00-system/lint-baseline.txt`, which is committed to the vault and read on every machine.
# Localising it would make a change of working language rewrite the entire baseline.
# Measured 2026-08-04: the details had been Russian (`66 строк при бюджете ~60`) and the
# same session that wrote the language rule turned them English while turning the report
# labels the other way — the file ended up half and half, and nothing could tell.
# Scope is emitted strings only. The awk/grep PATTERNS in this file are Russian on purpose
# (check 33 requires it) and must not be confused for output — so a line is examined only
# where the Cyrillic sits inside a printf/echo format or literal.
missing=""
scanned=0
for f in "$SCRIPT_DIR"/lib/*.sh; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    h=$(awk '
        # heredocs are usage text, scanned the same way; comments are check 32.
        /^[[:space:]]*#/ { next }
        /(printf|echo)[[:space:]]/ {
            t = $0
            # Drop everything that is a match pattern rather than a message: awk regex
            # literals /.../ and the bracketed alternations they live in.
            gsub(/\/[^\/]*\//, "", t)
            gsub(/~[[:space:]]*\/[^\/]*\//, "", t)
            if (t ~ /[А-Яа-яЁё]/) print FILENAME ":" FNR ": " $0
        }
    ' "$f")
    [ -n "$h" ] && missing+="$(printf '%s\n' "$h" | sed 's|.*/||; s/^/    /')"$'\n'
done
# And the rule must be stated where a session will read it before writing a report.
grep -q 'is not a speaker' "$SCRIPT_DIR/SKILL.md" ||
    missing+="  SKILL.md does not state that lib/ prints data in English"$'\n'
if [ "$scanned" -eq 0 ]; then
    fail "check 36 opened no files in lib/ — empty input, not a clean repo"
elif [ -n "$missing" ]; then
    fail "lib/ speaks to the user instead of emitting data" "$missing"
else
    pass "lib/ emits English data, the rule is stated in SKILL.md ($scanned files)"
fi

# ─── 37. A matched section name is an identifier: English in every template ──
# Decided 2026-08-04. A matched name is what prose-budget, sweep-closed, archive and
# /brain-lint search for literally, so it is an identifier and identifiers are not
# translated. The Russian spellings stay in every alternation in lib/ forever (check 33
# enforces that) — they are how existing files keep working, not an option for a new one.
# What this replaces: "pick the spelling that fits the vault's language", which had no way
# to converge. Measured 2026-08-04 on the live vault — all 9 taskboards English, while
# _PROJECT.md split 6 projects to 4, and a /brain-init run following the instruction
# literally produced a Russian taskboard unlike any of the nine.
# Templates only. Vault CONTENT is never rewritten by this rule, and this check never
# looks at the vault.
missing=""
scanned=0
for f in "$SCRIPT_DIR"/commands/*.md; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    # A heading inside a fenced block is a template being written out.
    h=$(awk '
        /^[[:space:]]*```/ { inb = !inb; next }
        inb && /^#{2,3} +(Статус|Последняя сессия|В работе|Завершено|Бэклог)/ {
            print FILENAME ":" FNR ": " $0 }
    ' "$f")
    [ -n "$h" ] && missing+="$(printf '%s\n' "$h" | sed 's|.*/||; s/^/    /')"$'\n'
done
# The taskboard template is where the gap was: Step 3 carried a whole subsection on
# heading language and Step 3b none, while the taskboard is made of matched sections.
grep -q 'Every heading here is a matched section' "$SCRIPT_DIR/commands/brain-init.md" ||
    missing+="  brain-init Step 3b does not say its headings are matched sections"$'\n'
# And the rule that makes the Done threshold satisfiable at all. The set of files that
# must carry it is DERIVED, not listed: any command that creates a Done section or hands
# entries to `archive` is a place where an entry gets closed, so a sixth such command is
# caught by this check rather than by someone remembering to extend it.
# The assertion is a line carrying BOTH the date format and a closing verb, not the format
# alone. The first version grepped `YYYY-MM-DD`, which appears 5 times in brain-save.md as
# a session-log filename — so it stayed green with the rule deleted, and its own negative
# test said so. A check that can pass without the property holding is worse than none.
for f in "$SCRIPT_DIR"/commands/*.md; do
    [ -f "$f" ] || continue
    writes_done=$(awk '
        /^[[:space:]]*```/ { inb = !inb; next }
        (inb && /^#{2,3} +Done/) || /brain\.sh archive/ { n++ }
        END { print n + 0 }' "$f")
    [ "$writes_done" -gt 0 ] || continue
    states_rule=$(grep -cE 'YYYY-MM-DD.*clos|clos.*YYYY-MM-DD' "$f")
    [ "$states_rule" -gt 0 ] ||
        missing+="  $(basename "$f") closes Done entries but never says one carries a date"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "check 37 opened no command files — empty input, not a clean repo"
elif [ -n "$missing" ]; then
    fail "a template writes a matched section in Russian, or the dating rule is missing" "$missing"
else
    pass "templates write matched sections in English, closed entries carry a date ($scanned files)"
fi

# ─── 34. Reports are in the owner's language, identifiers are not ────────────
# Until 2026-08-04 nothing said what language a command should ADDRESS THE USER in. The
# Result blocks were hardcoded English while the surrounding prose followed whatever the
# session happened to be speaking — so the answer was "by accident", and for a
# Russian-speaking owner it came out half and half.
# The setting already existed and was read by nobody for this purpose: the working
# language in 00-shared/CRITICAL_FACTS.md, via `brain.sh vault-language`.
# The half that is easy to get wrong is the exception. Identifiers must NOT be translated:
# a finding key is what `lint-diff` compares, so a translated key reads as one finding
# appearing and another vanishing in the same run — a fabricated delta on both sides.
# Every command that prints a Result block must therefore say both halves.
missing=""
scanned=0
grep -qF 'Language of everything you say to the user' "$SCRIPT_DIR/SKILL.md" ||
    missing+="  SKILL.md: нет общего правила о языке обращения"$'\n'
grep -qF 'Identifiers are never translated' "$SCRIPT_DIR/SKILL.md" ||
    missing+="  SKILL.md: не сказано, что идентификаторы не переводятся"$'\n'
for f in "$SCRIPT_DIR"/commands/*.md; do
    [ -f "$f" ] || continue
    grep -qE '^## Result' "$f" || continue      # у команды нет итогового блока — нечего проверять
    scanned=$((scanned + 1))
    grep -qF 'vault-language' "$f" ||
        missing+="  $(basename "$f"): Result-блок есть, а язык вывода не определён"$'\n'
    grep -qiE 'leave every identifier|identifiers?[^.]*exactly as' "$f" ||
        missing+="  $(basename "$f"): не сказано, что идентификаторы остаются как есть"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "this check found no Result block at all — the input is empty, not clean"
elif [ -n "$missing" ]; then
    fail "the report language is undeclared (or identifiers get translated)" "$missing"
else
    pass "reports print in the vault owner's language, identifiers are never translated ($scanned commands)"
fi

# ─── 33. Section names are matched in BOTH languages ─────────────────────────
# The tool does not switch languages, it matches both name sets at once:
# (Done|Завершено), (In progress|В работе), (Current state|Статус). That is strictly
# stronger than a language setting would be, because a real vault is MIXED — measured
# 2026-08-04: second-brain-setup uses `## Current state` while _mac/mac-setup and two
# _arch projects use `## Статус`, and both must be seen by the same run.
# The danger this check exists for is us: the translation pass of 2026-08-04 walked the
# whole file replacing Russian, and these patterns are Russian. Delete one alternative
# and every check goes blind on Russian-language projects — silently, with a green
# result, because "no findings" and "cannot see the section" look identical from outside.
# The invariant is pairing, not a count: any line of CODE that matches a section name in
# a regex must carry both languages. That survives adding or removing call sites, which
# a pinned number would not.
missing=""
LB="$SCRIPT_DIR/lib/brain.sh"
if [ ! -f "$LB" ]; then
    fail "check 33: no lib/brain.sh — empty input, not a clean repo"
else
    checked=0
    while IFS='|' read -r en ru; do
        # Code lines only (a comment may legitimately quote one side), and only lines
        # where the term is used AS A PATTERN — a report label like "taskboard Done
        # (entries)" is text, not a matcher.
        orphans=$(grep -nE "$en" "$LB" |
                  grep -vE '^[0-9]+:[[:space:]]*#' |
                  grep -E '~ /|grep -qE|_lc_section' |
                  grep -vF "$ru")
        checked=$((checked + 1))
        [ -n "$orphans" ] && missing+="  '$en' is matched without '$ru':"$'\n'"$(printf '%s\n' "$orphans" | cut -c1-90 | sed 's/^/    /')"$'\n'
    done <<'PAIRS'
Done|Завершено
In progress|В работе
Current state|Статус
Last session|Последняя сессия
PAIRS
    # And the reverse: the Russian side must actually be present somewhere, or the pairs
    # above are vacuously satisfied by a file that lost both halves at once.
    # Code lines only: the file header QUOTES these patterns to explain why they stay,
    # and a comment must not be able to satisfy a check about the code. Found by the
    # negative test, which removed ЗАКРЫТО from the matcher and stayed green.
    lb_code=$(grep -vE '^[[:space:]]*#' "$LB")
    for ru in Завершено 'В работе' Статус 'Последняя сессия' ЗАКРЫТО; do
        grep -qF "$ru" <<<"$lb_code" ||
            missing+="  the pattern '$ru' disappeared from the code of lib/brain.sh"$'\n'
    done
    if [ -n "$missing" ]; then
        fail "section names are not matched in both languages — a Russian vault will go invisible" "$missing"
    else
        pass "section names are matched in both languages ($checked pairs + 5 patterns present)"
    fi
fi

# ─── 32. What the repo publishes is English: commits and code comments ───────
# The repo is public. A commit message and a code comment are read by a stranger, and by
# the next maintainer, before anything else. The language rule existed but enumerated
# FILES (`SKILL.md`, `brain-*.md`, file names, Block 1) and named neither commits nor
# comments, while the entire visible history was English.
# On 2026-08-04 eight Russian commits went out: they passed Conventional Commits (check 9
# looks at form, not language) but not the practice.
# Two things this check must tell apart, which a blunt grep conflates:
#   * heredocs in *.sh generate RUSSIAN vault files (index.md, SOUL.md) — that is the
#     user's content, not a comment;
#   * `##` headings inside templates in commands/*.md are content too.
# Translating either would break the vault, so the scope is shell comments outside
# heredocs, plus ```bash blocks in the prompts.
missing=""
scanned=0
for f in "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh" "$SCRIPT_DIR"/lib/*.sh; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    # Quoted spans inside a comment are stripped first: a comment may legitimately
    # QUOTE the Russian section names the code searches for ("Завершено", "В работе"),
    # and documenting that boundary must not itself count as a violation — the same
    # reason strip_inline_code exists for the markdown checks.
    h=$(awk '
        /<<[[:space:]]*.?(EOF|USAGE|LY|PY)/ { inhd = 1; next }
        /^[[:space:]]*(EOF|USAGE|LY|PY)[[:space:]]*$/ { inhd = 0; next }
        !inhd && /^[[:space:]]*#/ {
            t = $0
            gsub(/"[^"]*"/, "", t)
            gsub(/`[^`]*`/, "", t)
            gsub(/[^ \t]+\.md/, "", t)      # a filename, not prose — same as in commits
            if (t ~ /[А-Яа-яЁё]/) print FILENAME ":" FNR ": " $0
        }
    ' "$f")
    [ -n "$h" ] && missing+="$(printf '%s\n' "$h" | sed 's|.*/||; s/^/    /')"$'\n'
done
for f in "$SCRIPT_DIR/SKILL.md" "$SCRIPT_DIR"/commands/*.md; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    h=$(awk '
        /^[[:space:]]*```/ { inb = !inb; lang = inb ? substr($0, 4) : ""; next }
        inb && lang ~ /^(bash|sh)/ && /^[[:space:]]*#/ && /[А-Яа-яЁё]/ {
            print FILENAME ":" FNR ": " $0 }
    ' "$f")
    [ -n "$h" ] && missing+="$(printf '%s\n' "$h" | sed 's|.*/||; s/^/    /')"$'\n'
done
# Commit messages, from the date the rule was adopted. History before it is not rewritten,
# the same boundary as check 9.
LANG_SINCE="2026-07-23"
# Subject AND body: the first version looked at `%s` alone and reported zero while two
# commit bodies carried Cyrillic. A check that measures less than it claims is the very
# defect this file exists to catch.
# Filenames are stripped by SHAPE, not against the tracked list: a rename commit names
# the OLD file too, and that name is by definition no longer tracked. A token ending in
# .md is a filename, not prose — ВТОРОЙ_МОЗГ_*.md is a legitimately Russian-named
# user-facing document and a message must be able to name it.
# Per commit, not per line. Quoted spans are stripped for the same reason as in
# comments — a commit explaining what was translated must be able to quote the Russian
# it replaced — but a quote may WRAP, and a line-based sed then sees only half of it and
# reports the commit as prose. Flatten the message first, strip, then test; report the
# commit rather than the line, which is the more useful unit anyway.
bad_msgs=""
for c in $(cd "$SCRIPT_DIR" && git log --since="$LANG_SINCE" --format='%H' 2>/dev/null); do
    body=$(cd "$SCRIPT_DIR" && git log -1 --format='%s %b' "$c" | tr '\n' ' ' |
           sed -E 's@[^[:space:]]+\.md@@g; s@"[^"]*"@@g; s@`[^`]*`@@g')
    case "$body" in
        *[А-Яа-яЁё]*) bad_msgs="$bad_msgs$(cd "$SCRIPT_DIR" && git log -1 --format='%h %s' "$c")"$'\n' ;;
    esac
done
[ -n "$bad_msgs" ] && missing+="  commit messages containing Cyrillic:"$'\n'"$(printf '%s\n' "$bad_msgs" | sed 's/^/    /')"$'\n'
# preflight.sh's own check labels. Its COMMENTS are out of scope (dev-only, never
# installed) and the exclusion was written that way — but it leaked onto the labels,
# which are a different thing: this file is tracked in a public repo and prints them.
# Measured 2026-08-04 on Arch: 2 labels of 50 came out Russian, ungrammatically
# ("4 команд"), while the other 48 were English. Nothing was watching, because the
# word "comments" in the exclusion was read as "everything in preflight.sh".
# Backtick spans are stripped for the same reason as in comments: a label may have to
# quote the Russian section name its check is about.
scanned=$((scanned + 1))
h=$(awk '
    match($0, /^[[:space:]]*(pass|fail) "/) {
        t = substr($0, RSTART + RLENGTH)
        sub(/".*/, "", t)
        gsub(/`[^`]*`/, "", t)
        if (t ~ /[А-Яа-яЁё]/) print FILENAME ":" FNR ": " $0
    }
' "$SCRIPT_DIR/preflight.sh")
[ -n "$h" ] && missing+="$(printf '%s\n' "$h" | sed 's|.*/||; s/^/    /')"$'\n'
# The rule exists in three places and must name both things in all three.
for f in "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/chat-skills/brain-onboarding/SKILL.md"; do
    [ -f "$f" ] || continue
    # A window, not a line: the rule may span a paragraph, and a line-based grep would
    # call the rule's own expanded wording a violation.
    n_rule=$(grep -c 'Language:' "$f")
    n_named=$(awk '
        /Language:/ { w = $0; for (i = 0; i < 6 && (getline nxt) > 0; i++) w = w " " nxt
                      # The exact plural phrases, not any mention of the words: the
                      # neighbouring prose ("a comment and a commit message are read by
                      # strangers") satisfied the weak version of this check, and the
                      # negative test showed it.
                      if (w ~ /commit messages/ && w ~ /code comments/) n++ }
        END { print n + 0 }' "$f")
    [ "$n_rule" -eq "$n_named" ] ||
        missing+="  $(basename "$f"): $n_rule statements of the rule, commits and comments named in $n_named"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "check 32 opened no files — empty input, not a clean repo"
elif [ -n "$missing" ]; then
    fail "Russian where the repo speaks to strangers" "$missing"
else
    pass "commits, comments and check labels are English ($scanned files)"
    # The scope is stated out loud, and now names what is IN it as well as what is out —
    # the previous wording named only the exclusion, and the labels fell through the gap.
    echo "      (preflight.sh: its check labels are in scope, its comments are not — dev-only)"
fi

# ─── 31. `grep -q` never ends a pipeline under pipefail ──────────────────────
# `set -uo pipefail` is on line 13. Under it, `grep -q` (and `-qv`) exits at the first
# qualifying input, the producer takes SIGPIPE and dies with 141, and 141 becomes the
# status of the whole pipeline — so a SUCCESSFUL match reads as a failure.
# Measured 2026-08-04: check 26 went red against a fully working warning, and — worse —
# the negative test on it reported a false "goes red", because it was red before the
# mutation too. One such line voids both the check and the test on it.
# The remedy is a here-string — `grep -q PATTERN <<<"$var"` — which is not a pipeline at
# all, so pipefail has nothing to observe and the producer cannot be signalled.
# WHAT THIS CHECK USED TO GET WRONG, and why the exemption is gone (measured 2026-08-16):
# it exempted `printf`/`echo`/`cat`/`sed`/`head -N` as producers that "finish on their own
# and take no SIGPIPE", and prescribed exactly that form as the fix. False. The race is
# decided by the OUTPUT SIZE against the pipe buffer (64 KiB on Linux), not by the kind of
# producer: with a match at 15% depth, `printf | grep -q` returned non-zero 0/200 times at
# 28 KB, 199/200 at 56 KB and 200/200 at 114 KB. Check 33 fed it 42 KB — the grey zone —
# and flapped red on ~20% of preflight runs, naming a different Russian pattern each time
# while lib/brain.sh carried all of them. A release gate that fails at random is worse
# than one that fails: its red is read as noise. So the rule is now absolute — no `grep -q`
# ends a pipeline, whatever produces the input — because "is this output under 64 KB"
# needs a judgement on every call site and grows with the vault, while "is there a pipe"
# needs none.
missing=""
scanned=0
for f in "$SCRIPT_DIR/preflight.sh" "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh"; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    # No producer is exempt (see the note above — the exemption was the defect).
    # Quoted spans are stripped first: a check may legitimately SEARCH for the string
    # "grep -q", and a pattern is data, not a pipeline. Caught by check 33's own line.
    h=$(sed -E "s@'[^']*'@@g; s@\"[^\"]*\"@@g" "$f" | grep -nE '\| *grep -q' |
        grep -vE '^\s*[0-9]+:\s*#')
    [ -n "$h" ] && missing+="$(basename "$f"):"$'\n'"$(printf '%s\n' "$h" | sed 's/^/    /')"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "check 31 opened no files — empty input, not a clean repo"
elif [ -n "$missing" ]; then
    fail "grep -q at the end of a pipeline: under pipefail the producer's SIGPIPE reads as failure" "$missing"
else
    pass "grep -q never ends a pipeline, whatever produces the input ($scanned files)"
fi

# ─── 29. No personal data goes out to the public repo ────────────────────────
# The rule "do not add personal data to this repo" stood in CLAUDE.md Block 2 from the
# start and had NO machine check — in a Block that requires a check for every rule in it.
# As prose it survives exactly until the next session, and the cost of a mistake is
# irreversible: the repo is public and what was pushed has already been cloned.
# The user name and host are NOT hardcoded but read from the environment: hardcoding them
# would be the very leak this check looks for, and would break it for everyone who
# installs the package.
missing=""
scanned=0
PD_U=$(basename "$HOME")
PD_HN=$(hostname 2>/dev/null | sed 's/\..*//')
# The key patterns are assembled from pieces, or the check would match itself.
PD_KEY="sk-""[A-Za-z0-9]{20,}|ghp_""[A-Za-z0-9]{20,}|AKIA""[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY"
PD_FILES=$(cd "$SCRIPT_DIR" && git ls-files 2>/dev/null | grep -v '^preflight\.sh$')
if [ -z "$PD_FILES" ]; then
    fail "check 29 got no file list (git ls-files empty) — empty input, not a clean repo"
else
    for f in $PD_FILES; do
        [ -f "$SCRIPT_DIR/$f" ] || continue
        scanned=$((scanned + 1))
        h=""
        [ -n "$PD_U" ] && grep -qF "/$PD_U" "$SCRIPT_DIR/$f" 2>/dev/null && h="${h}the user's home path; "
        [ -n "$PD_HN" ] && [ ${#PD_HN} -ge 4 ] && grep -qiF "$PD_HN" "$SCRIPT_DIR/$f" 2>/dev/null && h="${h}the machine name; "
        grep -qE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-z]{2,}' "$SCRIPT_DIR/$f" 2>/dev/null && h="${h}e-mail; "
        grep -qE "$PD_KEY" "$SCRIPT_DIR/$f" 2>/dev/null && h="${h}looks like a key or token; "
        [ -n "$h" ] && missing+="  $f: $h"$'\n'
    done
    if [ "$scanned" -eq 0 ]; then
        fail "check 29 opened no files — empty input, not a clean repo"
    elif [ -n "$missing" ]; then
        fail "personal data in a file of the public repo" "$missing"
    else
        pass "no personal data in the tracked files ($scanned files)"
    fi
fi

# ─── 30. Vault data is never executed ────────────────────────────────────────
# Everything in lib/ reads the vault: file names, frontmatter values, note bodies. That is
# INPUT, and part of it arrives from `raw/`, which the package itself declares untrusted.
# Verified by running it on a hostile fixture rather than by reading the code: the signal
# is not a word in the output but the tree being UNCHANGED. Any file appearing after the
# run means a substitution executed.
# What this test does NOT prove, worth writing down: removing quotes does not turn it red —
# bash does not re-parse a variable's value, so an unquoted `$p` yields word-splitting, not
# execution. Only a real vector reddens it: eval, sh -c, bash -c. Hence the static half
# beside the dynamic one — asserting their absence.
missing=""
grep -nE '\beval\b|\bsh -c\b|\bbash -c\b' "$SCRIPT_DIR"/lib/*.sh >/dev/null 2>&1 &&
    missing+="eval / sh -c / bash -c appeared in lib/ — vault data could become a command:"$'\n'"$(grep -nE '\beval\b|\bsh -c\b|\bbash -c\b' "$SCRIPT_DIR"/lib/*.sh | sed 's/^/    /')"$'\n'
ij=$(mktemp -d)
mkdir -p "$ij/00-system" "$ij/proj/wiki"
printf -- '# index\n- [[proj/_PROJECT]]\n' > "$ij/00-system/index.md"
printf -- '---\nupdated: %s\n---\n## Current state\nx\n' "$PF_ANCIENT" > "$ij/proj/_PROJECT.md"
IJ_FM='---\nstatus: draft\ndate: 2020-01-01\n---\n# x\n[[somename]]\n'
( cd "$ij/proj/wiki" || exit 1
  printf -- "$IJ_FM" > '$(touch zzz1).md'
  printf -- "$IJ_FM" > 'semi; touch zzz2.md'
  printf -- "$IJ_FM" > '`touch zzz3`.md'
  printf -- "$IJ_FM" > "quote'\"quote.md"
  printf -- "$IJ_FM" > 'space and *glob*.md'
  printf -- '---\nstatus: draft\ndate: 2020-01-01\nsupersedes: $(touch zzz4)\n---\n`touch zzz5`\n[[$(touch zzz6)]]\n' > 'hostile.md' )
n_fx=$(find "$ij/proj/wiki" -name '*.md' | wc -l | tr -d ' ')
if [ "$n_fx" -lt 6 ]; then
    fail "check 30: the hostile fixture was not created ($n_fx files) — the test would check its own typo"
    rm -rf "$ij"
else
    find "$ij" | sort > "$ij.before"
    bash "$SCRIPT_DIR/lib/brain.sh" lint-collect "$ij"                                  >/dev/null 2>&1
    bash "$SCRIPT_DIR/lib/brain.sh" prose-budget "$ij/proj/_PROJECT.md"                 >/dev/null 2>&1
    bash "$SCRIPT_DIR/lib/brain.sh" local-conventions "$ij" proj "$ij/proj/_PROJECT.md" >/dev/null 2>&1
    find "$ij" | sort > "$ij.after"
    added=$(diff "$ij.before" "$ij.after" | grep '^>' | sed 's/^> /    /')
    [ -n "$added" ] && missing+="files appeared after the run — a substitution executed:"$'\n'"$added"$'\n'
    grep -qiE 'untrusted|недовер' "$SCRIPT_DIR/SKILL.md" ||
        missing+="SKILL.md does not declare raw/ untrusted"$'\n'
    grep -qiE 'untrusted|недовер' "$SCRIPT_DIR/commands/brain-ingest.md" ||
        missing+="/brain-ingest does not declare raw/ untrusted — and it is the one that reads it"$'\n'
    rm -rf "$ij" "$ij.before" "$ij.after"
    if [ -n "$missing" ]; then
        fail "vault data can execute, or is declared trusted" "$missing"
    else
        pass "hostile names and vault content do not execute, no eval in lib/ ($n_fx fixture files)"
    fi
fi

# ─── 28. --project scopes every check but two declared exceptions ────────────
# Measured 2026-08-04: `lint-collect --project nf-content` returned 16 findings, 12 of them
# about seven OTHER projects. The scope reached the per-project loop only, while the file
# sweeps ran over the whole vault. That is not "stricter" — it is a report that does not
# mean what its header says, and it trains the reader to skim.
# Exactly two exceptions, both by construction rather than oversight:
#   ambiguous-link — a link breaks because a NAME was duplicated anywhere, so a scoped view
#     of it yields only a lower bound;
#   project-unregistered / registry-stale — a registry-versus-filesystem disagreement is a
#     vault-level fact with no owning project.
# The check runs lint-collect on a fixture rather than grepping shape: scope is behaviour.
sc2=$(mktemp -d)
mkdir -p "$sc2/00-system" "$sc2/a/wiki" "$sc2/b/wiki"
printf -- '# index\n- [[a/_PROJECT]]\n- [[b/_PROJECT]]\n' > "$sc2/00-system/index.md"
for pr in a b; do
    printf -- '---\nupdated: %s\n---\n## Current state\nok\n' "$PF_FRESH" > "$sc2/$pr/_PROJECT.md"
    printf -- '---\nstatus: draft\ndate: 2020-01-01\n---\n# n\n[[../_PROJECT|_PROJECT]]\n' > "$sc2/$pr/wiki/note-$pr.md"
done
missing=""
out=$(bash "$SCRIPT_DIR/lib/brain.sh" lint-collect "$sc2" --project a 2>/dev/null)
if [ -z "$out" ]; then
    missing+="the scoped run produced no findings — the fixture or the scope is broken"$'\n'
else
    grep -qF 'stale-draft:a/wiki/note-a' <<<"$out" ||
        missing+="a finding inside the scope was lost"$'\n'
    grep -qE ':b(/|$)' <<<"$out" &&
        missing+="another project's findings reached the scoped report: $(printf '%s\n' "$out" | grep -E ':b(/|$)' | tr '\n' ' ')"$'\n'
fi
bash "$SCRIPT_DIR/lib/brain.sh" lint-collect "$sc2" --project nosuchproj >/dev/null 2>&1 &&
    missing+="a non-existent --project did not fail the run (empty coverage reads as a clean project)"$'\n'
rm -rf "$sc2"
grep -qF 'ambiguous-link' "$SCRIPT_DIR/commands/brain-lint.md" ||
    missing+="brain-lint does not name the exception that stays vault-wide"$'\n'
if [ -n "$missing" ]; then
    fail "--project scopes too little, or fails what it should not" "$missing"
else
    pass "--project scopes the file sweeps; two declared exceptions stay vault-wide"
fi

# ─── 27. The decision note has two forms, and every source knows it ──────────
# Measured 2026-08-04 across the vault: 286 notes, median 68 lines, NOT ONE under 20 — no
# lighter form existed, so a one-sentence decision either inflated to fill the sections or
# invented content for them. 29 notes carry `Alternatives rejected` empty or one line long,
# and that inflation is visible in the files.
# The second half of the check is about sources. The decision-note body is described in
# FOUR places: brain-save, brain-ingest, SKILL.md and the chat-skill. A rule added to one
# leaves three demanding the old form — exactly how the sync step missed the chat-skill and
# ended up in the backlog. So the list of sources is not written out here by hand but
# DERIVED: a file describing the heavy form must also describe the light one. A fifth
# source is then caught by itself, with no edit to this check.
missing=""
scanned=0
for f in "$SCRIPT_DIR/SKILL.md" "$SCRIPT_DIR"/commands/*.md \
         "$SCRIPT_DIR"/chat-skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    grep -qF 'Alternatives rejected' "$f" || continue
    scanned=$((scanned + 1))
    grep -qF 'alternatives worth recording' "$f" ||
        missing+="$(basename "$(dirname "$f")")/$(basename "$f"): describes the heavy form but not the choice between forms"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "check 27 found no description of a decision note — empty input, not a clean repo"
else
    # Where there is a REAL template, the short form must be genuinely short: without the
    # heavy sections but with the same frontmatter and the mandatory backlink — otherwise
    # it is not a second form but a second schema, and property queries drift apart.
    for f in "$SCRIPT_DIR/commands/brain-save.md" "$SCRIPT_DIR/commands/brain-ingest.md"; do
        [ -f "$f" ] || { missing+="$(basename "$f") is missing"$'\n'; continue; }
        short=$(awk '/\*\*Short form:\*\*/ { s = 1; next }
                     s && /\*\*Full form\*\*/ { exit }
                     s { print }' "$f")
        if [ -z "$short" ]; then
            missing+="$(basename "$f"): no short form"$'\n'; continue
        fi
        grep -qF '[[../_PROJECT|_PROJECT]]' <<<"$short" ||
            missing+="$(basename "$f"): the short form lacks the mandatory backlink"$'\n'
        grep -qF 'status: accepted' <<<"$short" ||
            missing+="$(basename "$f"): the short form carries different frontmatter"$'\n'
        grep -qF '## Alternatives rejected' <<<"$short" &&
            missing+="$(basename "$f"): the short form carries a heavy section — that is not a second form"$'\n'
    done
    if [ -n "$missing" ]; then
        fail "the decision-note forms have drifted between sources" "$missing"
    else
        pass "the decision note has two forms, all $scanned sources agree"
    fi
fi

# ─── 26. The mover looks where the counter looks ─────────────────────────────
# `archive` only ever moved Done, while the threshold that fires is `In progress`.
# The same distortion was fixed twice already: in the Done counter (it grepped the whole
# file) and in the `_PROJECT.md` budget (it summed prose with link lists). One rule —
# measure and move the part that hurts.
# The first version of sweep-closed was going to move sections closed in their ENTIRETY.
# Measured across seven projects 2026-08-04: there are none, anywhere. The weight sits in
# sections mixing both states (goprofi has one of 1073 lines: 42 closed items and 40 open).
# Hence the unit of the move is an item, not a section; the check below pins that down.
sc_fx=$(mktemp -d)
{
  echo "# t"; echo; echo "## In progress"; echo
  echo "- [ ] open"
  echo "  - [x] closed sub-item that explains its parent"
  echo "- [x] closed top-level"
  echo "      body"
  echo; echo "## Done"; echo; echo "- [x] 2026-07-01 old"
} > "$sc_fx/tb.md"
cp "$sc_fx/tb.md" "$sc_fx/orig.md"
missing=""
BL="$SCRIPT_DIR/lib/brain.sh"
# a dry run must not write
bash "$BL" sweep-closed "$sc_fx/tb.md" >/dev/null 2>&1
cmp -s "$sc_fx/tb.md" "$sc_fx/orig.md" || missing+="the dry run changed the file"$'\n'
bash "$BL" sweep-closed "$sc_fx/tb.md" --apply >/dev/null 2>&1 ||
    missing+="sweep-closed refused a valid fixture"$'\n'
prog=$(awk '/^## /{ p = ($0 ~ /In progress/) } p' "$sc_fx/tb.md")
grep -qF 'closed sub-item' <<<"$prog" ||
    missing+="the closed SUB-item left its open parent"$'\n'
grep -qF '[x] closed top-level' <<<"$prog" &&
    missing+="the closed top-level item stayed in In progress"$'\n'
sort "$sc_fx/orig.md" > "$sc_fx/a"; sort "$sc_fx/tb.md" > "$sc_fx/b"
cmp -s "$sc_fx/a" "$sc_fx/b" || missing+="the result is not a permutation of the input"$'\n'
# Headings are not moved, items are. So a heading whose TEXT is a closure claim can end up
# standing over open items: the data is intact (the move is a permutation) but the file
# starts asserting something false, and a taskboard is read by its headings first.
# Measured 2026-08-04 in goprofi-voronka: one `### ✅ ЗАКРЫТО 03.08 …` section of 1073
# lines carried 42 closed items and 40 open ones.
cat > "$sc_fx/lying.md" <<'LY'
# t

## In progress

### ✅ ЗАКРЫТО 2026-08-01 — всё сделано
- [x] closed
- [ ] actually open

## Done

- [x] 2026-07-01 old
LY
# The output is taken into a variable rather than piped into `grep -q`. Under
# `set -o pipefail` (line 13) `grep -q` exits at the first match, the producer takes
# SIGPIPE, and the pipeline status becomes 141 — a SUCCESSFUL match reads as a failure.
# Measured right here 2026-08-04: the check went red against a fully working warning, and
# the negative test on it reported a false "goes red", because it was red before the
# mutation too.
ly_out=$(bash "$BL" sweep-closed "$sc_fx/lying.md" 2>&1)
grep -qF 'this heading claims closure' <<<"$ly_out" ||
    missing+="the move does not warn about a heading that will become false"$'\n'
# And the reverse: an honest heading raises no warning.
sed 's/✅ ЗАКРЫТО 2026-08-01 — всё сделано/Work in progress/' "$sc_fx/lying.md" > "$sc_fx/honest.md"
ho_out=$(bash "$BL" sweep-closed "$sc_fx/honest.md" 2>&1)
grep -qF 'this heading claims closure' <<<"$ho_out" &&
    missing+="the warning fires on an honest heading — a false alarm"$'\n'
# The guard is verified by RUNNING a broken copy, not by grepping for its presence.
sed 's|{ print > (w "/" (state == "moved" ? "moved" : "keep")) }|{ if ($0 !~ /body/) print > (w "/" (state == "moved" ? "moved" : "keep")) }|' "$BL" > "$sc_fx/broken.sh"
if cmp -s "$sc_fx/broken.sh" "$BL" || [ ! -s "$sc_fx/broken.sh" ] || ! bash -n "$sc_fx/broken.sh" 2>/dev/null; then
    missing+="META: the breakage did not apply — the test would be checking its own typo"$'\n'
else
    cp "$sc_fx/orig.md" "$sc_fx/tb2.md"
    bash "$sc_fx/broken.sh" sweep-closed "$sc_fx/tb2.md" --apply >/dev/null 2>&1 &&
        missing+="losing a line did not stop the write"$'\n'
    cmp -s "$sc_fx/tb2.md" "$sc_fx/orig.md" ||
        missing+="the guard refused but the file changed anyway"$'\n'
fi
rm -rf "$sc_fx"
grep -qF 'sweep-closed' "$SCRIPT_DIR/commands/brain-lint.md" ||
    missing+="/brain-lint does not name sweep-closed for the taskboard-inprogress finding"$'\n'
if [ -n "$missing" ]; then
    fail "sweep-closed moves the wrong thing, or moves without a guard" "$missing"
else
    pass "sweep-closed moves items (not sections), spares sub-items, and a refusal leaves the file intact"
fi

# ─── 24. A variable in a prompt block must be introduced somewhere ───────────
# Found 2026-08-04 by a sweep over every prompt: /brain-save Step 0c grepped
# "$PROJECT_CLAUDE_MD" — a name occurring exactly once in the whole package, in that very
# line. No assignment, no mention in prose from which a session could tell what to
# substitute. grep received an empty filename, the error went to `2>/dev/null`, the output
# was empty — and the half of the step that is the only one working for a NEW project had
# never run since it was written.
# Check 16 did not see this: it requires the step to EXIST and to sit above the templates.
# A step's presence and its executability are different facts, and a green on the first
# reads as a green on the second. Exactly the shape of `mapfile` and `except ImportError`.
# The criterion for "introduced" is deliberately broad: either an assignment in a block or
# a mention in the same file's prose. Prompt blocks are executed by a session, not only by
# a shell, and a `$PROJECT` introduced by the phrase "that is `$PROJECT`" is a legitimate
# way. Introduced nowhere is not a way — it is a typo.
missing=""
scanned=0
for f in "${TARGETS[@]}"; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    blocks=$(code_blocks "$f")
    prose=$(awk '/^[[:space:]]*```/ { inb = !inb; next } !inb' "$f")
    used=$(printf '%s\n' "$blocks" | grep -oE '\$\{?[A-Z_][A-Z0-9_]*\}?' | tr -d '${}' | sort -u)
    assigned=$(printf '%s\n' "$blocks" | grep -oE '^[[:space:]]*[A-Z_][A-Z0-9_]*=' | tr -d ' =' | sort -u)
    h=""
    for v in $used; do
        case "$v" in HOME|PATH|PWD|USER|TMPDIR|SHELL|IFS) continue ;; esac
        grep -qx "$v" <<<"$assigned" && continue
        grep -qF "\$$v" <<<"$prose" && continue
        h+="  \$$v — no assignment in a block and no mention in the file's prose"$'\n'
    done
    [ -n "$h" ] && missing+="$(basename "$f"):"$'\n'"$h"
done
if [ "$scanned" -eq 0 ]; then
    fail "check 24 opened no files — empty input, not a clean repo"
elif [ -n "$missing" ]; then
    fail "a prompt block refers to a variable with nowhere to come from" "$missing"
else
    pass "every variable in a prompt block is introduced by assignment or prose ($scanned files)"
fi

# ─── 39. The Obsidian CLI never writes; renaming is ours and keeps quotations ─
# The CLI was allowed exactly one mutating call, `obsidian move`, behind a guard, with an
# after-the-fact check of which file changed. Measured 2026-08-04, all three protections
# missed it: it wrote `"alwaysUpdateLinks": true` into the vault's .obsidian/app.json,
# repointed nothing at call time — `git status` right after showed only the note itself —
# and minutes later, while the session edited those files, the GUI rewrote their backlinks
# from its cached copy at pre-edit offsets. 8 corrupted spots in 6 files, exit 0. A check
# placed after a call cannot see damage that arrives later, so the rule is now the one a
# grep can hold whole: nothing writes through the CLI.
# The replacement is `brain.sh rename`, and it is verified by RUNNING it: the link forms
# a vault actually uses, the boundary that tells `note` from `note-two`, and the line
# between a pointer (updated) and a quotation (left as written) — the last one is why the
# renamed note's only mention in sessions/ survived that day: it was inline code.
missing=""
scanned=0
for f in "${TARGETS[@]}"; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    # Executable blocks only — a ```markdown block is a template, see exec_blocks.
    h=$(exec_blocks "$f" | grep -E 'obsidian +(move|property:set|create|delete|rm)')
    [ -n "$h" ] && missing+="$(basename "$f") — a mutating obsidian call inside a code block:"$'\n'"$(printf '%s\n' "$h" | sed 's/^/  /')"$'\n'
done
# lib/ may name the CLI only in the read-only guard and in comments explaining the ban.
# Two forms are legitimate and everything else is a finding: asking whether the binary
# exists, and the one read-only query the guard makes. `command -v obsidian` is not an
# invocation, and a whitelist of exact forms says that better than a blacklist of verbs —
# a blacklist would have to predict every subcommand the CLI grows next.
# An INVOCATION is `obsidian <subcommand>`; the function name `obsidian_available` and the
# SingletonLock path are not, which is why the word boundary excludes `_` and `/`.
h=$(grep -nE '(^|[^-_/[:alnum:]])obsidian[[:space:]]+[a-z]' "$SCRIPT_DIR/lib/brain.sh" |
    grep -vE '^[0-9]+:[[:space:]]*#' |
    grep -v 'command -v obsidian' | grep -v 'obsidian vault info=name')
[ -n "$h" ] && missing+="lib/brain.sh — a CLI call that is not the read-only guard:"$'\n'"$(printf '%s\n' "$h" | sed 's/^/  /')"$'\n'
# Both code-vs-prose state machines carry the same three rules; if one loses a rule the
# two disagree about what a quotation is, and only one of them is covered by a fixture.
for fn in '_lc_strip' 'rename_note'; do
    # Stop at the closing brace AT THE DEFINITION'S OWN INDENT. Stopping at the first
    # `}` on a line of its own ends the capture inside the embedded awk program, which
    # is where the three rules live — the first draft did exactly that and reported all
    # three as missing from a function that has them.
    body=$(awk -v f="$fn" '
        !on && $0 ~ "^[[:space:]]*" f "\\(\\) \\{" {
            on = 1; match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH); print; next }
        on { print; if ($0 == ind "}") exit }' "$SCRIPT_DIR/lib/brain.sh")
    [ -n "$body" ] || { missing+="$fn not found — the state-machine comparison had nothing to read"$'\n'; continue; }
    grep -q 'fence = !fence' <<<"$body"   || missing+="$fn lost the fenced-block rule"$'\n'
    grep -q 'incode = 0' <<<"$body"       || missing+="$fn lost the blank-line reset"$'\n'
    grep -q 'split($0, part' <<<"$body"   || missing+="$fn lost the inline-code split"$'\n'
done
# Behavioural: one fixture, every form, run for real.
rf=$(mktemp -d); mkdir -p "$rf/proj/wiki" "$rf/proj/sessions"
printf '# note\n' > "$rf/proj/wiki/note.md"
printf '# note-two\n' > "$rf/proj/wiki/note-two.md"
{ printf -- '[[note]] [[proj/wiki/note]] [[note|alias]] [[note#head]] [[note^blk]] ![[note]] [[proj/wiki/note.md]]\n'
  printf -- '[[note-two]] [[proj/wiki/note-two|two]]\n'
  printf -- 'inline `[[note]]` and `wiki/note.md`\n'; } > "$rf/proj/_PROJECT.md"
{ printf -- 'pointer [[../wiki/note]]\n\n'; printf -- '```\nquoted [[note]]\n```\n'; } > "$rf/proj/sessions/s.md"
# A name with a space, and one with shell metacharacters. Vault filenames are input:
# `for f in $(find …)` splits on the space and drops the file entirely, while the run
# still reports success for the ones it reached — measured 2026-08-04 on the first
# fixture that had such a name, and this vault carries two of them.
printf -- 'spaced [[note]]\n' > "$rf/proj/wiki/a name with spaces.md"
printf -- 'meta [[note]]\n'   > "$rf/proj/wiki/star*glob;semi.md"
# A symlink named *.md pointing outside the vault. Without -type f the sweep enumerates
# it and `cat >` follows it, rewriting the TARGET — silently, outside the vault.
mkdir -p "$rf/outside"
printf -- 'outside [[note]]\n' > "$rf/outside/target.conf"
ln -s "$rf/outside/target.conf" "$rf/proj/wiki/leak.md"
# A symlink whose BASENAME is what a later rename wants, at a path that is otherwise
# free. Obsidian resolves a bare link to it like any file, so it is a real collision —
# narrowing the uniqueness sweep to -type f would stop seeing it.
ln -s "$rf/outside/target.conf" "$rf/proj/sessions/taken-name.md"
bash "$LIBSH" rename "$rf" proj/wiki/note.md proj/wiki/renamed.md --apply >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || missing+="rename failed on a valid fixture (exit $rc)"$'\n'
[ -f "$rf/proj/wiki/renamed.md" ] || missing+="rename did not move the file"$'\n'
[ -f "$rf/proj/wiki/note.md" ] && missing+="rename left the old file behind"$'\n'
pm=$(cat "$rf/proj/_PROJECT.md")
for form in '[[renamed]]' '[[proj/wiki/renamed]]' '[[renamed|alias]]' '[[renamed#head]]' \
            '[[renamed^blk]]' '![[renamed]]' '[[proj/wiki/renamed.md]]'; do
    grep -qF "$form" <<<"$pm" || missing+="rename did not produce $form"$'\n'
done
grep -qF '[[note-two]]' <<<"$pm"  || missing+="rename damaged the longer name note-two"$'\n'
grep -qF '`[[note]]`' <<<"$pm"    || missing+="rename rewrote a quotation in inline code"$'\n'
grep -qF 'pointer [[../wiki/renamed]]' "$rf/proj/sessions/s.md" || missing+="rename skipped a pointer in sessions/"$'\n'
grep -qF 'quoted [[note]]' "$rf/proj/sessions/s.md" || missing+="rename rewrote a quotation inside a fenced block"$'\n'
grep -qF 'spaced [[renamed]]' "$rf/proj/wiki/a name with spaces.md" ||
    missing+="rename skipped a file whose name contains a space (word splitting), and still reported success"$'\n'
grep -qF 'meta [[renamed]]' "$rf/proj/wiki/star*glob;semi.md" ||
    missing+="rename skipped a file whose name carries shell metacharacters"$'\n'
grep -qF 'outside [[note]]' "$rf/outside/target.conf" ||
    missing+="rename followed a symlink and rewrote a file outside the vault"$'\n'
# A backslash in a basename is refused, not handled: awk -v reinterprets it, and both
# directions silently report success while breaking or repointing nothing.
bash "$LIBSH" rename "$rf" proj/wiki/renamed.md 'proj/wiki/tab\tnew.md' --apply >/dev/null 2>&1 &&
    missing+="rename accepted a backslash in the new basename (awk -v would reinterpret it)"$'\n'
bash "$LIBSH" rename "$rf" proj/wiki/renamed.md proj/wiki/taken-name.md --apply >/dev/null 2>&1 &&
    missing+="rename accepted a basename already taken by a symlink elsewhere in the vault"$'\n'
# Refusals: a taken basename elsewhere in the vault must stop it before anything moves.
bash "$LIBSH" rename "$rf" proj/wiki/renamed.md proj/sessions/note-two.md --apply >/dev/null 2>&1 &&
    missing+="rename accepted a basename already taken elsewhere in the vault"$'\n'
[ -f "$rf/proj/wiki/renamed.md" ] || missing+="a refused rename moved the file anyway"$'\n'
bash "$LIBSH" rename "$rf" proj/wiki/absent.md proj/wiki/x.md --apply >/dev/null 2>&1 &&
    missing+="rename accepted a source that does not exist"$'\n'
bash "$LIBSH" rename "$rf" ../outside.md proj/wiki/x.md >/dev/null 2>&1 &&
    missing+="rename accepted a path escaping the vault"$'\n'
rm -rf "$rf"
if [ "$scanned" -eq 0 ]; then
    fail "check 39 opened no files — empty input, not a clean repo"
elif [ -n "$missing" ]; then
    fail "the CLI writes to the vault, or rename mishandles a link form" "$missing"
else
    pass "the Obsidian CLI is read-only and rename repoints links without touching quotations ($scanned files)"
fi

# ─── 38. A date fallback names the time of day, or it borrows the clock ──────
# Check 20 treats any line carrying `||` as a portable fallback. That is presence, not
# correctness, and the gap between the two was a live defect for as long as the fallback
# existed: `date -j -f %Y-%m-%d "$1" +%s` parses on BSD and fills every field the format
# does not name — hours, minutes, seconds — from the CURRENT clock. So one date yields a
# different epoch on every call while the run's TODAY is frozen at the top, and an age in
# days shrinks by one the moment the run crosses a second boundary.
# Measured 2026-08-04 on Darwin with a BSD-only PATH: `2026-07-20` was 15 days old in a
# --project run and 14 days old in the full sweep, so both projects sitting exactly on the
# 14-day threshold vanished from lint-collect — 27 findings against 29, exit 0, stderr
# empty. GNU's `-d` means midnight, so the two implementations disagreed by a whole day
# even standing still: a key set that depends on which machine ran it is exactly the fake
# NEW/GONE the baseline exists to prevent.
# Static half runs everywhere. Behavioural half executes the shipped chain itself (read
# out of lib/brain.sh, never a second copy that could drift from it) and requires the
# epoch to be midnight; where the machine has no BSD date the BSD branch cannot be
# exercised at all, and the check says which of the two modes it ran in rather than
# printing one green for both.
missing=""
scanned=0
for f in "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR"/commands/*.md "$SCRIPT_DIR/SKILL.md"; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    # strip comment lines first: this rule is explained in prose that quotes the broken
    # form, and a comment must never be able to fail — or satisfy — a check about code
    h=$(grep -nE 'date -j' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v '%H')
    [ -n "$h" ] && missing+="$(basename "$f") — a BSD date parse that does not name the time:"$'\n'"$(printf '%s\n' "$h" | sed 's/^/  /')"$'\n'
done
epoch_fn=$(sed -n '/_lc_epoch() {/,/^    }/p' "$SCRIPT_DIR/lib/brain.sh")
if [ -z "$epoch_fn" ]; then
    missing+="lib/brain.sh — _lc_epoch not found; the behavioural half had nothing to run"$'\n'
else
    eval "$epoch_fn"                       # the shipped text, not a copy of it
    e1=$(_lc_epoch 2026-07-20)
    e2=$(_lc_epoch 2026-07-20)
    hms=$(date -d "@$e1" +%H%M%S 2>/dev/null || date -r "$e1" +%H%M%S 2>/dev/null || echo "??")
    if [ -z "$e1" ]; then
        missing+="_lc_epoch returned nothing — no working date(1) here, which is a failure and not a skip"$'\n'
    elif [ "$e1" != "$e2" ]; then
        missing+="_lc_epoch is not deterministic: $e1 then $e2 for one date"$'\n'
    elif [ "$hms" != "000000" ]; then
        missing+="_lc_epoch resolves a bare date to $hms, not to midnight — it is reading the clock"$'\n'
    fi
    # The branch under test is the SECOND one, and the first shadows it: wherever GNU date
    # answers, the BSD form is never reached, so the assertions above are about a line that
    # did not run. Caught by the differentiating negative test — a fallback rewritten to
    # read the clock stayed green here while the static half was satisfied. So where a BSD
    # date exists, run the shipped chain again with a PATH that offers only that one.
    mode="GNU branch only (this machine has no BSD date)"
    gap "the BSD branch of the date fallback (check 38) — no BSD \`date\` on this machine; run on macOS with PATH=/usr/bin:/bin"
    if /bin/date -j -f "%Y-%m-%d %H:%M:%S" "2026-07-20 00:00:00" +%s >/dev/null 2>&1; then
        mode="both branches, BSD included"
        pf_ed=$(mktemp -d); pf_bsd="$pf_ed/epoch_bsd.sh"
        { printf '%s\n' "$epoch_fn"; printf '%s\n' '_lc_epoch 2026-07-20'; } > "$pf_bsd"
        b1=$(PATH=/usr/bin:/bin /bin/bash "$pf_bsd" 2>/dev/null)
        if [ -z "$b1" ]; then
            missing+="the BSD branch returned nothing under a BSD-only PATH"$'\n'
        elif [ "$b1" != "$e1" ]; then
            missing+="the two branches disagree for one date: GNU $e1, BSD $b1 — the age in days differs by machine"$'\n'
        fi
        rm -rf "$pf_ed"
    fi
fi
if [ "$scanned" -eq 0 ]; then
    fail "check 38 opened no files — empty input, not a clean repo"
elif [ -n "$missing" ]; then
    fail "a date parse borrows the current clock (silently shifts an age by a day)" "$missing"
else
    pass "a bare date resolves to midnight and does not move — $mode ($scanned files)"
fi

# ─── 40. An existing project CLAUDE.md is audited, not only the template ─────
# Checks 10 and 10b guard the template /brain-init writes, and Step 0a of /brain-save
# states the rules in prose — both act at CREATION. A file that acquired a state section
# afterwards was governed by nothing, and the file is loaded in full at every session
# start. Measured 2026-08-05 across the live projects: 2 of 7 carried `## Current state`,
# 3 carried a `Stack` inventory, and one state section claimed 30 tables against 45 on
# disk — found by a person reading the file, not by a check.
# Verified by RUNNING the subcommand, never by grepping its shape: the classes it must
# separate (a heading LED by a date against a rule that merely cites one) were calibrated
# against real files, and only a fixture can hold that boundary still.
bs="$SCRIPT_DIR/commands/brain-save.md"
lb="$SCRIPT_DIR/lib/brain.sh"
missing=""
if [ ! -f "$bs" ] || [ ! -f "$lb" ]; then
    fail "check 40: no brain-save.md or lib/brain.sh — empty input, not a clean repo"
else
    grep -qF 'claude-md-audit' "$bs" || missing+="brain-save never audits the project CLAUDE.md"$'\n'
    # Unconditional, or it inherits the defect it was written to fix: Step 0a is skippable,
    # and a check that only runs when a session already had a reason to open the file adds
    # nothing over the prose that is there.
    grep -qE 'runs on every save|на каждом сохранении' "$bs" ||
        missing+="the audit is not stated to run on every save — Step 0a is skippable"$'\n'
    cm=$(mktemp -d)
    run_audit() {  # <fixture-body> <expected-rc> <label>
        printf '%s' "$1" > "$cm/CLAUDE.md"
        bash "$lb" claude-md-audit "$cm/CLAUDE.md" >/dev/null 2>&1
        [ "$?" -eq "$2" ] || missing+="$3"$'\n'
    }
    run_audit '# p

## Rules
- pnpm, never npm (adopted 2026-07-20)
' 0 "a clean file does not exit 0"
    run_audit '# p

## Current state
phase two
' 2 "an English state section is not reported"
    # Both spellings, always: a fleet is mixed, and a pattern knowing one language reports
    # zero for a project using the other.
    run_audit '# p

## Статус
фаза два
' 2 "a Russian state section is not reported"
    run_audit '# p

### Stack and tools
- bash
' 2 "an inventory section is not reported"
    run_audit '# p

### 2026-07-25
what happened
' 2 "a heading led by a date is not reported"
    # The calibrated boundary, and the reason the discriminator is three tokens rather
    # than "any date in a heading": this exact heading is live in excalipoint.
    run_audit '# p

### Где что лежит (разделение введено 2026-07-25)
- src/
' 0 "a structural heading citing a date is reported (false positive)"
    # Size is deliberately not a finding: this repo has removed the same distortion twice,
    # from the _PROJECT.md threshold and from the taskboard one. Rules grow legitimately.
    { echo '# p'; echo; echo '## Rules'
      i=0; while [ $i -lt 400 ]; do echo "- rule $i"; i=$((i + 1)); done; } > "$cm/big"
    run_audit "$(cat "$cm/big")" 0 "a long file of rules is reported — size must not be measured"
    # NOT READ is an error, never a pass: "no file" and "no findings" are different facts.
    bash "$lb" claude-md-audit "$cm/absent.md" >/dev/null 2>&1
    [ "$?" -eq 1 ] || missing+="an unreadable file does not give exit 1"$'\n'

    # Scope: a project's instructions are rarely one file. Measured 2026-08-16 in
    # goprofi-voronka — root 765 lines, backend 645, content 579, infra 200 — of which
    # only the root was ever audited, because that is the path /brain-save hands over.
    # A zoned file must be audited too, and the coverage must be PRINTED: "one file was
    # clean" read as "the instructions are clean" for as long as nobody looked.
    zc=$(mktemp -d)
    git -C "$zc" init -q >/dev/null 2>&1
    git -C "$zc" config user.email t@t >/dev/null 2>&1
    git -C "$zc" config user.name t >/dev/null 2>&1
    mkdir -p "$zc/backend"
    printf -- '# root\n\n## Rules\n- pnpm, never npm\n' > "$zc/CLAUDE.md"
    printf -- '# zone\n\n## Current state\nphase two is running\n' > "$zc/backend/CLAUDE.md"
    git -C "$zc" add -A >/dev/null 2>&1
    git -C "$zc" commit -qm z >/dev/null 2>&1
    zout=$(bash "$lb" claude-md-audit "$zc/CLAUDE.md" 2>&1); zrc=$?
    [ "$zrc" -eq 2 ] ||
        missing+="a state section in a zoned CLAUDE.md is not found (the root file is clean, rc=$zrc)"$'\n'
    grep -q 'backend/CLAUDE.md' <<<"$zout" ||
        missing+="the finding does not name which instruction file it came from"$'\n'
    grep -qE '^scope	2 instruction file' <<<"$zout" ||
        missing+="the audit does not print how many instruction files it covered"$'\n'
    # An untracked file is not part of the project's instructions and must not be counted.
    printf -- '# scratch\n\n## Current state\nnot part of the project\n' > "$zc/scratch-CLAUDE.md"
    zout=$(bash "$lb" claude-md-audit "$zc/CLAUDE.md" 2>&1)
    grep -qE '^scope	2 instruction file' <<<"$zout" ||
        missing+="an untracked CLAUDE.md is counted as project instructions"$'\n'
    rm -rf "$zc"
    rm -rf "$cm"
fi
if [ -n "$missing" ]; then
    fail "a project CLAUDE.md can hold state that nothing ever looks at" "$missing"
else
    pass "an existing CLAUDE.md is audited every save (7 outcomes, both languages, size ignored)"
fi

# ─── 41. A fixture date is never a fresh literal — the calendar is not an input ──
# A test whose verdict changes with the date, on code nobody touched, is a broken test in
# both directions: red it wastes the gate's credibility, green it proves nothing.
# Measured 2026-08-16: the lint-collect fixture asserted `nope stale-project:other` against
# `updated: 2026-08-01`, written 08-04 when it was 3 days old. On 08-16 it turned 15 — one
# day past the threshold — and failed the whole release gate with the code unchanged since
# 08-05. The sweep this rule demanded found four more not yet fired, one of them 3 days
# out (the scope fixture's `2026-08-04`, healthy-by-intent projects that were about to be
# reported stale).
# So: what must read FRESH is computed ($PF_FRESH), what must read STALE is written ancient
# ($PF_ANCIENT or an explicit old year) — a date can only get older, never younger, so an
# ancient literal is stable while a recent one is a delayed failure. The bound is 30 days,
# twice the largest age threshold in lib/ (14), so a literal cannot drift into a window.
# Scope: only `date:`/`updated:` values, which is where an age is read from. Prose dates in
# comments are records of when something was measured and must NOT be touched.
missing=""
PF_NOW=$(date +%s)
pf_lits=$(grep -oE '^[^#]*(date|updated): 2[0-9]{3}-[0-9]{2}-[0-9]{2}' "$SCRIPT_DIR/preflight.sh" |
          grep -oE '2[0-9]{3}-[0-9]{2}-[0-9]{2}' | LC_ALL=C sort -u)
if [ -z "$pf_lits" ]; then
    fail "check 41 found no fixture dates at all — empty input, not a clean file"
else
    pf_n=0
    for d in $pf_lits; do
        ds=$(date -d "$d" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$d 00:00:00" +%s)
        [ -n "$ds" ] || { missing+="  cannot parse the fixture date $d"$'\n'; continue; }
        pf_n=$((pf_n + 1))
        age=$(( (PF_NOW - ds) / 86400 ))
        [ "$age" -ge 30 ] ||
            missing+="  $d is only $age days old — a fixture that must read fresh uses \$PF_FRESH"$'\n'
    done
    [ "$pf_n" -gt 0 ] || missing+="  no fixture date could be parsed — the date fallback is broken"$'\n'
    if [ -n "$missing" ]; then
        fail "a fixture carries a fresh literal date — it will go red on a calendar day, untouched" "$missing"
    else
        pass "fixture dates cannot drift into a threshold ($pf_n literals, all ≥30 days; freshness computed)"
    fi
fi

# ─── 42. The save states what it did, and a skipped step is visible in the output ──
# Measured 2026-08-16 in goprofi-voronka, twice in one session: /brain-save ran eight of
# its twelve steps and reported success. The four that vanished were the ones leaving no
# visible trace (brain-version, local-conventions, the decision note, the architecture
# map), and the user caught it by the save feeling quick. That is this package's headline
# failure class occurring inside the package, so the report is checked by RUNNING it —
# a template can be filled from the memory of an intention, a count cannot.
# Four outcomes, and each one has been wrong at least once in development:
#   complete save -> 0 · a step without a trace -> 2 and names it · no project -> 1
#   a vault without git -> still runs, and invents no MISSING out of its own mode
#     (it did: under mtime nothing is "new", so a freshly written log read as absent).
missing=""
sr_lib=$(mktemp -d)
cp "$SCRIPT_DIR/lib/brain.sh" "$sr_lib/"
printf 'v9.9.9\n' > "$sr_lib/VERSION"     # the version is read next to the script
srb="$sr_lib/brain.sh"
srv=$(mktemp -d)
mkdir -p "$srv/proj/wiki" "$srv/proj/sessions" "$srv/00-system"
printf -- '---\nproject: proj\ntype: mixed\nupdated: %s\nbrain-version: "v9.9.9"\n---\n## Current state\nx\n' \
    "$PF_ANCIENT" > "$srv/proj/_PROJECT.md"
printf -- '## In progress\n- [ ] a\n## Done\n' > "$srv/proj/taskboard.md"
printf -- '---\nupdated: %s\n---\n# map\n' "$PF_ANCIENT" > "$srv/proj/architecture-map.md"
printf -- '# index\n- [[proj/_PROJECT]]\n' > "$srv/00-system/index.md"
printf -- '# connections\n' > "$srv/00-system/connections.md"
# Three earlier logs all carrying `zone:` — that makes it this project's convention, the
# one Step 0c exists to carry forward and the one a template cannot know about.
for d in 2020-01-01 2020-01-02 2020-01-03; do
    printf -- '---\ndate: %s\nzone: root\n---\nbody\n' "$d" > "$srv/proj/sessions/${d}_1000_session.md"
done
git -C "$srv" init -q >/dev/null 2>&1
git -C "$srv" add -A >/dev/null 2>&1
git -C "$srv" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
if ! git -C "$srv" rev-parse --git-dir >/dev/null 2>&1; then
    fail "check 42 could not build a git fixture — the outcome would be untested, not clean"
else
    # (a) a complete save: every owed step leaves a trace
    printf -- '---\ndate: %s\nzone: root\n---\nbody\n' "$PF_FRESH" > "$srv/proj/sessions/${PF_FRESH}_1200_session.md"
    printf -- '---\ndate: %s\n---\n[[../_PROJECT|_PROJECT]]\n' "$PF_FRESH" > "$srv/proj/wiki/decision-x.md"
    # A complete save stamps `updated` too, or the run below would fail on that alone.
    bash "$srb" stamp-field "$srv/proj/_PROJECT.md" updated "$PF_FRESH" >/dev/null 2>&1
    echo edit >> "$srv/proj/_PROJECT.md";        echo '- [ ] b' >> "$srv/proj/taskboard.md"
    echo row  >> "$srv/proj/architecture-map.md"; echo '- e'    >> "$srv/00-system/index.md"
    echo '- l' >> "$srv/00-system/connections.md"
    sr_out=$(bash "$srb" save-report "$srv" proj 2>&1); sr_rc=$?
    [ "$sr_rc" -eq 0 ] || missing+="a complete save does not exit 0 (got $sr_rc)"$'\n'
    grep -q 'MISSING' <<<"$sr_out" && missing+="a complete save still reports a MISSING step"$'\n'
    grep -q 'decision-x.md' <<<"$sr_out" || missing+="the decision note is not named in the report"$'\n'

    # (b) the measured defect: version not re-stamped, local key dropped, map untouched
    git -C "$srv" checkout -q . 2>/dev/null; git -C "$srv" clean -qfd 2>/dev/null
    printf -- '---\ndate: %s\n---\nbody\n' "$PF_FRESH" > "$srv/proj/sessions/${PF_FRESH}_1200_session.md"
    echo edit >> "$srv/proj/_PROJECT.md"
    # sed to a temp file, never `sed -i`: the flag takes an argument on BSD and none on GNU.
    sr_tmp=$(mktemp)
    sed 's/brain-version: "v9.9.9"/brain-version: "1.3"/' "$srv/proj/_PROJECT.md" > "$sr_tmp"
    mv "$sr_tmp" "$srv/proj/_PROJECT.md"
    sr_out=$(bash "$srb" save-report "$srv" proj 2>&1); sr_rc=$?
    [ "$sr_rc" -eq 2 ] || missing+="a save with an untraced step does not exit 2 (got $sr_rc)"$'\n'
    grep -q 'MISSING  brain-version' <<<"$sr_out" ||
        missing+="an unstamped brain-version is not reported MISSING"$'\n'
    grep -q 'MISSING  local conventions' <<<"$sr_out" ||
        missing+="a log dropping the project's own frontmatter key is not reported MISSING"$'\n'
    # Step 0b stamps TWO fields. Checking only the version left half the step invisible:
    # found 2026-08-16 when the owner asked why a save felt quick — that save had stamped
    # brain-version and not updated, and the report said ok twice.
    grep -q 'MISSING  updated' <<<"$sr_out" ||
        missing+="_PROJECT.md older than this session's own log is not reported"$'\n'
    grep -q 'ANSWER   architecture map' <<<"$sr_out" ||
        missing+="an untouched map in a mixed project does not ask for an answer"$'\n'
    # ANSWER must NOT set the exit code on its own: a warning that fires every run stops
    # being read, and an ordinary save legitimately leaves conditional steps untouched.
    git -C "$srv" checkout -q . 2>/dev/null; git -C "$srv" clean -qfd 2>/dev/null
    printf -- '---\ndate: %s\nzone: root\n---\nbody\n' "$PF_FRESH" > "$srv/proj/sessions/${PF_FRESH}_1200_session.md"
    bash "$srb" stamp-field "$srv/proj/_PROJECT.md" updated "$PF_FRESH" >/dev/null 2>&1
    echo edit >> "$srv/proj/_PROJECT.md"; echo row >> "$srv/proj/architecture-map.md"
    echo '- [ ] b' >> "$srv/proj/taskboard.md"
    bash "$srb" save-report "$srv" proj >/dev/null 2>&1
    [ $? -eq 0 ] || missing+="ANSWER alone sets a non-zero exit — the report will be ignored"$'\n'

    # (c) an unknown project is an error, never a clean report
    bash "$srb" save-report "$srv" nope >/dev/null 2>&1
    [ $? -eq 1 ] || missing+="an unknown project does not exit 1"$'\n'
    bash "$srb" save-report "$srv" >/dev/null 2>&1
    [ $? -eq 1 ] || missing+="a missing argument does not exit 1"$'\n'

    # (d) a vault without git still runs, and its own mode invents no finding
    srv2=$(mktemp -d)
    cp -r "$srv/proj" "$srv/00-system" "$srv2/" 2>/dev/null
    rm -rf "$srv2/.git"
    sr_out=$(bash "$srb" save-report "$srv2" proj 2>&1)
    grep -q 'mtime' <<<"$sr_out" || missing+="a vault without git does not say it fell back to mtime"$'\n'
    grep -q 'MISSING  session log' <<<"$sr_out" &&
        missing+="under mtime a freshly written log is reported missing — the mode invented it"$'\n'
    rm -rf "$srv2"
fi
rm -rf "$srv" "$sr_lib"
# The call has to sit where the prompt says: after the writes it measures, before the
# commit that hides them. A step placed after the commit is not a weaker version of this,
# it is inert — the working tree is clean by then and every step reads as skipped.
sr_md="$SCRIPT_DIR/commands/brain-save.md"
if [ ! -f "$sr_md" ]; then
    missing+="no commands/brain-save.md — nothing to check the ordering in"$'\n'
else
    # The CALL, not the word. Two negative tests were needed to get this line right:
    # grepping the file passes on the prose describing the step, and grepping the
    # executable blocks still passes on the Result template, which is fenced without a
    # language and therefore counts as code. So match the invocation form itself.
    sr_call=$(exec_blocks "$sr_md" | grep -E '(\$BRAIN|brain\.sh)[^|]*save-report' | head -1 | cut -d: -f1)
    sr_commit=$(grep -n 'git add -A' "$sr_md" | head -1 | cut -d: -f1)
    sr_write=$(grep -n 'prose-budget' "$sr_md" | head -1 | cut -d: -f1)
    if [ -z "$sr_call" ]; then
        missing+="brain-save.md never calls save-report — the Result block is a template again"$'\n'
    elif [ -z "$sr_commit" ] || [ -z "$sr_write" ]; then
        missing+="brain-save.md lost its commit line or its prose-budget call — cannot check the order"$'\n'
    elif [ "$sr_call" -lt "$sr_write" ] || [ "$sr_call" -gt "$sr_commit" ]; then
        missing+="save-report is called out of order (line $sr_call; writes $sr_write, commit $sr_commit)"$'\n'
    fi
    grep -q 'step skipped' "$sr_md" ||
        missing+="brain-save.md does not require a MISSING step to be named in the Result"$'\n'
fi
if [ -n "$missing" ]; then
    fail "a skipped save step can still read as a successful save" "$missing"
else
    pass "save-report measures the save on disk (4 outcomes run, ordering and MISSING wording checked)"
fi

# ─── 43. backfill-dates recovers closing dates from history, or refuses ──────
# `archive` moves dated entries only, so an undated Done backlog makes its threshold
# unsatisfiable by any amount of running `archive` — a permanent violation rather than a
# standard. goprofi did the recovery by hand on 2026-08-15 (34 entries, zero collisions);
# this is that, in the package, because by hand nobody will do it twice.
# Checked by running against a real repository, not by grepping shape. What each case
# guards is written next to it — every one of them broke at least once while being built.
missing=""
bf=$(mktemp -d)
git -C "$bf" init -q >/dev/null 2>&1
git -C "$bf" config user.email t@t >/dev/null 2>&1
git -C "$bf" config user.name t >/dev/null 2>&1
if ! git -C "$bf" rev-parse --git-dir >/dev/null 2>&1; then
    fail "check 43 could not build a git fixture — the outcome would be untested, not clean"
else
    # Three commits: an entry is opened, then closed, then a second one is closed later.
    printf -- '## In progress\n- [ ] alpha\n- [ ] beta\n\n## Done\n' > "$bf/taskboard.md"
    git -C "$bf" add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE='2026-05-01T10:00:00' GIT_COMMITTER_DATE='2026-05-01T10:00:00' \
        git -C "$bf" commit -qm one >/dev/null 2>&1
    printf -- '## In progress\n- [ ] beta\n\n## Done\n- [x] alpha, closed with no date\n      body line\n' > "$bf/taskboard.md"
    git -C "$bf" add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE='2026-06-02T10:00:00' GIT_COMMITTER_DATE='2026-06-02T10:00:00' \
        git -C "$bf" commit -qm two >/dev/null 2>&1
    printf -- '## In progress\n\n## Done\n- [x] alpha, closed with no date\n      body line\n- [x] beta, also undated\n- [x] 2026-01-01 gamma, already dated\n' > "$bf/taskboard.md"
    git -C "$bf" add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE='2026-07-03T10:00:00' GIT_COMMITTER_DATE='2026-07-03T10:00:00' \
        git -C "$bf" commit -qm three >/dev/null 2>&1

    # (a) a dry run reports and writes nothing
    before=$(command cat "$bf/taskboard.md")
    out=$(bash "$LIBSH" backfill-dates "$bf/taskboard.md" 2>&1)
    [ "$(command cat "$bf/taskboard.md")" = "$before" ] ||
        missing+="the dry run wrote to the taskboard"$'\n'
    grep -q '2 undated entries, 2 datable' <<<"$out" ||
        missing+="the dry run does not count what it can date (got: $(head -1 <<<"$out"))"$'\n'

    # (b) --apply dates each entry from the commit that first shows it closed
    bash "$LIBSH" backfill-dates "$bf/taskboard.md" --apply >/dev/null 2>&1 ||
        missing+="--apply failed on a valid board"$'\n'
    grep -q '^- \[x\] 2026-06-02 alpha' "$bf/taskboard.md" ||
        missing+="alpha was not dated from the commit that closed it (2026-06-02)"$'\n'
    grep -q '^- \[x\] 2026-07-03 beta' "$bf/taskboard.md" ||
        missing+="beta was not dated from its own commit (2026-07-03)"$'\n'
    grep -q '^- \[x\] 2026-01-01 gamma' "$bf/taskboard.md" ||
        missing+="an already dated entry was rewritten"$'\n'
    grep -q '^      body line' "$bf/taskboard.md" ||
        missing+="a body line was lost or moved"$'\n'
    # Nothing but dates: strip them from both sides and the files must be identical.
    sed -E 's/^(- \[x\]) [0-9]{4}-[0-9]{2}-[0-9]{2}/\1/' "$bf/taskboard.md" > "$bf/after.strip"
    printf '%s\n' "$before" | sed -E 's/^(- \[x\]) [0-9]{4}-[0-9]{2}-[0-9]{2}/\1/' > "$bf/before.strip"
    cmp -s "$bf/after.strip" "$bf/before.strip" ||
        missing+="the rewrite changed something other than the dates"$'\n'
    # Running it again must be a no-op, not a second date on the same line.
    out=$(bash "$LIBSH" backfill-dates "$bf/taskboard.md" 2>&1)
    grep -q 'already carries a date' <<<"$out" ||
        missing+="a second run does not recognise the board as fully dated"$'\n'

    # (c) two entries with the same text cannot be told apart — refuse, never guess.
    printf -- '## Done\n- [x] same text\n- [x] same text\n' > "$bf/dup.md"
    git -C "$bf" add -A >/dev/null 2>&1
    git -C "$bf" commit -qm dup >/dev/null 2>&1
    bash "$LIBSH" backfill-dates "$bf/dup.md" >/dev/null 2>&1
    [ $? -eq 1 ] || missing+="duplicate entry texts are not refused"$'\n'

    # (d) no git, no history: that is an error, not an empty result. This is the check
    # that caught the real bug — the pathspec was resolved from the file's own directory
    # instead of the repository root, so git returned an empty log for a file with 156
    # revisions and every entry would have been reported undatable.
    ng=$(mktemp -d)
    printf -- '## Done\n- [x] whatever\n' > "$ng/taskboard.md"
    bash "$LIBSH" backfill-dates "$ng/taskboard.md" >/dev/null 2>&1
    [ $? -eq 1 ] || missing+="a taskboard outside git does not exit 1"$'\n'
    # A tracked-but-in-a-subdirectory board must still find its history.
    mkdir -p "$bf/sub"
    printf -- '## Done\n- [x] sub entry undated\n' > "$bf/sub/taskboard.md"
    git -C "$bf" add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE='2026-07-04T10:00:00' GIT_COMMITTER_DATE='2026-07-04T10:00:00' \
        git -C "$bf" commit -qm sub >/dev/null 2>&1
    out=$(bash "$LIBSH" backfill-dates "$bf/sub/taskboard.md" 2>&1)
    grep -q '1 datable' <<<"$out" ||
        missing+="a board in a subdirectory finds no history — the pathspec is resolved from the wrong root"$'\n'
    rm -rf "$ng"
fi
rm -rf "$bf"
if [ -n "$missing" ]; then
    fail "backfill-dates cannot recover a closing date, or damages the board doing it" "$missing"
else
    pass "backfill-dates dates entries from history, refuses ambiguity, touches nothing else"
fi

# ─── 44. The taskboard counters measure debt, and never advise the impossible ──
# Two complaints from live use, both fixed by measuring something else:
#   * In progress was counted in LINES. goprofi read 1148/300 with 64 genuinely open
#     tasks, because that board requires each task to carry its measurement — so the
#     threshold punished the format and was unreachable without breaking another rule.
#   * The Done overrun advised running `archive`, which moves dated entries only. On a
#     board where none are dated it moves zero, and an instruction the tool cannot carry
#     out teaches the reader to skip the whole block.
missing=""
tc=$(mktemp -d)
printf -- '---\nupdated: %s\n---\n## Current state\nx\n' "$PF_ANCIENT" > "$tc/_PROJECT.md"
# 5 open items, each with a long justified body: many lines, little debt.
{ echo '## In progress'
  i=0; while [ $i -lt 5 ]; do echo "- [ ] task $i"
      j=0; while [ $j -lt 40 ]; do echo "      justification line $j"; j=$((j + 1)); done
      i=$((i + 1)); done
  echo '## Done'; } > "$tc/verbose.md"
out=$(bash "$LIBSH" prose-budget "$tc/_PROJECT.md" "$tc/verbose.md" 2>&1)
grep -q 'In progress (open items): 5/' <<<"$out" ||
    missing+="a board of 5 well-justified tasks is not measured as 5 items"$'\n'
grep -q 'OVER.*In progress' <<<"$out" &&
    missing+="200 lines of justification for 5 tasks reads as an overrun"$'\n'
# Done over budget with nothing archivable must say so and point at the recovery.
{ echo '## Done'; i=0; while [ $i -lt 25 ]; do echo "- [x] closed $i"; i=$((i + 1)); done; } > "$tc/undated.md"
out=$(bash "$LIBSH" prose-budget "$tc/_PROJECT.md" "$tc/undated.md" 2>&1)
grep -q 'archive can move: 0' <<<"$out" ||
    missing+="a Done overrun with no dated entry does not say archive can move nothing"$'\n'
grep -q 'backfill-dates' <<<"$out" ||
    missing+="the unactionable advice is not replaced by the one that works"$'\n'
# With dated entries it must name how many are reachable, not repeat the total.
{ echo '## Done'; i=0; while [ $i -lt 25 ]; do echo "- [x] 2026-01-0$((i % 9 + 1)) closed $i"; i=$((i + 1)); done; } > "$tc/dated.md"
out=$(bash "$LIBSH" prose-budget "$tc/_PROJECT.md" "$tc/dated.md" 2>&1)
grep -q 'archive can move: 25' <<<"$out" ||
    missing+="a fully dated Done section does not report all entries as archivable"$'\n'
# The lint and prose-budget must agree: one implementation, or they disagree per board.
lc_out=$(cd "$tc" 2>/dev/null && bash "$LIBSH" prose-budget "$tc/_PROJECT.md" "$tc/dated.md" 2>&1)
[ "$out" = "$lc_out" ] || missing+="prose-budget is not deterministic on the same input"$'\n'
rm -rf "$tc"
if [ -n "$missing" ]; then
    fail "a taskboard threshold measures the writing style, or advises what the tool cannot do" "$missing"
else
    pass "taskboard budgets count open items and only advise archive for what it can reach"
fi

# ─── 45. Freshness measures the record against the work, and status is honoured ──
# Two changes, one cause: a finding nobody can act on trains the reader to skim.
#   * `stale-project` used to fire at 14 days since `updated:`. That measures how
#     recently the owner chose to work on a project, not whether anything is wrong.
#     Measured 2026-08-16 on the live vault: 7 findings, all noise — six projects were
#     simply not the current priority, and every one of them had `updated:` exactly equal
#     to the date of its own last session, i.e. every record was correct. It now reports
#     the opposite direction: a session exists that the project file does not reflect.
#   * A project that is not `active` is not held to freshness at all. Live case:
#     puzzlebot-voronka is kept as a knowledge source for goprofi and deliberately not
#     developed. The exclusion must be NAMED in the output — a check that quietly looks
#     at less than it claims is this file's oldest enemy (sparse checkout, check 21).
missing=""
fv=$(mktemp -d)
mkdir -p "$fv/00-system" "$fv/quiet/sessions" "$fv/quiet/wiki" "$fv/lagging/sessions" "$fv/lagging/wiki" "$fv/parked/sessions" "$fv/parked/wiki"
printf -- '# index\n- [[quiet/_PROJECT]]\n- [[lagging/_PROJECT]]\n- [[parked/_PROJECT]]\n' > "$fv/00-system/index.md"
# quiet: nothing written for ages, but the record matches its last session -> NOT a finding
printf -- '---\nproject: quiet\nupdated: 2020-01-01\n---\n## Current state\nx\n' > "$fv/quiet/_PROJECT.md"
printf -- '---\ndate: 2020-01-01\n---\nx\n' > "$fv/quiet/sessions/2020-01-01_1000_session.md"
printf -- '---\ndate: 2020-01-01\n---\n[[../_PROJECT|_PROJECT]] [[note-q2]]\n' > "$fv/quiet/wiki/note-q1.md"
# lagging: a session exists that the project file never recorded -> IS a finding
printf -- '---\nproject: lagging\nupdated: 2020-01-01\n---\n## Current state\nx\n' > "$fv/lagging/_PROJECT.md"
printf -- '---\ndate: 2020-06-01\n---\nx\n' > "$fv/lagging/sessions/2020-06-01_1000_session.md"
printf -- '---\ndate: 2020-01-01\n---\n[[../_PROJECT|_PROJECT]] [[note-l2]]\n' > "$fv/lagging/wiki/note-l1.md"
# parked: same lag, but not active -> excluded, and said out loud
printf -- '---\nproject: parked\nstatus: reference\nupdated: 2020-01-01\n---\n## Current state\nx\n' > "$fv/parked/_PROJECT.md"
printf -- '---\ndate: 2020-06-01\n---\nx\n' > "$fv/parked/sessions/2020-06-01_1000_session.md"
printf -- '---\nupdated: 2019-01-01\n---\n# map\n' > "$fv/parked/architecture-map.md"
printf -- '---\ndate: 2020-01-01\n---\n[[../_PROJECT|_PROJECT]] [[note-p2]]\n' > "$fv/parked/wiki/note-p1.md"
# A note with no backlink: a CONTENT defect, unrelated to freshness. It must still be
# reported for a parked project — the exemption covers staleness, not everything.
printf -- '---\ndate: 2020-01-01\n---\nno backlink here [[note-p1]]\n' > "$fv/parked/wiki/note-p3.md"
fv_out=$(bash "$LIBSH" lint-collect "$fv" 2>&1)
if [ -z "$fv_out" ]; then
    fail "check 45 got no output from lint-collect — the fixture or the command is broken"
else
    grep -q '^stale-project:lagging' <<<"$fv_out" ||
        missing+="a session the project file never recorded is not reported"$'\n'
    grep -q '^stale-project:quiet' <<<"$fv_out" &&
        missing+="a project that is merely quiet is reported stale — the calendar is back"$'\n'
    grep -q '^stale-project:parked' <<<"$fv_out" &&
        missing+="a non-active project is held to freshness anyway"$'\n'
    grep -q '^map-stale:parked' <<<"$fv_out" &&
        missing+="a non-active project is reported for map drift"$'\n'
    grep -q '^scope-note:not-active' <<<"$fv_out" ||
        missing+="the excluded projects are not named — a silent exemption"$'\n'
    grep -q 'parked' <<<"$(grep '^scope-note:not-active' <<<"$fv_out")" ||
        missing+="the scope note does not name WHICH project it skipped"$'\n'
    # The exemption must not swallow everything: content checks still apply to it.
    grep -q '^wiki-no-backlink:parked' <<<"$fv_out" ||
        missing+="a non-active project fell out of the content checks too — that is over-exemption"$'\n'
fi
rm -rf "$fv"
if [ -n "$missing" ]; then
    fail "freshness reports the calendar, or a status exemption hides projects silently" "$missing"
else
    pass "stale-project measures the record against the work; non-active projects are skipped and named"
fi

# ─── 46. A cross-project entry is placed by code, because prose named no address ──
# Step 7 gave the entry's FORMAT and never its PLACE, and appending to a file is never
# an error — so sessions appended to the end, and the end of connections.md sat inside a
# heading dated 2026-07-29. Measured 2026-08-17 on the live vault: 89 August entries,
# three written that same day, under a July heading announcing a different topic, while
# the section a reader opens held nothing newer than 08-16. Wrong about its date, its
# size and its subject at once, and invisible: the file grew, the entry was there.
#
# So the check is positional, not merely "did it write" — a version that appends passes
# every count and still reproduces the defect. And no age window is asserted anywhere on
# purpose: these entries are techniques, which do not spoil, so `lint-collect` must not
# grow a threshold for this file. That absence is asserted too, or it comes back.
missing=""
cf=$(mktemp -d)
printf -- '# Connections\n\n## Shared knowledge\n\n## Knowledge transfers\n\n- 2026-08-10 | [[a/wiki/x]] → applicable in b\n  body\n' > "$cf/c.md"
printf -- '# C\n\n## Перетоки знаний\n\n- 2026-08-01 | old → x\n' > "$cf/ru.md"
printf -- '# nothing here\n' > "$cf/nosection.md"

out=$(printf 'new one → applicable in q\nsecond line\n' | bash "$LIBSH" connections-add "$cf/c.md" 2026-08-17 2>&1)
rc=$?
[ "$rc" -eq 0 ] || missing+="a valid entry was refused (rc=$rc): $out"$'\n'
# THE property: the new entry is the FIRST entry in the file, not the last.
first_entry=$(grep -m1 -E '^- 20[0-9][0-9]-' "$cf/c.md")
grep -qFe '2026-08-17' <<<"$first_entry" ||
    missing+="the entry did not land at the top of the section — got: $first_entry"$'\n'
# Its body must travel with it, indented, and the old entry must survive.
grep -qFe '  second line' "$cf/c.md" || missing+="the entry body was lost or left unindented"$'\n'
grep -qFe '- 2026-08-10 | [[a/wiki/x]] → applicable in b' "$cf/c.md" ||
    missing+="the pre-existing entry did not survive the insert"$'\n'
[ "$(grep -c -E '^- 20[0-9][0-9]-' "$cf/c.md")" -eq 2 ] ||
    missing+="entry count is not exactly one more than before"$'\n'

# The Russian spelling of the section is matched too — a live vault carries it.
printf 'ru entry → применимо в z\n' | bash "$LIBSH" connections-add "$cf/ru.md" 2026-08-17 >/dev/null 2>&1
grep -qFe '2026-08-17' <<<"$(grep -m1 -E '^- 20[0-9][0-9]-' "$cf/ru.md")" ||
    missing+="the Russian section name is not matched — a live vault would be appended to blindly"$'\n'

# Refusals. Each is a fact the caller must not be able to mistake for success.
printf '' | bash "$LIBSH" connections-add "$cf/c.md" 2026-08-17 >/dev/null 2>&1 &&
    missing+="an empty entry was accepted — a heredoc that never arrived reads as 'nothing to say'"$'\n'
echo x | bash "$LIBSH" connections-add "$cf/c.md" 17-08-2026 >/dev/null 2>&1 &&
    missing+="a malformed date was accepted"$'\n'
echo x | bash "$LIBSH" connections-add "$cf/nosection.md" 2026-08-17 >/dev/null 2>&1 &&
    missing+="a file with no knowledge-transfers section was written to anyway"$'\n'
printf 'new one → applicable in q\n' | bash "$LIBSH" connections-add "$cf/c.md" 2026-08-17 >/dev/null 2>&1 &&
    missing+="an exact duplicate was appended"$'\n'
[ "$(grep -c -E '^- 20[0-9][0-9]-' "$cf/c.md")" -eq 2 ] ||
    missing+="a refused call still changed the file"$'\n'

# Derived, not a hand-written list: any instruction file telling a session to put an
# entry into connections.md must hand it to the command. A fifth such file is caught by
# the check that already exists, instead of by someone remembering to extend a list.
for f in "$SCRIPT_DIR"/SKILL.md "$SCRIPT_DIR"/commands/*.md; do
    grep -qFe 'connections.md' "$f" || continue
    grep -qEe 'add (an )?entry|add connections|Add entry' "$f" || continue
    grep -qFe 'connections-add' "$f" ||
        missing+="$(basename "$f") tells a session to add a connection without naming connections-add"$'\n'
done
# No age threshold for this file, ever: a technique does not spoil with age, and the
# entries are reached by grep, which is recursive — archiving would not even save a read.
grep -qEe 'connections(\.md)?[^\n]*(older than|age|stale)' "$LIBSH" &&
    missing+="lib/brain.sh has grown an age threshold for connections.md"$'\n'
rm -rf "$cf"
if [ -n "$missing" ]; then
    fail "a cross-project entry is not placed by code, or an age window came back" "$missing"
else
    pass "connections-add puts the entry at the top, refuses four ways, and no age window exists"
fi

# ─── 47. The catalogue is generated, and it states each decision's standing ───
# Borrowed from nf-content's `catalog-records` — read a compact index and pull only what
# is relevant, instead of reading the base. Two properties make it worth having rather
# than being `ls` with extra steps, and both are asserted here:
#   * it is GENERATED per call and never stored, so it cannot drift from the notes. Their
#     version is maintained by a skill and their own limitation 2.3.2 admits it does not
#     re-sync a hand-edited record; a stored index that lies is worse than no index.
#   * it carries a decision's STANDING — superseded / corrected — which a file listing
#     cannot. On the live vault the first run surfaced two `corrected-by` notes in this
#     project that nobody had in mind, i.e. notes whose facts are partly retracted.
# The refusals matter for the same reason as everywhere here: an empty catalogue must be
# an error, never a clean answer.
missing=""
cv=$(mktemp -d)
mkdir -p "$cv/alpha/wiki" "$cv/beta/wiki" "$cv/nowiki"
printf -- '---\nproject: alpha\n---\n' > "$cv/alpha/_PROJECT.md"
printf -- '---\nproject: beta\n---\n'  > "$cv/beta/_PROJECT.md"
printf -- '---\nproject: nowiki\n---\n' > "$cv/nowiki/_PROJECT.md"
printf -- '---\nstatus: accepted\ndate: %s\nsupersedes:\n---\nbody\n' "$PF_ANCIENT" \
    > "$cv/alpha/wiki/decision-in-force.md"
printf -- '---\nstatus: superseded\nsuperseded-by: decision-in-force.md\ndate: %s\n---\nbody\n' "$PF_ANCIENT" \
    > "$cv/alpha/wiki/decision-retired.md"
printf -- '---\nstatus: accepted\ncorrected-by: decision-in-force.md\ndate: %s\n---\nbody\n' "$PF_ANCIENT" \
    > "$cv/alpha/wiki/decision-partly-wrong.md"
# `supersedes: ~` is YAML null, not a note name — it must not read as a supersession.
printf -- '---\nstatus: accepted\nsupersedes: ~\ncorrected-by: ~\ndate: %s\n---\nbody\n' "$PF_ANCIENT" \
    > "$cv/alpha/wiki/decision-null-fields.md"
printf -- '---\nstatus: stable\ndate: %s\n---\nbody\n' "$PF_ANCIENT" \
    > "$cv/alpha/wiki/synthesis-note.md"
printf -- '---\nproject: beta\n---\nno date at all\n' > "$cv/beta/wiki/undated.md"

sum=$(bash "$LIBSH" catalog "$cv" 2>&1)
if [ -z "$sum" ]; then
    fail "check 47 got no output from catalog — the fixture or the command is broken"
else
    # alpha: 5 notes, 4 decisions, 3 in force (accepted×3), 1 retired (superseded)
    grep -qEe '^5[[:space:]]+4[[:space:]]+3[[:space:]]+1[[:space:]]' <<<"$sum" ||
        missing+="the summary counts are wrong for alpha (want 5 notes / 4 decs / 3 in force / 1 retired), got: $(grep alpha <<<"$sum")"$'\n'
    grep -qFe 'alpha' <<<"$sum" || missing+="the summary does not list project alpha"$'\n'
    grep -qFe 'nowiki' <<<"$sum" &&
        missing+="a project with no wiki/ appears in the summary"$'\n'
fi

idx=$(bash "$LIBSH" catalog "$cv" --project alpha 2>&1)
grep -qEe '^[0-9-]+[[:space:]]+accepted[[:space:]]+decision-in-force$' <<<"$idx" ||
    missing+="an in-force decision is not reported as accepted"$'\n'
grep -qFe 'superseded→decision-in-force' <<<"$idx" ||
    missing+="a superseded decision does not name what replaced it — the standing is the point"$'\n'
grep -qFe 'accepted+corrected' <<<"$idx" ||
    missing+="a corrected decision is not marked — its retracted fact would be read as current"$'\n'
null_line=$(grep -Fe 'decision-null-fields' <<<"$idx")
case "$null_line" in
    *"→"*|*"+corrected"*) missing+="YAML null (~) was read as a note name: $null_line"$'\n' ;;
esac
# Newest first: sorting is what makes a long index usable at all.
[ "$(printf '%s\n' "$idx" | head -1 | cut -f1)" = "$(printf '%s\n' "$idx" | cut -f1 | LC_ALL=C sort -r | head -1)" ] ||
    missing+="the index is not sorted newest first"$'\n'

# Refusals: each is a fact the caller must not mistake for an empty vault.
bash "$LIBSH" catalog "$cv/../definitely-absent-$$" >/dev/null 2>&1 &&
    missing+="a missing vault path was accepted"$'\n'
ev=$(mktemp -d)
bash "$LIBSH" catalog "$ev" >/dev/null 2>&1 &&
    missing+="a vault with no _PROJECT.md printed a clean catalogue instead of failing"$'\n'
rmdir "$ev" 2>/dev/null || rm -rf "$ev"
bash "$LIBSH" catalog "$cv" --project nosuch >/dev/null 2>&1 &&
    missing+="an unknown project name was accepted"$'\n'
bash "$LIBSH" catalog "$cv" --project nowiki >/dev/null 2>&1 &&
    missing+="a project with no wiki/ returned success"$'\n'

# A call site is not optional. `catalog` shipped with none — executable, gated, and run
# never, which is this project's third failure mode (the step exists, nothing invokes it).
# So the check asserts an actual invocation in a command, not a mention in prose: matching
# the word alone would pass on the sentence explaining the rule.
grep -qEe 'bash "\$BRAIN" catalog' "$SCRIPT_DIR/commands/brain-lint.md" ||
    missing+="no command invokes catalog — it would exist and never run"$'\n'
grep -qFe 'brain.sh catalog' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md does not tell a session to list notes before searching them"$'\n'

# Generated, never stored: the command must not leave an index file behind.
# No `find … | grep -q .`: grep -q exits at the first match, the producer dies of
# SIGPIPE, and under pipefail a successful match reads as failure (rule in CLAUDE.md).
leftover=$(find "$cv" -name 'catalog*' -o -name '*каталог*')
[ -n "$leftover" ] &&
    missing+="catalog wrote an index file into the vault — a stored index drifts: $leftover"$'\n'
rm -rf "$cv"
if [ -n "$missing" ]; then
    fail "the catalogue does not state standing, miscounts, or accepts an empty vault" "$missing"
else
    pass "catalog is generated per call, counts notes and reports each decision's standing"
fi

# ─── 48. A document with a lifecycle is inventoried, and knowledge is not ─────
# The class: a brief / audit request / verification plan — an instruction that stops being
# true when its run closes. Measured 2026-08-16 (two briefs `open` for twelve days while
# _PROJECT.md announced their runs closed) and 2026-08-17 (the Autopilot brief, two days,
# while its own text warned against it). Deliberately an inventory rather than a
# threshold: the vault holds six such documents, five already final, and a brief
# legitimately stays open for weeks — so age is the wrong measure, as it is for project
# freshness (check 45). What the check must therefore prove is the SEPARATION: process
# state is reported, knowledge is not, and registries are not.
missing=""
lv=$(mktemp -d)
mkdir -p "$lv/proj/wiki" "$lv/proj/sessions" "$lv/proj/audits"
printf -- '---\nproject: proj\nstatus: active\n---\n## Current state\nx\n' > "$lv/proj/_PROJECT.md"
printf -- '# board\n## In progress\n' > "$lv/proj/taskboard.md"
printf -- '---\ntype: task-brief\nstatus: open\n---\nbrief body\n' > "$lv/proj/brief-open.md"
printf -- '---\ntype: task-brief\nstatus: closed\nclosed: %s\n---\nbrief body\n' "$PF_ANCIENT" \
    > "$lv/proj/brief-closed.md"
printf -- '---\nstatus: processed\n---\naudit\n' > "$lv/proj/audits/audit-request.md"
# Knowledge, not process: these must NOT appear, or the line becomes noise.
printf -- '---\nstatus: accepted\ndate: %s\n---\n[[../_PROJECT|_PROJECT]] [[other]]\n' "$PF_ANCIENT" \
    > "$lv/proj/wiki/decision-something.md"
printf -- '---\nstatus: stable\ndate: %s\n---\nconcept\n' "$PF_ANCIENT" > "$lv/proj/concept-note.md"
printf -- '---\ndate: %s\n---\nlog\n' "$PF_ANCIENT" > "$lv/proj/sessions/${PF_ANCIENT}_1000_session.md"
printf -- '# index\n- [[proj/_PROJECT]]\n' > "$lv/00-system-index-stub.md"
mkdir -p "$lv/00-system"; printf -- '# index\n- [[proj/_PROJECT]]\n' > "$lv/00-system/index.md"

lout=$(bash "$LIBSH" lint-collect "$lv" 2>&1)
lline=$(grep -Fe 'scope-note:lifecycle-docs' <<<"$lout")
if [ -z "$lline" ]; then
    missing+="lifecycle documents are not reported at all"$'\n'
else
    grep -qFe 'brief-open.md=open' <<<"$lline" ||
        missing+="an open brief is not named with its state"$'\n'
    grep -qFe "brief-closed.md=closed@$PF_ANCIENT" <<<"$lline" ||
        missing+="a closed brief does not carry its closing date — the second field is unchecked"$'\n'
    grep -qFe 'audit-request.md=processed' <<<"$lline" ||
        missing+="a document one level down (audits/) is missed"$'\n'
    grep -qFe 'decision-something' <<<"$lline" &&
        missing+="a wiki note is reported as a lifecycle document"$'\n'
    grep -qFe '_session' <<<"$lline" &&
        missing+="a session log is reported as a lifecycle document"$'\n'
    grep -qFe '_PROJECT.md' <<<"$lline" &&
        missing+="_PROJECT.md is reported — a project is not a document with a run"$'\n'
    grep -qFe 'concept-note' <<<"$lline" &&
        missing+="knowledge (status: stable) is reported as process state"$'\n'
fi
# It must stay a scope note: a threshold here would fire on a brief that is legitimately open.
grep -qEe '^(stale-brief|lifecycle-stale):' <<<"$lout" &&
    missing+="an age threshold on lifecycle documents appeared — a brief may stay open for weeks"$'\n'
# The rule must live where every session reads it, not only in the code.
grep -qFe 'lifecycle-docs' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md does not describe the lifecycle-document rule"$'\n'
grep -qFe 'closed:' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md does not require a closing date next to the final status"$'\n'
rm -rf "$lv"
if [ -n "$missing" ]; then
    fail "lifecycle documents are unreported, confused with knowledge, or given a deadline" "$missing"
else
    pass "documents with a lifecycle are inventoried with their state; notes and registries are not"
fi

# ─── 49. The gate states what it did NOT verify, and that is not a failure ─────
# Green must mean "ran and found nothing", never "did not run". Some checks cannot run on
# the machine at hand — check 38 needs a BSD `date` and this machine has none — and until
# now that admission was a phrase inside a green line, collected nowhere. Which is exactly
# why "check 41 has never executed under BSD date" sat as a task on the board rather than
# coming out of the gate that knew it.
# Borrowed from nf-content, where a missing component becomes an explicit item in a list
# instead of a silence. Adapted in one way that matters: it must NOT affect the exit code,
# because a warning that fires on every ordinary run stops being read — measured three
# times in this project already.
# This check is BEHAVIOURAL: it runs this script against itself (guarded by PF_NESTED, one
# level) rather than grepping for the mechanism, because a static check would pass on a
# gap() that is defined, called, and whose output is never printed.
if [ "$PF_NESTED" = "1" ]; then
    pass "coverage-gap reporting (skipped in the nested run)"
else
    missing=""
    nested_out=$(PF_NESTED=1 bash "$0" --fast 2>&1); nested_rc=$?
    grep -qFe 'not verified by this run' <<<"$nested_out" ||
        missing+="the run does not print a coverage-gap block at all"$'\n'
    grep -qFe 'BSD branch of the date fallback' <<<"$nested_out" ||
        missing+="check 38's admission that it could not test the BSD branch is not collected"$'\n'
    grep -qFe 'the install into a clean' <<<"$nested_out" ||
        missing+="--fast does not report the skipped install as a gap"$'\n'
    [ "$nested_rc" -eq 0 ] ||
        missing+="a coverage gap changed the exit code (got $nested_rc) — a gap is not a failure"$'\n'
    grep -qFe 'preflight passed' <<<"$nested_out" ||
        missing+="the gap block replaced the pass line instead of preceding it"$'\n'
    # The gap list must not be silently empty on a machine that has real gaps: an empty
    # block would read as full coverage, the very confusion this check exists to remove.
    n_gaps=$(grep -cEe '^  · ' <<<"$nested_out")
    [ "$n_gaps" -ge 2 ] ||
        missing+="expected at least two gaps in a --fast run, got $n_gaps"$'\n'
    if [ -n "$missing" ]; then
        fail "the gate does not state its own coverage gaps, or turns them into failures" "$missing"
    else
        pass "coverage gaps are collected, named and kept out of the exit code ($n_gaps in a --fast run)"
    fi
fi

# ─── 50. Two rules that the borrowing measured down to their working size ─────
# A: an account without an owner. A bullet of 3+ lines in `Current state` is no longer a
# state but an account, and an account with no `[[link]]` has no full text anywhere — a
# recap living in the one file forbidden to hold recaps. Length is the discriminator by
# measurement, not taste: demanding a link from every bullet reports 16 across the vault
# and fires on one-line statuses that legitimately cite nothing; demanding it only from the
# long ones reports 1. Borrowed from nf-content, where the obligation to link belongs to a
# record TYPE that exists to point at detail, never to every line.
# C: state the diagnosis before changing a status. Measured the same day — a session read a
# verdict as a decision, closed a brief and propagated the closure into four files, every
# edit correct in form. Prose-only by nature (the defect is in the reading), so what a check
# can hold is that the obligation is stated where a status is actually written, derived from
# the files rather than from a hand-kept list.
missing=""
rv=$(mktemp -d); mkdir -p "$rv/p/wiki" "$rv/00-system"
printf -- '# index\n- [[p/_PROJECT]]\n' > "$rv/00-system/index.md"
{ printf -- '---\nproject: p\nupdated: %s\n---\n## Current state\n' "$PF_ANCIENT"
  printf -- '- short bullet with no link at all\n'
  printf -- '- a long bullet that retells something\n  second line of the retelling\n  third line of it\n'
  printf -- '- another long one, but sourced\n  second line\n  third line [[some-note]]\n'
} > "$rv/p/_PROJECT.md"
printf -- '# board\n## In progress\n' > "$rv/p/taskboard.md"
# A decision note outside wiki/ must still be schema-checked: the report claims "entire
# vault", and until 2026-08-17 the filter was the PATH `/wiki/decision-`, so a note in
# 00-shared/concepts/ was read by the vault-wide sweeps and skipped by the schema check.
mkdir -p "$rv/00-shared/concepts"
printf -- '---\nstatus: partially-bogus\ndate: %s\n---\nx\n' "$PF_ANCIENT" \
    > "$rv/00-shared/concepts/decision-outside-wiki.md"
rout=$(bash "$LIBSH" lint-collect "$rv" 2>&1)
grep -qFe 'decision-schema:00-shared/concepts/decision-outside-wiki.md' <<<"$rout" ||
    missing+="a decision note outside wiki/ is not schema-checked, while the report says entire vault"$'\n'
grep -qEe '^retelling-no-source:p	1 bullet' <<<"$rout" ||
    missing+="expected exactly 1 unsourced long bullet, got: $(grep retelling <<<"$rout" || echo none)"$'\n'
# The short bullet must NOT count: that is what keeps this off every ordinary status line.
grep -qEe '^retelling-no-source:p	[2-9]' <<<"$rout" &&
    missing+="a short bullet without a link was counted — the check would fire on plain status"$'\n'
rm -rf "$rv"

# C, derived: any command that writes a final status or closes a task must carry the rule.
for f in "$SCRIPT_DIR"/commands/*.md; do
    writes=$(grep -Ee 'status: (closed|superseded|deprecated)' "$f" || true)
    [ -n "$writes" ] || continue
    cites=$(grep -Ee 'diagnos|диагноз' "$f" || true)
    [ -n "$cites" ] ||
        missing+="$(basename "$f") writes a final status and never mentions stating the diagnosis"$'\n'
done
grep -qFe 'state the diagnosis' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md does not require stating the diagnosis before a status change"$'\n'
if [ -n "$missing" ]; then
    fail "an unsourced account is unreported, or a status change needs no diagnosis" "$missing"
else
    pass "a long unsourced bullet is reported (a short one is not), and status changes owe a diagnosis"
fi

# ─── 51. Every prescribed call is executable AS WRITTEN ────────────────────────
# Open since 2026-08-04, when three places prescribed `brain.sh archive` without its flags:
# the bare form exits 1, and with `--before` but no `--apply` it moves nothing and exits 0.
# Documented that day, checked by nobody — and the class recurred immediately: on 2026-08-17
# `SKILL.md` shipped `brain.sh catalog --project <p>` with no vault argument, which exits 64.
# A prompt names the form; nothing proved the form runs.
#
# What this checks is USAGE, not semantics: every invocation form found in the prompts is
# run against a fixture, and the failure condition is an argument-handling complaint
# (`unknown option`, `no vault at '--…'`, `needs …`). A finding-shaped non-zero exit (2) is
# a legitimate answer and must not read as a broken call.
missing=""
cw=$(mktemp -d)
mkdir -p "$cw/00-system" "$cw/proj/wiki" "$cw/proj/sessions"
printf -- '# index\n- [[proj/_PROJECT]]\n' > "$cw/00-system/index.md"
printf -- '---\nproject: proj\nupdated: %s\nstatus: active\n---\n## Current state\nx\n' "$PF_ANCIENT" \
    > "$cw/proj/_PROJECT.md"
printf -- '# board\n## In progress\n- [ ] open\n## Done\n- [x] %s closed\n' "$PF_ANCIENT" \
    > "$cw/proj/taskboard.md"
printf -- '# Connections\n\n## Knowledge transfers\n\n- %s | [[a]] → b\n' "$PF_ANCIENT" \
    > "$cw/00-system/connections.md"
printf -- '---\nstatus: accepted\ndate: %s\n---\n[[../_PROJECT|_PROJECT]] [[other]]\n' "$PF_ANCIENT" \
    > "$cw/proj/wiki/decision-x.md"
printf -- '# archive\n' > "$cw/proj/archive-notes.md"
printf -- '# CLAUDE.md\n\nProject: proj\n' > "$cw/CLAUDE.md"
: > "$cw/baseline.txt"

# Each row: the form as prescribed, with placeholders bound to the fixture.
run_form() {
    _label="$1"; shift
    _out=$("$@" 2>&1); _rc=$?
    case "$_out" in
        *"unknown option"*|*"unknown command"*|*"unknown argument"*|*"needs "*|*"no vault at '--"*|*"no taskboard at ''"*|*"no connections file at ''"*)
            missing+="$_label is not executable as written: ${_out%%$'\n'*} (rc=$_rc)"$'\n' ;;
    esac
    [ "$_rc" -eq 64 ] && missing+="$_label exits 64 (usage error) as written"$'\n'
    return 0
}
run_form "catalog <vault>"                bash "$LIBSH" catalog "$cw"
run_form "catalog <vault> --project <p>"  bash "$LIBSH" catalog "$cw" --project proj
run_form "lint-collect <vault>"           bash "$LIBSH" lint-collect "$cw"
run_form "lint-collect --project"         bash "$LIBSH" lint-collect "$cw" --project proj
run_form "prose-budget two args"          bash "$LIBSH" prose-budget "$cw/proj/_PROJECT.md" "$cw/proj/taskboard.md"
run_form "claude-md-audit <path>"         bash "$LIBSH" claude-md-audit "$cw/CLAUDE.md"
run_form "local-conventions three args"   bash "$LIBSH" local-conventions "$cw" proj "$cw/CLAUDE.md"
run_form "save-report <vault> <project>"  bash "$LIBSH" save-report "$cw" proj
run_form "stamp-field three args"         bash "$LIBSH" stamp-field "$cw/proj/_PROJECT.md" updated "$PF_ANCIENT"
run_form "sweep-closed <taskboard>"       bash "$LIBSH" sweep-closed "$cw/proj/taskboard.md"
run_form "backfill-dates <taskboard>"     bash "$LIBSH" backfill-dates "$cw/proj/taskboard.md"
run_form "archive with both flags"        bash "$LIBSH" archive "$cw/proj/taskboard.md" "$cw/proj/archive-notes.md" --before 2030-01-01
run_form "vault-language <vault>"         bash "$LIBSH" vault-language "$cw"
run_form "version"                        bash "$LIBSH" version
run_form "obsidian-available <vault>"     bash "$LIBSH" obsidian-available "$cw"
# connections-add reads the entry from stdin, so it needs its own invocation
ca_out=$(printf 'x → y\n' | bash "$LIBSH" connections-add "$cw/00-system/connections.md" "$PF_ANCIENT" 2>&1)
case "$ca_out" in *"unknown option"*|*"needs "*) missing+="connections-add is not executable as written: $ca_out"$'\n' ;; esac
rm -rf "$cw"
if [ -n "$missing" ]; then
    fail "a call prescribed in a prompt does not run as written" "$missing"
else
    pass "all 16 prescribed invocation forms run as written (usage, not semantics)"
fi

# ─── 52. Live docs do not restate a number the code owns; history is left alone ──
# Two halves, and the second one cost more to get right than the first.
#
# The defect: the architecture map forbids writing the check count anywhere but the run
# output (it changed every session and drifted three times), and the Russian architecture
# reference still said `stale-project` fires at 14 days — untrue since 2026-08-16 — and
# described the summed ~60-line prose budget, removed the same day. A doc restating a number
# the code owns is a second copy of it, and copies drift.
#
# The trap, hit while fixing exactly this on 2026-08-17: **most "stale" numbers in these
# files are HISTORY, not claims.** A changelog entry for v1.6.0 saying "23 checks" or "the
# prose threshold counts prose" is correct forever — it records that release. Five of seven
# greps landed inside changelog sections, and editing them falsified the release history
# before the mistake was caught. So the check needs an explicit live/history boundary per
# file, and it must not be "the first `### v` heading": in README the live sections come
# BEFORE the changelog, and in the Russian reference the history is a set of italic
# `*vX.Y.Z — …*` summaries under one late heading.
missing=""
check_live_docs() {
    _f="$1"; _stop="$2"
    [ -f "$_f" ] || return 0
    _live=$(awk -v stop="$_stop" '$0 ~ stop { exit } { print }' "$_f")
    # (a) no live claim about how many checks the gate has
    _cnt=$(grep -nEe '[0-9]+ (checks|проверк)' <<<"$_live" || true)
    [ -z "$_cnt" ] ||
        missing+="$(basename "$_f") states a live check count (the run output owns it): ${_cnt%%$'\n'*}"$'\n'
    # (b) any number presented as a THRESHOLD must be one the code actually holds. A TARGET
    # is a different fact and is not compared: /brain-save asks for ~10 lines of
    # `Current state` while the lint fires at 30, and both are true.
    # Case variants written out rather than tolower(): tolower() on Cyrillic depends on the
    # locale, and this file refuses to trust the locale (see the self-test at the top). The
    # first draft matched lowercase only and went green on a mutated line reading
    # "**Порог прозы — 60 строк**" — capitalised, which is how such a sentence usually starts.
    _claimed=$(awk '/([Пп]орог|[Бб]юджет|[Tt]hreshold|[Bb]udget)/ {
            while (match($0, /~?[0-9]+ (lines|строк)/)) {
                s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s
                $0 = substr($0, RSTART + RLENGTH)
            }
        }' <<<"$_live" | LC_ALL=C sort -u)
    for _c in $_claimed; do
        grep -qxFe "$_c" <<<"$BUDGETS" ||
            missing+="$(basename "$_f") claims a threshold of $_c lines, which no BUDGET_* holds"$'\n'
    done
}
BUDGETS=$(grep -oE '^BUDGET_[A-Z]+=[0-9]+' "$LIBSH" | cut -d= -f2 | LC_ALL=C sort -u)
[ -n "$BUDGETS" ] || missing+="no BUDGET_* found in lib/brain.sh — the comparison had no input"$'\n'
check_live_docs "$SCRIPT_DIR/README.md"     '^## Changelog'
check_live_docs "$SCRIPT_DIR/README_RU.md"  '^## Changelog'
check_live_docs "$SCRIPT_DIR/WORKFLOW.md"   '^## Changelog'
for _r in "$SCRIPT_DIR"/ВТОРОЙ_МОЗГ_*.md; do
    check_live_docs "$_r" '^## Версионирование системы'
done
# The boundary itself must exist, or the whole check silently reads a file as all-live.
for _f in "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/README_RU.md"; do
    grep -qEe '^## Changelog' "$_f" ||
        missing+="$(basename "$_f") has no '## Changelog' heading — the live/history boundary this check needs"$'\n'
done
if [ -n "$missing" ]; then
    fail "live documentation restates a number the code owns" "$missing"
else
    pass "live docs cite no check count and no threshold the code lacks; changelogs untouched"
fi

echo -e "${BLUE}[2/3] Scripts${NC}"
for s in "$SCRIPT_DIR"/*.sh; do
    if bash -n "$s" 2>/dev/null; then
        pass "$(basename "$s"): syntax ok"
    else
        fail "$(basename "$s"): syntax error" "$(bash -n "$s" 2>&1)"
    fi
done

# ─── Install into a clean $HOME ──────────────────────────────────────────────
echo ""
echo -e "${BLUE}[3/3] Install into a clean \$HOME${NC}"
if [ "$FAST" = "1" ]; then
    echo -e "  ${YELLOW}—${NC} skipped (--fast)"
    gap "the install into a clean \$HOME (--fast was passed) — the release gate requires a full run"
else
    TMPHOME=$(mktemp -d)
    trap 'rm -rf "$TMPHOME"' EXIT

    if HOME="$TMPHOME" bash "$SCRIPT_DIR/install.sh" </dev/null >"$TMPHOME/install.log" 2>&1; then
        pass "install.sh ran non-interactively (exit 0)"
    else
        fail "install.sh failed in a clean \$HOME" "$(tail -5 "$TMPHOME/install.log")"
    fi

    missing=""
    for expected in \
        ".claude/skills/second-brain/SKILL.md" \
        ".claude/skills/second-brain/lib/brain.sh" \
        ".claude/skills/second-brain/lib/VERSION" \
        ".claude/commands/brain-setup.md" \
        ".claude/commands/brain-init.md" \
        ".claude/commands/brain-save.md" \
        ".claude/commands/brain-ingest.md" \
        ".claude/commands/brain-lint.md" \
        "Workspace/second-brain-vault/00-system/index.md" \
        "Workspace/second-brain-vault/00-system/connections.md" \
        "Workspace/second-brain-vault/00-shared/CRITICAL_FACTS.md" \
        "Workspace/second-brain-vault/00-shared/SOUL.md" \
        "Workspace/second-brain-vault/.gitignore"; do
        [ -f "$TMPHOME/$expected" ] || missing+="$expected"$'\n'
    done
    if [ -n "$missing" ]; then
        fail "install.sh did not create the expected files" "$missing"
    else
        pass "all 13 expected files are present"
    fi

    # update.sh over an install, twice — it must be idempotent
    if HOME="$TMPHOME" bash "$SCRIPT_DIR/update.sh" >/dev/null 2>&1 &&
       HOME="$TMPHOME" bash "$SCRIPT_DIR/update.sh" >/dev/null 2>&1; then
        pass "update.sh is idempotent (two runs in a row, exit 0)"
    else
        fail "update.sh fails over a fresh install"
    fi

    # What is installed must match the repository byte for byte
    drift=""
    for cmd in brain-setup brain-init brain-save brain-ingest brain-lint; do
        cmp -s "$SCRIPT_DIR/commands/$cmd.md" "$TMPHOME/.claude/commands/$cmd.md" ||
            drift+="$cmd.md differs from the repository"$'\n'
    done
    cmp -s "$SCRIPT_DIR/SKILL.md" "$TMPHOME/.claude/skills/second-brain/SKILL.md" ||
        drift+="SKILL.md differs from the repository"$'\n'
    cmp -s "$SCRIPT_DIR/lib/brain.sh" "$TMPHOME/.claude/skills/second-brain/lib/brain.sh" ||
        drift+="lib/brain.sh differs from the repository"$'\n'
    [ -x "$TMPHOME/.claude/skills/second-brain/lib/brain.sh" ] ||
        drift+="lib/brain.sh was installed without the +x flag"$'\n'
    if [ -n "$drift" ]; then
        fail "the installed files do not match the sources" "$drift"
    else
        pass "the installed files are identical to the sources"
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
if [ -n "$GAPS" ]; then
    echo -e "${YELLOW}━━━ not verified by this run ━━━${NC}"
    printf '%s' "$GAPS" | sed 's/^/  · /'
    echo ""
    echo "  These are gaps in COVERAGE, not failures — the exit code is unaffected."
    echo "  A green above means the checks that ran found nothing, never that everything"
    echo "  was checked. Each line is a task: it needs another machine or another mode."
    echo ""
fi
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}━━━ preflight passed: $PASSED checks ━━━${NC}"
    echo ""
    echo "  The mechanical part is clean. That does NOT mean a tag can be cut:"
    echo "  the soak rule requires /brain-lint --all on the live vault and at least"
    echo "  one session of use before tagging (see CLAUDE.md -> Release gate)."
    echo ""
    exit 0
else
    echo -e "${RED}━━━ preflight failed: $FAILED of $((PASSED + FAILED)) ━━━${NC}"
    echo ""
    exit 1
fi
