#!/usr/bin/env bash
# preflight.sh — release gate. Запускать ПЕРЕД тем как ставить тег.
#
# Проверяет репозиторий на нарушения собственных правил из CLAUDE.md Block 2.
# Каждое правило здесь появилось после живого инцидента — список не умозрительный.
# Три из четырёх багов релизов v1.4.3/v1.5.0 ловились однострочным grep, которого
# не существовало; этот скрипт и есть тот grep.
#
# Использование:
#   bash preflight.sh          # все проверки
#   bash preflight.sh --fast   # без установки в temp $HOME (быстрая проверка при правках)

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

# Цели проверки. Намеренно НЕ включает preflight.sh: скрипт содержит запрещённые
# паттерны как строки поиска и заматчил бы сам себя — ровно тот же класс ошибки,
# что `pgrep -f`, из-за которого guard находил собственный процесс (v1.3 → 2026-07-11).
TARGETS=("$SCRIPT_DIR/SKILL.md" "$SCRIPT_DIR"/commands/brain-*.md)

pass() { PASSED=$((PASSED + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() {
    FAILED=$((FAILED + 1))
    echo -e "  ${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /'
    return 0
}

# code_blocks <file> — печатает только содержимое ``` fenced-блоков.
# Проза не сканируется намеренно: файлы описывают запрещённые вызовы словами
# ("Do not use obsidian property:set here"), и грубый grep по всему файлу
# сделал бы документирование запрета его же нарушением.
code_blocks() {
    awk '/^[[:space:]]*```/ { inblock = !inblock; next } inblock { print }' "$1"
}

# strip_inline_code <file...> — печатает файлы с вырезанными `inline-code` спанами,
# в формате grep -n (файл:строка:текст). Нужно там, где паттерн ищется по всему файлу,
# включая шаблоны: проза документирует запреты, цитируя их в backticks
# ("never `status: superseded-by: x`"), и без этого документация запрета сама
# считалась бы его нарушением. Fenced-блоки backticks внутри не содержат, поэтому
# реальные шаблоны остаются видимыми.
strip_inline_code() {
    for f in "$@"; do
        [ -f "$f" ] || continue
        awk -v F="$f" '
            # Fenced-блоки оставляем как есть: реальные шаблоны живут именно в них,
            # а состояние inline-спана внутри блока не отслеживаем.
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
            # incode намеренно НЕ сбрасывается на границе строки: markdown допускает
            # перенос inline-спана, и именно такие спаны давали ложные срабатывания.
        ' "$f"
    done
}

echo -e "${BLUE}━━━ preflight: проверка перед релизом ━━━${NC}"
echo ""
echo -e "${BLUE}[1/3] Собственные запреты (CLAUDE.md Block 2)${NC}"

# ─── 1. Адресация файлов в obsidian CLI ──────────────────────────────────────
# Инцидент 2026-07-22: /brain-save проставил updated: в _PROJECT.md чужого проекта.
# `file=` резолвится по имени как голый wikilink, берёт первое совпадение, exit 0.
hits=""
for f in "${TARGETS[@]}"; do
    h=$(code_blocks "$f" | grep -n "obsidian .*[^a-z_]file=" || true)
    [ -n "$h" ] && hits+="$(basename "$f"): $h"$'\n'
done
if [ -n "$hits" ]; then
    fail "obsidian CLI адресуется через file= (должно быть path=)" "$hits"
else
    pass "obsidian CLI: адресация только через path="
fi

# ─── 2. property:set ─────────────────────────────────────────────────────────
# Замерено 2026-07-22: пересобирает весь frontmatter — снимает кавычки, разворачивает
# инлайн-списки, 007 → 7. Потеря данных без предупреждения, exit 0.
hits=""
for f in "${TARGETS[@]}"; do
    h=$(code_blocks "$f" | grep -n "obsidian property:set" || true)
    [ -n "$h" ] && hits+="$(basename "$f"): $h"$'\n'
done
if [ -n "$hits" ]; then
    fail "вызов obsidian property:set в исполняемом блоке (запрещён — пересобирает frontmatter)" "$hits"
else
    pass "property:set не вызывается ни в одном code-блоке"
fi

# ─── 3. pgrep -f ─────────────────────────────────────────────────────────────
# Инцидент 2026-07-11: guard самозамыкался на собственном shell-процессе.
hits=""
for f in "${TARGETS[@]}"; do
    h=$(code_blocks "$f" | grep -n "pgrep -f" || true)
    [ -n "$h" ] && hits+="$(basename "$f"): $h"$'\n'
done
if [ -n "$hits" ]; then
    fail "pgrep -f для проверки запущенного GUI (самозамыкается на своём же процессе)" "$hits"
else
    pass "pgrep -f не используется"
fi

# ─── 4. Целостность guard'а ──────────────────────────────────────────────────
# Каждое требование — отдельный инцидент: cold-start GUI (timeout), самоматч (SingletonLock),
# -e вместо -L (target симлинка намеренно не существует), запись в чужой vault (сверка имени).
for f in "${TARGETS[@]}"; do
    name=$(basename "$f")
    calls=$(code_blocks "$f" | grep -cE "^[[:space:]]*(if |\[|.*\$\()?[[:space:]]*obsidian " || true)
    [ "$calls" -eq 0 ] && continue

    if ! grep -q "_obsidian_available()" "$f"; then
        fail "$name вызывает obsidian, но не определяет _obsidian_available()"
        continue
    fi
    guard=$(sed -n '/_obsidian_available()/,/^}/p' "$f")
    problems=""
    echo "$guard" | grep -q "timeout" || problems+="нет timeout — может подвесить сессию"$'\n'
    echo "$guard" | grep -q "vault info=name" || problems+="не сверяет имя активного vault"$'\n'
    echo "$guard" | grep -q 'basename "\$VAULT"' || problems+="имя vault не выводится из \$VAULT"$'\n'
    echo "$guard" | grep -q '\-L ' || problems+="SingletonLock проверяется не через -L"$'\n'
    if [ -n "$problems" ]; then
        fail "$name: guard неполон" "$problems"
    else
        pass "$name: guard полон (timeout + сверка имени vault + -L)"
    fi
done

# ─── 5. Legacy-форма supersession ────────────────────────────────────────────
# `status: superseded-by: x` — двойное двоеточие, невалидный YAML: Obsidian не читает
# frontmatter такой заметки целиком и она выпадает из всех property-запросов.
mapfile -t ALL_MD < <(find "$SCRIPT_DIR" -name '*.md' -not -path '*/.git/*')
hits=$(strip_inline_code "${ALL_MD[@]}" | grep "status:[[:space:]]*superseded-by:" || true)
if [ -n "$hits" ]; then
    fail "legacy-форма supersession в одну строку (невалидный YAML)" "$hits"
else
    pass "supersession везде двумя полями (status + superseded-by)"
fi

# ─── 6. Голые wikilinks на неуникальные имена ────────────────────────────────
# Класс багов, повторившийся трижды (2026-07-14/15): _PROJECT.md, architecture-map.md,
# и задублированные между проектами wiki-заметки. Obsidian резолвит голую ссылку в
# первое совпадение по кратчайшему пути — молча в чужой проект.
NONUNIQUE="_PROJECT|architecture-map|taskboard|index|connections"
hits=$(strip_inline_code "${ALL_MD[@]}" | grep -E "\[\[($NONUNIQUE)(\|[^]]*)?\]\]" || true)
if [ -n "$hits" ]; then
    fail "голый [[wikilink]] на имя, неуникальное в vault (нужен явный путь)" "$hits"
else
    pass "неуникальные имена всегда адресуются явным путём"
fi

# ─── 7. Валидность YAML во frontmatter ───────────────────────────────────────
if command -v python3 >/dev/null 2>&1; then
    bad=$(python3 - "$SCRIPT_DIR" <<'PY' 2>/dev/null || true
import sys, pathlib
try:
    import yaml
except ImportError:
    sys.exit(0)
root = pathlib.Path(sys.argv[1])
for p in root.rglob("*.md"):
    if ".git" in p.parts:
        continue
    text = p.read_text(encoding="utf-8", errors="replace")
    if not text.startswith("---"):
        continue
    end = text.find("\n---", 3)
    if end == -1:
        continue
    try:
        yaml.safe_load(text[3:end])
    except Exception as e:
        print(f"{p.relative_to(root)}: {str(e).splitlines()[0]}")
PY
)
    if [ -n "$bad" ]; then
        fail "невалидный YAML во frontmatter" "$bad"
    else
        pass "frontmatter во всех .md парсится"
    fi
fi

# ─── 8. Распространяемый zip не отстал от исходников ─────────────────────────
# Найдено 2026-07-22: brain-onboard.zip не пересобирался с 27.06 и вёз внешним
# пользователям v1.3 — вместе с формой `status: superseded-by: x`, которую v1.5.0
# объявил невалидным YAML. Артефакт собирается вручную, поэтому расходится молча.
ZIP="$SCRIPT_DIR/chat-skills/brain-onboarding/brain-onboard.zip"
ZIP_SRC="$SCRIPT_DIR/chat-skills/brain-onboarding/SKILL.md"
if [ -f "$ZIP" ] && [ -f "$ZIP_SRC" ] && command -v unzip >/dev/null 2>&1; then
    if diff -q <(unzip -p "$ZIP" 'brain-onboarding/SKILL.md' 2>/dev/null) "$ZIP_SRC" >/dev/null 2>&1; then
        pass "brain-onboard.zip совпадает с исходным SKILL.md"
    else
        fail "brain-onboard.zip разошёлся с chat-skills/brain-onboarding/SKILL.md — пересобрать"
    fi
fi

# ─── Синтаксис шелл-скриптов ─────────────────────────────────────────────────
echo ""
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
        pass "все 11 ожидаемых файлов на месте"
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
