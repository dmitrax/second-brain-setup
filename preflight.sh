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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FAILED=0
PASSED=0

# Scan targets. preflight.sh is deliberately NOT among them: it holds the forbidden
# patterns as search strings and would match itself — the same class of mistake as
# `pgrep -f`, which made the guard find its own process (v1.3 -> 2026-07-11).
TARGETS=("$SCRIPT_DIR/SKILL.md" "$SCRIPT_DIR"/commands/brain-*.md)

pass() { PASSED=$((PASSED + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
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
    h=$(code_blocks "$f" | grep -n "obsidian .*[^a-z_]file=" || true)
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
    h=$(code_blocks "$f" | grep -n "obsidian property:set" || true)
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
    [ "$calls" -eq 0 ] && [ "$mentions" -eq 0 ] && continue

    if [ "$mentions" -eq 0 ]; then
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
    if printf '%s\n' "$ob_calls" | grep -qv 'timeout [0-9]'; then
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
    bash "$LIBSH" stamp-field "$TMPLIB/a.md" updated 2026-08-03 >/dev/null 2>&1 ||
        problems+="stamp-field failed on a normal file"$'\n'
    grep -q '^updated: 2026-08-03$' "$TMPLIB/a.md" || problems+="stamp-field did not write the date"$'\n'
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
    grep -q 'done_sec && /\^\[\[:space:\]\]\*-' "$LIBSH" ||
        problems+="archive: entries are counted outside the Done section"$'\n'
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
    printf -- '---\nupdated: 2026-01-01\n---\n# map\n' > "$LCV/proj/architecture-map.md"
    # Three sessions: two carry zone, the third does not -> key-uniformity.
    printf -- '---\ndate: 2026-06-01\nzone: root\n---\nx\n'  > "$LCV/proj/sessions/2026-06-01_1000_session.md"
    printf -- '---\ndate: 2026-06-02\nzone: back\n---\nx\n'  > "$LCV/proj/sessions/2026-06-02_1000_session.md"
    printf -- '---\ndate: 2026-08-01\n---\nx\n'              > "$LCV/proj/sessions/2026-08-01_1000_session.md"

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
    printf -- '---\nproject: other\nupdated: 2026-08-01\n---\n## Current state\nbrief\n' \
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
    printf -- '---\nproject: unreg\nupdated: 2026-08-01\n---\n## Current state\nbrief\n' \
        > "$LCV/unreg/_PROJECT.md"

    # A project NESTED inside another project. This is the class the inventory kept
    # losing: measured 2026-08-04, `nf-content/MWR-Dima` — its own _PROJECT.md, its own
    # taskboard, its own wiki, an entry in the registry — was invisible to every
    # per-project check, because the project list was built from the top level. The file
    # sweeps always saw it, so the discrepancy read as a regression rather than a gap in
    # coverage.
    mkdir -p "$LCV/other/nested"
    printf -- '---\nproject: nested\nupdated: 2020-01-01\n---\n## Current state\nbrief\n' \
        > "$LCV/other/nested/_PROJECT.md"

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

    want 'prose-budget:proj'
    want 'ffc-budget:proj'
    want 'stale-project:proj'
    want 'taskboard-inprogress:proj'
    want 'taskboard-size:proj'
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
    echo "$msg" | grep -qE "^($CC_TYPES)(\([a-zA-Z0-9_.-]+\))?!?: .+" || \
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
elif echo "$CLAUDE_TPL" | grep -qE '^#{2,3} +(Current state|Статус)'; then
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
elif echo "$CLAUDE_TPL" | grep -qE '^#{2,3} +(Stack|Стек)'; then
    fail "the CLAUDE.md template in brain-init.md opened an inventory section — that belongs to _PROJECT.md and architecture-map.md"
elif echo "$CLAUDE_TPL" | grep -qF 'ANSWER TO QUESTION 5'; then
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
missing=""
grep -qi 'Searching the vault' "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: no section about searching the vault"$'\n'
for flag in '`grep -rF`' '`grep -rE`'; do
    grep -qF "$flag" "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: $flag is not prescribed"$'\n'
done
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
# Значение выводится под запись, ключ переносится — иначе копирование значения молча врёт.
grep -qiE 'derive each .*value|value derived' "$BS" ||
    missing+="brain-save.md: потеряно правило «ключ переносится, значение выводится»"$'\n'
grep -qF 'key-uniformity' "$SCRIPT_DIR/lib/brain.sh" ||
    missing+="lib: нет проверки однородности ключей frontmatter"$'\n'
grep -qF 'key-uniformity' "$SCRIPT_DIR/commands/brain-lint.md" ||
    missing+="brain-lint.md: находка key-uniformity не описана"$'\n'
if [ -n "$missing" ]; then
    fail "локальные конвенции frontmatter не защищены (шаблон читается как исчерпывающий)" "$missing"
else
    pass "шаблоны объявлены минимумом, шаг поиска локальных ключей до записи, lint 10b на месте"
fi

# ─── 17. Счётчик таскборда видит оба маркера и мерит не только Done ──────────
# Два дефекта одного класса «зелёное ≠ проверенное», найдены 2026-08-03.
# (1) Счётчик искал только `- [x]`, а cadrika пишет `- ✅` — её 16 закрытых пунктов
#     были невидимы, порог не сработал бы и на сотне.
# (2) Порог считал только Done, поэтому goprofi-voronka проходил как здоровый при
#     2131 строке, из них 1074 в `## In progress` — секция, которую сессия не может
#     удержать в контексте, отчего задачи дописываются вслепую и дублируются.
# Тот же перекос чинили у _PROJECT.md, заменив общий размер бюджетом прозы.
missing=""
BL="$SCRIPT_DIR/lib/brain.sh"
grep -qF '✅' "$BL" || missing+="lib: счётчик Done не знает маркер ✅"$'\n'
grep -qF '[x]' "$BL" || missing+="lib: счётчик Done не знает маркер [x]"$'\n'
# Ищем сам замер, а не слова «In progress» в прозе: первая редакция этой проверки
# матчила описание находки и потому не заметила бы удаление кода.
grep -qE '^[[:space:]]*prog=\$\(' "$BL" ||
    missing+="lib: нет замера размера секции In progress (переменная prog=)"$'\n'
# Счётчик Done обязан считать ВНУТРИ секции Done. Замерено 2026-08-03: по всему файлу
# goprofi-voronka давал 83 против 19, dimarch 31 против 8, собственный таскборд 65
# против 5 — закрытые подпункты открытых задач считались архивируемыми записями.
# Счётчики уехали в _budget_* (одна реализация на линт и на запись, проверка 25),
# поэтому смотрим их тела, а не строку вызова. Требуемое свойство то же и не ослаблено:
# внутри счётчика Done обязан стоять фильтр по секции.
done_body=$(awk '/^_budget_done\(\)/ { f = 1 } f { print } f && /^}/ { exit }' "$BL")
if [ -z "$done_body" ]; then
    missing+="lib: функции _budget_done нет — счётчик Done негде проверить"$'\n'
else
    printf '%s\n' "$done_body" | grep -qF '## (Done|Завершено)' ||
        missing+="lib: счётчик Done не знает, где секция Done"$'\n'
    # Наличия шаблона секции мало: он может лежать в теле и не участвовать в счёте.
    # Требуем, чтобы строка счёта была ЗАКРЫТА этим флагом. Поймано негативным тестом
    # 2026-08-04: снятие флага с условия оставляло проверку зелёной.
    printf '%s\n' "$done_body" | grep -qE '^[[:space:]]*d &&' ||
        missing+="lib: счётчик Done считает по всему файлу, не по секции Done"$'\n'
fi
grep -qE '^BUDGET_PROG=[0-9]{2,}' "$BL" ||
    missing+="lib: у секции In progress нет порога (BUDGET_PROG)"$'\n'
grep -qF '"$prog" -gt "$BUDGET_PROG"' "$BL" ||
    missing+="lib: размер In progress не сравнивается со своим порогом"$'\n'
grep -qF 'taskboard-inprogress:' "$BL" ||
    missing+="lib: потеряна метрика In progress — снова мерится только Done"$'\n'
if [ -n "$missing" ]; then
    fail "счётчик таскборда снова слеп (маркер или метрика)" "$missing"
else
    pass "счётчик таскборда видит [x] и ✅, мерит Done + In progress + размер"
fi

# ─── 18. Код-блоки промптов исполняются оболочкой сессии (на macOS — zsh) ────
# Планка bash 3.2 (проверка 14) закрывает *.sh — у них свой shebang. Но fenced-блоки
# внутри SKILL.md и commands/*.md исполняет оболочка сессии, а на Маке это zsh.
# Замерено 2026-08-03, оба раза с ложной зеленью: `[ "$a" \< "$b" ]` в zsh падает с
# `condition expected` (шаг проверки версии карты напечатал «ok» по всем проектам,
# включая отставший), а `for p in $LIST` не делит переменную на слова (весь список
# обработался как одна строка). Граница проведена так: всё, что требует специфики
# оболочки, живёт в lib/brain.sh (свой shebang, гарантированный bash); в блоках
# промптов — только то, что одинаково в bash и zsh.
hits=""
for f in "${TARGETS[@]}"; do
    blocks=$(code_blocks "$f")
    h=""
    # `\<` / `\>` в [ ]: в zsh это перенаправление, а не сравнение строк
    echo "$blocks" | grep -nE '\[[^]]*\\[<>]' >/dev/null 2>&1 &&
        h+="  \\< или \\> внутри [ ] — в zsh это не сравнение"$'\n'
    # словоделение неквотированной переменной: в zsh его нет
    echo "$blocks" | grep -nE 'for [A-Za-z_]+ in \$[A-Za-z_{]' >/dev/null 2>&1 &&
        h+="  for ... in \$VAR — в zsh переменная не делится на слова"$'\n'
    # ${var:0:1} — разная семантика индексации
    echo "$blocks" | grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*:[0-9]+:[0-9]+\}' >/dev/null 2>&1 &&
        h+="  \${var:N:M} — индексация различается"$'\n'
    # массивы: индексация с 0 в bash и с 1 в zsh
    echo "$blocks" | grep -nE '\$\{[A-Za-z_]+\[[@*]\]\}' >/dev/null 2>&1 &&
        h+="  массивы — индексация с 0 в bash и с 1 в zsh, выносить в lib/"$'\n'
    # builtins, которых в zsh нет вовсе
    echo "$blocks" | grep -nE '\b(map''file|read''array|declare -''A|shopt)\b' >/dev/null 2>&1 &&
        h+="  bash-only builtin — выносить в lib/brain.sh"$'\n'
    # Шестой класс, найден 2026-08-04: несовпавший glob. В zsh это фатальная ошибка —
    # команда не выполняется ВОВСЕ, и `2>/dev/null` её не глушит, потому что печатает
    # её шелл до того, как перенаправление применится к команде; в bash тот же glob
    # уходит литеральным аргументом. Ни один из двух исходов не является пустым
    # списком, а код возврата конвейера остаётся 0.
    # Замерено на /brain-save Step 0c: `ls -1 ".../sessions/"*.md` на проекте без
    # логов — то есть на первом же сохранении нового проекта, ради которого шаг и
    # написан — молча давал ноль. Мера: `find <dir> -name "<pat>"`, где паттерн
    # закавычен и разворачивает его find, а не оболочка.
    g=$(unquoted_globs "$f")
    [ -n "$g" ] && h+="  незакавыченный glob — в zsh несовпадение отменяет команду:"$'\n'"$(printf '%s\n' "$g" | sed 's/^/    /')"$'\n'
    [ -n "$h" ] && hits+="$(basename "$f"):"$'\n'"$h"
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
    fail "проверка 18 не получила ни одного файла — вход пуст, а не чист"
elif [ -n "$hits" ]; then
    fail "конструкция, расходящаяся между bash и zsh, в code-блоке промпта" "$hits"
else
    pass "код-блоки промптов переносимы между bash и zsh (6 классов не встречаются)"
fi

# ─── 19. Вывод о состоянии обязан проверять свою посылку ────────────────────
# Один класс, найден 2026-08-03 на первом же сохранении под новым кодом: команда
# делает верное действие и сопровождает его утверждением, посылку которого никто
# не проверял. Оба места — в /brain-save, оба молчаливы.
# (1) Предупреждение о версии называло «пропустившими update.sh» проекты со значением
#     `1.3`. Это не штамп, а литерал старого шаблона /brain-init: вписывался при
#     создании проекта и ни о какой машине не свидетельствует. Пять проектов были
#     объявлены отставшими, притом что они просто не сохранялись после 03.08.
#     Форматы `1.3` и `v1.6.0-10-g34f5287` вдобавок не упорядочены друг против друга.
# (2) «Удаляй старые записи — они остаются в sessions/» есть утверждение о конкретной
#     записи, а не свойство секции. У выброшенной записи `_mac/mac-setup` от 15.07
#     лога не было и нет; факты уцелели в architecture-map.md по везению, не по проверке.
#     Тот же случай ловили руками 26.07 в goprofi-voronka — в текст правила он не въехал.
missing=""
BS="$SCRIPT_DIR/commands/brain-save.md"
grep -qF 'Compare only real stamps' "$BS" ||
    missing+="brain-save.md: сравнение версий не требует, чтобы оба значения были штампами"$'\n'
grep -qF 'v<MAJOR>.<MINOR>.<PATCH>' "$BS" ||
    missing+="brain-save.md: не описан формат настоящего штампа"$'\n'
grep -qF 'the old `/brain-init` literal' "$BS" ||
    missing+="brain-save.md: легаси-значения не названы литералом /brain-init"$'\n'
grep -qF 'not ordered against each other' "$BS" ||
    missing+="brain-save.md: два формата версии сравниваются как упорядоченные"$'\n'
grep -qF 'have not been saved since stamping' "$BS" ||
    missing+="brain-save.md: потерян верный вывод для легаси-значения (не «старая установка»)"$'\n'
grep -qF 'Before deleting an entry' "$BS" ||
    missing+="brain-save.md: удаление записи из «Последней сессии» ничем не обусловлено"$'\n'
grep -qF 'must exist. If it does not' "$BS" ||
    missing+="brain-save.md: не требуется, чтобы session log удаляемой записи существовал"$'\n'
if [ -n "$missing" ]; then
    fail "вывод о состоянии делается без проверки посылки (версия / удаление записи)" "$missing"
else
    pass "brain-save сверяет форматы версий и не удаляет запись без живого session log"
fi

# ─── 20. Имя команды не гарантирует инструмент ──────────────────────────────
# Проверка 18 закрывает синтаксис оболочки. Эта — то, ВО ЧТО разрешается имя команды.
# Замерено 2026-08-03 на рабочем Маке: `date` и `xargs` — GNU из Homebrew (gnubin в
# PATH), а `ls` и `grep` вообще shell-функции из снапшота Claude Code. Одно имя, три
# разных источника, и код промпта не может знать, какой достанется.
# Картина отказа каждый раз одна и та же: команда отработала, вывод пуст, проверка
# зелёная. В тот день `date -j` (BSD-форма) не существовал вовсе, и два шага линта
# молча дали ноль находок вместо ошибки; поймано только сверкой с baseline.
# Своим shebang'ом это НЕ лечится, в отличие от класса проверки 18: `#!/bin/bash`
# задаёт оболочку, а не PATH — lib/brain.sh получает те же самые бинарники. Значит
# мера другая: либо флаги, одинаковые в GNU и BSD, либо явный фоллбек в коде.
missing=""
# Паттерны собраны из кусков, иначе проверка нашла бы саму себя.
NONPORTABLE="date -""j|date -""d|date --""date|stat -""f |stat -""c |sed -""i|readlink -""f|grep -""P"
scanned=0
for f in "$SCRIPT_DIR/SKILL.md" "$SCRIPT_DIR"/commands/*.md "$SCRIPT_DIR"/lib/*.sh \
         "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh"; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    # строка с явным фоллбеком (две формы через ||) — это и есть требуемая мера
    h=$(grep -nE "$NONPORTABLE" "$f" | grep -v '||' | grep -v '^\s*#')
    [ -n "$h" ] && missing+="$(basename "$f"):"$'\n'"$(printf '%s\n' "$h" | sed 's/^/  /')"$'\n'
done
# Вторая половина того же класса, и она про имя, а не про флаг: `ls` в блоке промпта
# исполняет оболочка сессии, где это может быть чем угодно. Замерено 2026-08-04 на этой
# машине: `ls` — функция `eza --icons=auto` из ~/.zshrc, попавшая в снапшот Claude Code.
# Комментарий выше называл `ls` примером проблемы с самого начала, а список паттернов
# его не содержал, потому что проверка искала флаги. Разбор форматированного вывода
# чужой реализации `ls` — не то, на чём должен стоять шаг команды: `find` разворачивает
# паттерн сам и не имеет вариантов вывода.
# Область — только промпты: скрипт, запущенный как `bash lib/brain.sh`, функции
# оболочки не наследует (они не экспортированы), так что там `ls` — настоящий бинарник.
for f in "${TARGETS[@]}"; do
    [ -f "$f" ] || continue
    h=$(code_blocks "$f" | grep -nE '(^|[|;(&]|[[:space:]])ls([[:space:]]|$)')
    [ -n "$h" ] && missing+="$(basename "$f") — вызов ls в блоке промпта (в оболочке сессии это может быть функция):"$'\n'"$(printf '%s\n' "$h" | sed 's/^/  /')"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "проверка 20 не открыла ни одного файла — вход пуст, а не чист"
elif [ -n "$missing" ]; then
    fail "имя, разрешающееся непредсказуемо, без фоллбека (shebang это не лечит)" "$missing"
else
    pass "непортируемые флаги и имена команд отсутствуют или имеют фоллбек ($scanned файлов)"
fi

# ─── 21. Линт объявляет охват, а не предполагает его ────────────────────────
# Синхронизация делает чекаут СВЕЖИМ, но не ПОЛНЫМ: sparse-checkout оставляет
# отслеживаемые пути вне рабочего дерева, и каждая проверка линта меряет подмножество,
# продолжая называть результат обходом vault. Отличить «файла нет» от «файл не выложен»
# изнутри проверки нельзя — только этим шагом.
# Замерено 2026-08-04 на Маке с исключённым /_arch (228 файлов): `obsidian unresolved`
# показал 93 битые ссылки, из них 91 — на файлы, существующие и верные на другой машине;
# после снятия исключения осталась 1. Плюс три находки baseline ушли в GONE, не будучи
# исправленными: база общая для машин, а видимость — своя, поэтому --seal с неполного
# чекаута стирает чужие находки, и следующий запуск на другой машине показывает их как
# NEW. Экономии при этом нет — ~4% чекаута, и конфиденциальности тоже: объекты лежат
# в .git и читаются через `git cat-file`.
lf="$SCRIPT_DIR/commands/brain-lint.md"
if [ ! -f "$lf" ]; then
    fail "проверка 21: commands/brain-lint.md отсутствует — вход пуст, а не чист"
else
    missing=""
    grep -qF 'core.sparseCheckout' "$lf" || missing+="не определяет sparse-checkout"$'\n'
    grep -qF 'ls-files -v' "$lf" || missing+="не ловит skip-worktree (config сам по себе не полон)"$'\n'
    grep -qF 'PARTIAL' "$lf" || missing+="нечем пометить неполный охват"$'\n'
    grep -qE 'Coverage:' "$lf" || missing+="в шаблоне отчёта нет строки охвата"$'\n'
    grep -qE 'Do not .*--seal|не .*--seal' "$lf" || missing+="не запрещает --seal с неполного чекаута"$'\n'
    if [ -n "$missing" ]; then
        fail "brain-lint не объявляет фактический охват — отчёт будет притворяться полным" "$missing"
    else
        pass "линт определяет неполный чекаут, объявляет охват и не печатает базу с него"
    fi
fi

# ─── 22. Правило про ссылки в заметках выполнимо и измеряется ───────────────
# Правило требовало «минимум 2 [[wikilink]] на заметку», а шаблон decision-заметки в
# brain-save давал `[[../_PROJECT]]` плюс необязательный placeholder — значит заметка,
# первая по своей теме, рождалась нарушением, и так родились 6 из 383 (замер 2026-08-04).
# Планка, которую собственный шаблон не может взять, — не стандарт, а вечное нарушение;
# оно же толкает выдумывать ссылки, а выдуманная связь хуже отсутствующей, потому что
# граф читают как свидетельство, что связь есть. Правило переписано на «обратная ссылка
# обязательна + соседняя, когда соседняя существует» и получило шаг линта 4c.
missing=""
if [ ! -f "$SCRIPT_DIR/SKILL.md" ] || [ ! -f "$SCRIPT_DIR/commands/brain-lint.md" ]; then
    fail "проверка 22: нет SKILL.md или brain-lint.md — вход пуст, а не чист"
else
    grep -qE 'Minimum 2 \[\[|minimum 2 \[\[' "$SCRIPT_DIR/SKILL.md" \
        && missing+="SKILL.md всё ещё требует невыполнимый минимум в 2 ссылки"$'\n'
    grep -qF 'backlink is mandatory' "$SCRIPT_DIR/SKILL.md" \
        || missing+="SKILL.md не объявляет обратную ссылку обязательной"$'\n'
    grep -qF 'wiki-no-backlink' "$SCRIPT_DIR/lib/brain.sh" \
        || missing+="lib: правило без машинной проверки (нет wiki-no-backlink)"$'\n'
    grep -qF 'wiki-no-links' "$SCRIPT_DIR/lib/brain.sh" \
        || missing+="lib: не выделяются тупиковые заметки"$'\n'
    grep -qF '_lc_strip' "$SCRIPT_DIR/lib/brain.sh" \
        || missing+="lib: не снимается inline-code — литералы посчитаются ссылками"$'\n'
    grep -qF 'wiki-no-sibling' "$SCRIPT_DIR/commands/brain-lint.md" \
        || missing+="brain-lint.md: не сказано, что отсутствие соседней ссылки — не дефект"$'\n'
    if [ -n "$missing" ]; then
        fail "правило о ссылках невыполнимо или не измеряется" "$missing"
    else
        pass "правило о ссылках выполнимо (backlink + соседняя при наличии) и меряется шагом 4c"
    fi
fi

# ─── 23. Конвенцией считается ключ со ЗНАЧЕНИЕМ, а не сам ключ ──────────────
# Step 10b считал ключ конвенцией по факту присутствия. Шаблон decision-заметки печатает
# `supersedes:` пустым, заполняют его единицы — и он попадал в конвенции, после чего
# заметки без этой пустой строки объявлялись нарушителями. Замер 2026-08-04: пуст или
# отсутствует у 29 из 32 в cadrika, 95 из 100 в goprofi-voronka, 33 из 34 здесь. Находка
# была шумом и лежала в общем baseline, где зелёная строка рядом читается как проверенная.
# Ложная находка дороже пропущенной: она приучает читателя пролистывать список.
# Заодно: `ls` в старом коде — тот же класс, что `date -j` (на Маке это функция-обёртка
# над eza), поэтому счёт файлов ушёл на find.
lb="$SCRIPT_DIR/lib/brain.sh"
if [ ! -f "$lb" ]; then
    fail "проверка 23: lib/brain.sh отсутствует — вход пуст, а не чист"
else
    missing=""
    grep -qF 'only when it carries a VALUE' "$lb" \
        || missing+="10b не требует непустого значения — пустой ключ шаблона станет конвенцией"$'\n'
    # Паттерн собран из кусков: иначе проверка нашла бы саму себя, как это уже
    # сделала проверка 20 на прозе, где сломанная форма была процитирована буквально.
    LSCOUNT="ls"" -1 \*\.md"
    grep -qE "$LSCOUNT" "$lb" \
        && missing+="10b считает файлы через ls (на Маке это функция-обёртка)"$'\n'
    if [ -n "$missing" ]; then
        fail "Step 10b принимает за конвенцию артефакт шаблона" "$missing"
    else
        pass "Step 10b считает конвенцией только ключ со значением, файлы — через find"
    fi
fi

# ─── Синтаксис шелл-скриптов ─────────────────────────────────────────────────
echo ""
# ─── 25. Бюджет меряется в момент записи, и одним кодом с линтом ────────────
# Порог, который меряет только /brain-lint, меряется через сутки и кем придётся: тот,
# кто перерасход СОЗДАЛ, о нём не узнаёт, и приписать его конкретной сессии некому.
# Замерено 2026-08-03: `_mac/mac-setup` вырос 51→62 и 28→35 сохранением в 22:03 и
# всплыл через час на другой машине; за одну сессию 2240 собственный `_PROJECT.md`
# этого проекта переходил бюджет ЧЕТЫРЕ раза обычными правками статуса, и каждый раз
# об этом сообщал линт, запущенный руками.
# Вторая половина проверки — про то, что реализация одна. Две копии порога расходятся,
# и тогда «находка» становится тем, что видит только один из двух вызывающих; этот
# проект встретил ровно эту форму уже в четырёх проверках.
bs="$SCRIPT_DIR/commands/brain-save.md"
lb="$SCRIPT_DIR/lib/brain.sh"
missing=""
if [ ! -f "$bs" ] || [ ! -f "$lb" ]; then
    fail "проверка 25: нет brain-save.md или lib/brain.sh — вход пуст, а не чист"
else
    grep -qF 'prose-budget' "$bs" || missing+="brain-save не вызывает prose-budget"$'\n'
    # Порядок: мерить таскборд до того, как Step 4 его правит, — мерить не то.
    n_tb=$(grep -n '^## Step 4:' "$bs" | head -1 | cut -d: -f1)
    n_pb=$(grep -n 'brain-budget\|prose-budget' "$bs" | head -1 | cut -d: -f1)
    if [ -n "$n_tb" ] && [ -n "$n_pb" ]; then
        [ "$n_pb" -gt "$n_tb" ] || missing+="вызов prose-budget стоит ВЫШЕ правки таскборда — мерит предыдущее состояние"$'\n'
    else
        missing+="не найден Step 4 или вызов prose-budget, чтобы сверить порядок"$'\n'
    fi
    grep -qE 'не заканчивать молча|Never finish the save silently' "$bs" ||
        missing+="перерасход разрешено завершить молча"$'\n'
    # Одна реализация: пороги — переменные, и lint_collect читает те же самые.
    for v in BUDGET_PROSE BUDGET_FFC BUDGET_DONE BUDGET_PROG BUDGET_SIZE; do
        n=$(grep -c "^$v=" "$lb")
        [ "$n" -eq 1 ] || missing+="$v определён $n раз(а), должен ровно один"$'\n'
        grep -qF "\$$v" "$lb" || missing+="$v нигде не используется"$'\n'
    done
    # Проверка ЗАПУСКОМ на фикстуре, а не грепом формы: три исхода обязаны различаться.
    fx=$(mktemp -d)
    printf -- '---\nupdated: 2026-08-04\n---\n## Current state\nодна строка\n' > "$fx/_PROJECT.md"
    printf -- '# tb\n## In progress\n- [ ] one\n## Done\n- [x] 2026-08-01 done\n' > "$fx/taskboard.md"
    bash "$lb" prose-budget "$fx/_PROJECT.md" "$fx/taskboard.md" >/dev/null 2>&1
    [ $? -eq 0 ] || missing+="в пределах бюджета exit не 0"$'\n'
    # перерасход: раздуваем For future Claude выше своего порога
    { printf -- '---\nupdated: 2026-08-04\n---\n## For future Claude\n'
      i=0; while [ $i -lt 40 ]; do echo "- строка $i"; i=$((i + 1)); done; } > "$fx/_PROJECT.md"
    bash "$lb" prose-budget "$fx/_PROJECT.md" "$fx/taskboard.md" >/dev/null 2>&1
    [ $? -eq 2 ] || missing+="перерасход не даёт exit 2"$'\n'
    # счётчик не отработал: это ошибка, а не «в пределах бюджета»
    sed 's|^_budget_ffc()   { _lc_section|_budget_ffc()   { _no_such_counter|' "$lb" > "$fx/broken.sh"
    if cmp -s "$fx/broken.sh" "$lb" || [ ! -s "$fx/broken.sh" ] || ! bash -n "$fx/broken.sh" 2>/dev/null; then
        missing+="МЕТА: поломка счётчика не применилась — тест проверял бы свою опечатку"$'\n'
    else
        bash "$fx/broken.sh" prose-budget "$fx/_PROJECT.md" "$fx/taskboard.md" >/dev/null 2>&1
        [ $? -eq 1 ] || missing+="неотработавший счётчик не даёт exit 1 (зелёное вместо ошибки)"$'\n'
    fi
    rm -rf "$fx"
    if [ -n "$missing" ]; then
        fail "бюджет не меряется при записи или меряется вторым кодом" "$missing"
    else
        pass "prose-budget вызывается после правок, различает три исхода, пороги в одном месте"
    fi
fi

# ─── 33. Имена секций матчатся на ОБОИХ языках ──────────────────────────────
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
    fail "проверка 33: нет lib/brain.sh — вход пуст, а не чист"
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
        [ -n "$orphans" ] && missing+="  '$en' матчится без '$ru':"$'\n'"$(printf '%s\n' "$orphans" | cut -c1-90 | sed 's/^/    /')"$'\n'
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
        printf '%s\n' "$lb_code" | grep -qF "$ru" ||
            missing+="  паттерн '$ru' исчез из кода lib/brain.sh"$'\n'
    done
    if [ -n "$missing" ]; then
        fail "имена секций матчатся не на обоих языках — русский ваулт станет невидим" "$missing"
    else
        pass "имена секций матчатся на обоих языках ($checked пар + 5 паттернов на месте)"
    fi
fi

# ─── 32. Публичное — по-английски: коммиты и комментарии в коде ─────────────
# Репо публичный. Сообщение коммита и комментарий в коде читает посторонний и
# следующий сопровождающий — раньше всего остального. Правило про язык существовало,
# но перечисляло ФАЙЛЫ (`SKILL.md`, `brain-*.md`, имена файлов, Block 1) и не называло
# ни коммиты, ни комментарии, при том что вся видимая история была на английском.
# 2026-08-04 в репозиторий уехало 8 коммитов на русском: формат Conventional Commits
# они прошли (проверка 9 смотрит форму, не язык), практику — нет.
# Две вещи, которые проверка обязана различать и которые грубый грep смешивает:
#   * heredoc в *.sh генерирует РУССКИЕ файлы ваулта (index.md, SOUL.md) — это
#     содержимое пользователя, а не комментарий;
#   * `##`-заголовки в шаблонах внутри commands/*.md — тоже содержимое, не код.
# Перевод того и другого сломал бы ваулт, поэтому область — только shell-комментарии
# вне heredoc и только в блоках ```bash у промптов.
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
# Сообщения коммитов — с даты принятия правила. Раньше неё история не переписывается,
# та же граница, что у проверки 9.
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
[ -n "$bad_msgs" ] && missing+="  сообщения коммитов с кириллицей:"$'\n'"$(printf '%s\n' "$bad_msgs" | sed 's/^/    /')"$'\n'
# Правило существует в трёх местах и обязано называть обе вещи во всех трёх.
for f in "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/chat-skills/brain-onboarding/SKILL.md"; do
    [ -f "$f" ] || continue
    # Окно, а не строка: правило может занимать абзац, и построчный грep объявил бы
    # нарушением собственную развёрнутую формулировку.
    n_rule=$(grep -c 'Language:' "$f")
    n_named=$(awk '
        /Language:/ { w = $0; for (i = 0; i < 6 && (getline nxt) > 0; i++) w = w " " nxt
                      # Точные формулировки во множественном числе, а не любое
                      # упоминание слов: соседняя проза («a comment and a commit
                      # message are read by strangers») удовлетворяла слабой версии
                      # этой проверки, и негативный тест это показал.
                      if (w ~ /commit messages/ && w ~ /code comments/) n++ }
        END { print n + 0 }' "$f")
    [ "$n_rule" -eq "$n_named" ] ||
        missing+="  $(basename "$f"): $n_rule формулировок правила, коммиты и комментарии названы в $n_named"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "проверка 32 не открыла ни одного файла — вход пуст, а не чист"
elif [ -n "$missing" ]; then
    fail "русский там, где репо говорит с посторонними" "$missing"
else
    pass "коммиты и комментарии в поставляемом коде по-английски ($scanned файлов)"
    # Область названа вслух: preflight.sh сюда не входит и это НЕ значит, что он чист.
    echo "      (вне области: preflight.sh — 491 русский комментарий, dev-only, не ставится)"
fi

# ─── 31. `grep -q` не стоит на конце конвейера под pipefail ─────────────────
# `set -uo pipefail` стоит строкой 13. Под ним `grep -q` (и `-qv`) выходит по первому
# подходящему входу, продюсер получает SIGPIPE и завершается с 141, а статусом всего
# конвейера становится именно 141 — то есть УСПЕШНОЕ совпадение читается как провал.
# Замерено 2026-08-04: проверка 26 краснела при полностью рабочем предупреждении, и —
# что хуже — негативный тест на ней дал ложное «краснеет», потому что она была красной
# и до мутации. Одна такая строка обесценивает и проверку, и тест на неё.
# Мера: забрать вывод в переменную и грепать `printf '%s\n' "$var"`. Тогда продюсер
# завершается до грепа и SIGPIPE не возникает.
# Свип по существующему коду под это правило нашёл второй экземпляр — проверку
# «obsidian без timeout», где не стреляло только из-за короткого вывода.
missing=""
scanned=0
for f in "$SCRIPT_DIR/preflight.sh" "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/update.sh"; do
    [ -f "$f" ] || continue
    scanned=$((scanned + 1))
    # Продюсер printf/echo/cat/sed завершается сам и SIGPIPE не получает — они не в счёт.
    # Quoted spans are stripped first: a check may legitimately SEARCH for the string
    # "grep -q", and a pattern is data, not a pipeline. Caught by check 33's own line.
    h=$(sed -E "s@'[^']*'@@g; s@\"[^\"]*\"@@g" "$f" | grep -nE '\| *grep -q' |
        grep -vE '^\s*[0-9]+:\s*#' |
        grep -vE "(printf|echo|cat|sed|comm|sort|cut|head -[0-9]+) [^|]*\| *grep -q")
    [ -n "$h" ] && missing+="$(basename "$f"):"$'\n'"$(printf '%s\n' "$h" | sed 's/^/    /')"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "проверка 31 не открыла ни одного файла — вход пуст, а не чист"
elif [ -n "$missing" ]; then
    fail "grep -q на конце конвейера: под pipefail SIGPIPE продюсера читается как провал" "$missing"
else
    pass "grep -q не стоит за долгим продюсером ($scanned файлов)"
fi

# ─── 29. В публичный репо не уезжают личные данные ──────────────────────────
# Правило «не добавлять личные данные в этот репо» стояло в CLAUDE.md Block 2 с самого
# начала и НЕ имело машинной проверки — при том что тот же Block 2 требует проверку для
# каждого своего правила. Прозой оно живёт ровно до следующей сессии, а цена ошибки
# необратима: репо публичный, и запушенное уже склонировано.
# Имя пользователя и хост НЕ захардкожены, а берутся из окружения: хардкод был бы сам
# той утечкой, которую проверка ищет, и сломал бы её у всех, кто поставит пакет.
missing=""
scanned=0
PD_U=$(basename "$HOME")
PD_HN=$(hostname 2>/dev/null | sed 's/\..*//')
# Паттерны ключей собраны из кусков, иначе проверка нашла бы саму себя.
PD_KEY="sk-""[A-Za-z0-9]{20,}|ghp_""[A-Za-z0-9]{20,}|AKIA""[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY"
PD_FILES=$(cd "$SCRIPT_DIR" && git ls-files 2>/dev/null | grep -v '^preflight\.sh$')
if [ -z "$PD_FILES" ]; then
    fail "проверка 29 не получила списка файлов (git ls-files пуст) — вход пуст, а не чист"
else
    for f in $PD_FILES; do
        [ -f "$SCRIPT_DIR/$f" ] || continue
        scanned=$((scanned + 1))
        h=""
        [ -n "$PD_U" ] && grep -qF "/$PD_U" "$SCRIPT_DIR/$f" 2>/dev/null && h="${h}домашний путь пользователя; "
        [ -n "$PD_HN" ] && [ ${#PD_HN} -ge 4 ] && grep -qiF "$PD_HN" "$SCRIPT_DIR/$f" 2>/dev/null && h="${h}имя машины; "
        grep -qE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-z]{2,}' "$SCRIPT_DIR/$f" 2>/dev/null && h="${h}e-mail; "
        grep -qE "$PD_KEY" "$SCRIPT_DIR/$f" 2>/dev/null && h="${h}похоже на ключ/токен; "
        [ -n "$h" ] && missing+="  $f: $h"$'\n'
    done
    if [ "$scanned" -eq 0 ]; then
        fail "проверка 29 не открыла ни одного файла — вход пуст, а не чист"
    elif [ -n "$missing" ]; then
        fail "личные данные в файле публичного репо" "$missing"
    else
        pass "личных данных в отслеживаемых файлах нет ($scanned файлов)"
    fi
fi

# ─── 30. Данные ваулта не исполняются ───────────────────────────────────────
# Весь lib/ читает ваулт: имена файлов, значения frontmatter, тела заметок. Это ВХОДНЫЕ
# данные, и часть их приходит из `raw/`, который пакет сам объявляет недоверенным.
# Проверяется запуском на враждебной фикстуре, а не чтением кода: признак — не слово в
# выводе, а НЕИЗМЕННОСТЬ дерева. Любой файл, появившийся после прогона, означает, что
# подстановка выполнилась.
# Что этот тест НЕ доказывает, и это важно записать: снятие кавычек его не краснит —
# bash не переисполняет значение переменной, так что неквотированный `$p` даёт
# словоделение, а не исполнение. Красит его только настоящий вектор: eval, sh -c,
# bash -c. Поэтому к динамической половине добавлена статическая — их отсутствие.
missing=""
grep -nE '\beval\b|\bsh -c\b|\bbash -c\b' "$SCRIPT_DIR"/lib/*.sh >/dev/null 2>&1 &&
    missing+="в lib/ появился eval / sh -c / bash -c — данные ваулта могут стать командой:"$'\n'"$(grep -nE '\beval\b|\bsh -c\b|\bbash -c\b' "$SCRIPT_DIR"/lib/*.sh | sed 's/^/    /')"$'\n'
ij=$(mktemp -d)
mkdir -p "$ij/00-system" "$ij/proj/wiki"
printf -- '# index\n- [[proj/_PROJECT]]\n' > "$ij/00-system/index.md"
printf -- '---\nupdated: 2026-08-04\n---\n## Current state\nx\n' > "$ij/proj/_PROJECT.md"
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
    fail "проверка 30: враждебная фикстура не создалась ($n_fx файлов) — тест проверял бы свою опечатку"
    rm -rf "$ij"
else
    find "$ij" | sort > "$ij.before"
    bash "$SCRIPT_DIR/lib/brain.sh" lint-collect "$ij"                                  >/dev/null 2>&1
    bash "$SCRIPT_DIR/lib/brain.sh" prose-budget "$ij/proj/_PROJECT.md"                 >/dev/null 2>&1
    bash "$SCRIPT_DIR/lib/brain.sh" local-conventions "$ij" proj "$ij/proj/_PROJECT.md" >/dev/null 2>&1
    find "$ij" | sort > "$ij.after"
    added=$(diff "$ij.before" "$ij.after" | grep '^>' | sed 's/^> /    /')
    [ -n "$added" ] && missing+="после прогона появились файлы — подстановка выполнилась:"$'\n'"$added"$'\n'
    grep -qiE 'untrusted|недовер' "$SCRIPT_DIR/SKILL.md" ||
        missing+="SKILL.md не объявляет raw/ недоверенным"$'\n'
    grep -qiE 'untrusted|недовер' "$SCRIPT_DIR/commands/brain-ingest.md" ||
        missing+="/brain-ingest не объявляет raw/ недоверенным — а читает его именно он"$'\n'
    rm -rf "$ij" "$ij.before" "$ij.after"
    if [ -n "$missing" ]; then
        fail "данные ваулта могут исполниться или объявлены доверенными" "$missing"
    else
        pass "враждебные имена и содержимое ваулта не исполняются, eval в lib/ нет ($n_fx файлов фикстуры)"
    fi
fi

# ─── 28. --project скоупит все проверки, кроме двух заявленных ──────────────
# Замерено 2026-08-04: `lint-collect --project nf-content` возвращал 16 находок, из
# которых 12 — про семь ДРУГИХ проектов. Скоуп применялся только к проектному циклу,
# а файловые свипы шли по всему ваулту. Это не «строже», это отчёт, который не значит
# того, что написано в его заголовке, и он приучает читателя пролистывать.
# Ровно два исключения, и оба по устройству, а не по недосмотру:
#   ambiguous-link — ссылка ломается от появления дубликата ИМЕНИ где угодно, поэтому
#     скоупленный взгляд на неё даёт лишь нижнюю границу;
#   project-unregistered / registry-stale — расхождение реестра с ФС есть факт уровня
#     ваулта, у него нет владельца-проекта.
# Проверка гоняет lint-collect на фикстуре, а не грепает форму: скоуп — это поведение.
sc2=$(mktemp -d)
mkdir -p "$sc2/00-system" "$sc2/a/wiki" "$sc2/b/wiki"
printf -- '# index\n- [[a/_PROJECT]]\n- [[b/_PROJECT]]\n' > "$sc2/00-system/index.md"
for pr in a b; do
    printf -- '---\nupdated: 2026-08-04\n---\n## Current state\nок\n' > "$sc2/$pr/_PROJECT.md"
    printf -- '---\nstatus: draft\ndate: 2020-01-01\n---\n# n\n[[../_PROJECT|_PROJECT]]\n' > "$sc2/$pr/wiki/note-$pr.md"
done
missing=""
out=$(bash "$SCRIPT_DIR/lib/brain.sh" lint-collect "$sc2" --project a 2>/dev/null)
if [ -z "$out" ]; then
    missing+="скоупленный прогон не дал ни одной находки — фикстура или скоуп сломаны"$'\n'
else
    printf '%s\n' "$out" | grep -qF 'stale-draft:a/wiki/note-a' ||
        missing+="находка внутри скоупа потеряна"$'\n'
    printf '%s\n' "$out" | grep -qE ':b(/|$)' &&
        missing+="в скоупленный отчёт попали находки чужого проекта: $(printf '%s\n' "$out" | grep -E ':b(/|$)' | tr '\n' ' ')"$'\n'
fi
bash "$SCRIPT_DIR/lib/brain.sh" lint-collect "$sc2" --project nosuchproj >/dev/null 2>&1 &&
    missing+="несуществующий --project не уронил проверку (пустой охват читается как чистый проект)"$'\n'
rm -rf "$sc2"
grep -qF 'ambiguous-link' "$SCRIPT_DIR/commands/brain-lint.md" ||
    missing+="brain-lint не называет исключение, которое остаётся vault-wide"$'\n'
if [ -n "$missing" ]; then
    fail "--project скоупит не всё или роняет нужное" "$missing"
else
    pass "--project скоупит файловые свипы, вайд остаются два заявленных исключения"
fi

# ─── 27. У decision-заметки две формы, и все её источники об этом знают ─────
# Замерено 2026-08-04 по ваулту: 286 заметок, медиана 68 строк, НИ ОДНОЙ короче 20 —
# лёгкой формы не существовало, поэтому решение на одну фразу либо раздувалось до
# секций, либо их выдумывало. 29 заметок несут `Alternatives rejected` пустой или в
# одну строку — это и есть раздувание, видимое в файлах.
# Вторая половина проверки — про источники. Тело decision-заметки описано в ЧЕТЫРЁХ
# местах: brain-save, brain-ingest, SKILL.md и chat-skill. Правило, внесённое в одно,
# оставляет три требовать прежнего — ровно так шаг синхронизации проехал мимо
# chat-skill'а и попал в backlog. Поэтому список источников здесь не перечислен
# вручную, а ВЫВЕДЕН: файл, описывающий тяжёлую форму, обязан описывать и лёгкую.
# Так пятый источник поймается сам, без правки этой проверки.
missing=""
scanned=0
for f in "$SCRIPT_DIR/SKILL.md" "$SCRIPT_DIR"/commands/*.md \
         "$SCRIPT_DIR"/chat-skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    grep -qF 'Alternatives rejected' "$f" || continue
    scanned=$((scanned + 1))
    grep -qF 'alternatives worth recording' "$f" ||
        missing+="$(basename "$(dirname "$f")")/$(basename "$f"): описывает тяжёлую форму, не описывает выбор между формами"$'\n'
done
if [ "$scanned" -eq 0 ]; then
    fail "проверка 27 не нашла ни одного описания decision-заметки — вход пуст, а не чист"
else
    # Там, где есть НАСТОЯЩИЙ шаблон, короткая форма обязана быть настоящей короткой:
    # без тяжёлых секций, но с той же frontmatter и обязательным backlink'ом — иначе
    # это не вторая форма, а вторая схема, и property-запросы разъедутся.
    for f in "$SCRIPT_DIR/commands/brain-save.md" "$SCRIPT_DIR/commands/brain-ingest.md"; do
        [ -f "$f" ] || { missing+="$(basename "$f") отсутствует"$'\n'; continue; }
        short=$(awk '/\*\*Short form:\*\*/ { s = 1; next }
                     s && /\*\*Full form\*\*/ { exit }
                     s { print }' "$f")
        if [ -z "$short" ]; then
            missing+="$(basename "$f"): короткой формы нет"$'\n'; continue
        fi
        printf '%s\n' "$short" | grep -qF '[[../_PROJECT|_PROJECT]]' ||
            missing+="$(basename "$f"): в короткой форме нет обязательного backlink'а"$'\n'
        printf '%s\n' "$short" | grep -qF 'status: accepted' ||
            missing+="$(basename "$f"): короткая форма несёт другую frontmatter"$'\n'
        printf '%s\n' "$short" | grep -qF '## Alternatives rejected' &&
            missing+="$(basename "$f"): короткая форма несёт тяжёлую секцию — это не вторая форма"$'\n'
    done
    if [ -n "$missing" ]; then
        fail "формы decision-заметки разошлись между источниками" "$missing"
    else
        pass "decision-заметка имеет две формы, все $scanned источника согласованы"
    fi
fi

# ─── 26. Переносчик смотрит туда же, куда смотрит счётчик ───────────────────
# `archive` двигал только Done, а порог, который срабатывает, — это `In progress`.
# Тот же перекос уже чинили дважды: у счётчика Done (грепал весь файл) и у бюджета
# `_PROJECT.md` (складывал прозу со списками ссылок). Правило одно — мерить и двигать
# ту часть, которая мешает.
# Первая версия sweep-closed собиралась двигать закрытые ЦЕЛИКОМ секции. Замер по семи
# проектам 2026-08-04: таких секций ноль, во всех. Вес — в секциях, смешивающих оба
# состояния (в goprofi одна на 1073 строки: 42 закрытых пункта и 40 открытых). Отсюда
# единица переноса — пункт, а не секция; проверка ниже фиксирует именно это поведение.
sc_fx=$(mktemp -d)
{
  echo "# t"; echo; echo "## In progress"; echo
  echo "- [ ] открытый"
  echo "  - [x] подпункт закрыт, но объясняет родителя"
  echo "- [x] закрытый верхнего уровня"
  echo "      тело"
  echo; echo "## Done"; echo; echo "- [x] 2026-07-01 старое"
} > "$sc_fx/tb.md"
cp "$sc_fx/tb.md" "$sc_fx/orig.md"
missing=""
BL="$SCRIPT_DIR/lib/brain.sh"
# dry-run обязан не писать
bash "$BL" sweep-closed "$sc_fx/tb.md" >/dev/null 2>&1
cmp -s "$sc_fx/tb.md" "$sc_fx/orig.md" || missing+="dry-run изменил файл"$'\n'
bash "$BL" sweep-closed "$sc_fx/tb.md" --apply >/dev/null 2>&1 ||
    missing+="sweep-closed отказал на корректной фикстуре"$'\n'
prog=$(awk '/^## /{ p = ($0 ~ /In progress/) } p' "$sc_fx/tb.md")
printf '%s\n' "$prog" | grep -qF 'подпункт закрыт' ||
    missing+="закрытый ПОДПУНКТ уехал от своего открытого родителя"$'\n'
printf '%s\n' "$prog" | grep -qF '[x] закрытый верхнего уровня' &&
    missing+="закрытый пункт верхнего уровня остался в In progress"$'\n'
sort "$sc_fx/orig.md" > "$sc_fx/a"; sort "$sc_fx/tb.md" > "$sc_fx/b"
cmp -s "$sc_fx/a" "$sc_fx/b" || missing+="результат не является перестановкой входа"$'\n'
# Заголовок не переносится — переносятся пункты. Значит заголовок, чей ТЕКСТ есть
# заявление о закрытии, может остаться стоять над открытыми пунктами: данные целы
# (перенос — перестановка), но файл начинает утверждать неверное, а таскборд читают
# по заголовкам. Замерено 2026-08-04 в goprofi-voronka: `### ✅ ЗАКРЫТО 03.08 …` на
# 1073 строки нёс 42 закрытых пункта и 40 открытых.
cat > "$sc_fx/lying.md" <<'LY'
# t

## In progress

### ✅ ЗАКРЫТО 2026-08-01 — всё сделано
- [x] закрытый
- [ ] на самом деле открытый

## Done

- [x] 2026-07-01 старое
LY
# Вывод забирается в переменную, а НЕ подаётся в `grep -q` конвейером. Под
# `set -o pipefail` (строка 13) `grep -q` выходит по первому совпадению, продюсер
# получает SIGPIPE, и статусом конвейера становится 141 — то есть УСПЕШНОЕ совпадение
# читается как провал. Замерено здесь же 2026-08-04: проверка краснела при полностью
# рабочем предупреждении, а негативный тест на ней дал ложное «краснеет», потому что
# она была красной и до мутации.
ly_out=$(bash "$BL" sweep-closed "$sc_fx/lying.md" 2>&1)
printf '%s\n' "$ly_out" | grep -qF 'this heading claims closure' ||
    missing+="перенос не предупреждает про заголовок, который станет неверным"$'\n'
# И обратное: честный заголовок предупреждения не вызывает.
sed 's/✅ ЗАКРЫТО 2026-08-01 — всё сделано/Работа в процессе/' "$sc_fx/lying.md" > "$sc_fx/honest.md"
ho_out=$(bash "$BL" sweep-closed "$sc_fx/honest.md" 2>&1)
printf '%s\n' "$ho_out" | grep -qF 'this heading claims closure' &&
    missing+="предупреждение срабатывает на честном заголовке — ложная тревога"$'\n'
# Страховка проверяется ЗАПУСКОМ сломанной копии, а не грепом её наличия.
sed 's|{ print > (w "/" (state == "moved" ? "moved" : "keep")) }|{ if ($0 !~ /тело/) print > (w "/" (state == "moved" ? "moved" : "keep")) }|' "$BL" > "$sc_fx/broken.sh"
if cmp -s "$sc_fx/broken.sh" "$BL" || [ ! -s "$sc_fx/broken.sh" ] || ! bash -n "$sc_fx/broken.sh" 2>/dev/null; then
    missing+="МЕТА: поломка не применилась — тест проверял бы свою опечатку"$'\n'
else
    cp "$sc_fx/orig.md" "$sc_fx/tb2.md"
    bash "$sc_fx/broken.sh" sweep-closed "$sc_fx/tb2.md" --apply >/dev/null 2>&1 &&
        missing+="потеря строки не остановила запись"$'\n'
    cmp -s "$sc_fx/tb2.md" "$sc_fx/orig.md" ||
        missing+="страховка отказала, но файл всё равно изменён"$'\n'
fi
rm -rf "$sc_fx"
grep -qF 'sweep-closed' "$SCRIPT_DIR/commands/brain-lint.md" ||
    missing+="/brain-lint не называет sweep-closed для находки taskboard-inprogress"$'\n'
if [ -n "$missing" ]; then
    fail "sweep-closed двигает не то или двигает без страховки" "$missing"
else
    pass "sweep-closed двигает пункты (не секции), бережёт подпункты, отказ не портит файл"
fi

# ─── 24. Переменная в блоке промпта обязана быть где-то введена ─────────────
# Найдено 2026-08-04 свипом по всем промптам: /brain-save Step 0c грепал
# "$PROJECT_CLAUDE_MD" — имя, которое во всём пакете встречается ровно один раз, в
# самой этой строке. Ни присваивания, ни упоминания в прозе, откуда сессия могла бы
# понять, что подставлять. Grep получал пустое имя файла, ошибка уходила в
# `2>/dev/null`, вывод был пуст — и половина шага, единственная работающая для нового
# проекта, не выполнялась ни разу с момента написания.
# Проверка 16 этого не видела: она требует, чтобы шаг СУЩЕСТВОВАЛ и стоял выше
# шаблонов. Наличие шага и его исполнимость — разные факты, и зелёное по первому
# читается как второе. Ровно та же форма, что `mapfile` и `except ImportError`.
# Критерий введения намеренно широкий: либо присваивание в блоке, либо упоминание
# в прозе того же файла. Блоки промптов исполняет не шелл, а сессия, и `$PROJECT`,
# введённый фразой «that is `$PROJECT`», — законный способ. Не введённое нигде —
# не способ, а опечатка.
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
        printf '%s\n' "$assigned" | grep -qx "$v" && continue
        printf '%s\n' "$prose"    | grep -qF "\$$v" && continue
        h+="  \$$v — ни присваивания в блоке, ни упоминания в прозе файла"$'\n'
    done
    [ -n "$h" ] && missing+="$(basename "$f"):"$'\n'"$h"
done
if [ "$scanned" -eq 0 ]; then
    fail "проверка 24 не открыла ни одного файла — вход пуст, а не чист"
elif [ -n "$missing" ]; then
    fail "блок промпта ссылается на переменную, которую негде взять" "$missing"
else
    pass "все переменные блоков промптов введены присваиванием или прозой ($scanned файлов)"
fi

echo -e "${BLUE}[2/3] Скрипты${NC}"
for s in "$SCRIPT_DIR"/*.sh; do
    if bash -n "$s" 2>/dev/null; then
        pass "$(basename "$s"): синтаксис ок"
    else
        fail "$(basename "$s"): синтаксическая ошибка" "$(bash -n "$s" 2>&1)"
    fi
done

# ─── Установка в чистый $HOME ────────────────────────────────────────────────
echo ""
echo -e "${BLUE}[3/3] Установка в чистый \$HOME${NC}"
if [ "$FAST" = "1" ]; then
    echo -e "  ${YELLOW}—${NC} пропущено (--fast)"
else
    TMPHOME=$(mktemp -d)
    trap 'rm -rf "$TMPHOME"' EXIT

    if HOME="$TMPHOME" bash "$SCRIPT_DIR/install.sh" </dev/null >"$TMPHOME/install.log" 2>&1; then
        pass "install.sh отработал неинтерактивно (exit 0)"
    else
        fail "install.sh упал в чистом \$HOME" "$(tail -5 "$TMPHOME/install.log")"
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
        fail "install.sh не создал ожидаемые файлы" "$missing"
    else
        pass "все 13 ожидаемых файлов на месте"
    fi

    # update.sh поверх установки, дважды — должен быть идемпотентен
    if HOME="$TMPHOME" bash "$SCRIPT_DIR/update.sh" >/dev/null 2>&1 &&
       HOME="$TMPHOME" bash "$SCRIPT_DIR/update.sh" >/dev/null 2>&1; then
        pass "update.sh идемпотентен (два прогона подряд, exit 0)"
    else
        fail "update.sh падает поверх свежей установки"
    fi

    # Установленное должно совпадать с репозиторием байт в байт
    drift=""
    for cmd in brain-setup brain-init brain-save brain-ingest brain-lint; do
        cmp -s "$SCRIPT_DIR/commands/$cmd.md" "$TMPHOME/.claude/commands/$cmd.md" ||
            drift+="$cmd.md расходится с репозиторием"$'\n'
    done
    cmp -s "$SCRIPT_DIR/SKILL.md" "$TMPHOME/.claude/skills/second-brain/SKILL.md" ||
        drift+="SKILL.md расходится с репозиторием"$'\n'
    cmp -s "$SCRIPT_DIR/lib/brain.sh" "$TMPHOME/.claude/skills/second-brain/lib/brain.sh" ||
        drift+="lib/brain.sh расходится с репозиторием"$'\n'
    [ -x "$TMPHOME/.claude/skills/second-brain/lib/brain.sh" ] ||
        drift+="lib/brain.sh установлен без флага +x"$'\n'
    if [ -n "$drift" ]; then
        fail "установленные файлы не совпадают с исходниками" "$drift"
    else
        pass "установленные файлы идентичны исходникам"
    fi
fi

# ─── Итог ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}━━━ preflight пройден: $PASSED проверок ━━━${NC}"
    echo ""
    echo "  Механическая часть чиста. Это НЕ означает, что можно ставить тег:"
    echo "  правило обкатки требует прогона /brain-lint --all на живом vault и"
    echo "  минимум одной сессии использования до тега (см. CLAUDE.md → Release gate)."
    echo ""
    exit 0
else
    echo -e "${RED}━━━ preflight провален: $FAILED из $((PASSED + FAILED)) ━━━${NC}"
    echo ""
    exit 1
fi
