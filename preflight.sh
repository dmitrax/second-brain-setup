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

# ─── 4. Guard вызывается из lib/, а не переписывается инлайн ─────────────────
# До v1.7.0 guard существовал как fenced-блок в brain-lint.md, а SKILL.md и brain-init.md
# ссылались на него как на библиотечную функцию, которой в их контексте нет — то есть
# /brain-init предписывал мутирующий `obsidian move` под защитой, которой у него не было.
# Теперь это одна копия кода. Инлайн-определение снова разойдётся с оригиналом, поэтому
# запрещено; форма guard'а здесь больше не грепается — она проверяется ЗАПУСКОМ ниже.
for f in "${TARGETS[@]}"; do
    name=$(basename "$f")
    if grep -qE "_obsidian_available\(\)[[:space:]]*\{" "$f"; then
        fail "$name: определяет _obsidian_available() инлайн" \
             "с v1.7.0 guard живёт в lib/brain.sh; инлайн-копия разойдётся с оригиналом"
        continue
    fi
    # Реальные вызовы считаем только в code-блоках: отличить прозаическое ПРЕДПИСАНИЕ
    # вызова от прозаического ЗАПРЕТА ("Do not use obsidian property:set") грепом нельзя.
    calls=$(code_blocks "$f" | grep -cE "^[[:space:]]*(if |\[|.*\$\()?[[:space:]]*obsidian " || true)
    mentions=$(grep -c "obsidian-available" "$f" || true)
    [ "$calls" -eq 0 ] && [ "$mentions" -eq 0 ] && continue

    if [ "$mentions" -eq 0 ]; then
        fail "$name вызывает obsidian в code-блоке, не вызвав guard из lib/brain.sh"
    else
        pass "$name: guard вызывается из lib/brain.sh"
    fi
done

# ─── 4b. Guard РАБОТАЕТ — проверка запуском, а не грепом ─────────────────────
# Ради этого guard и выносился в код: раньше проверить можно было только форму текста.
# Три состояния, все обязаны отработать без запуска GUI и без зависания.
LIBSH="$SCRIPT_DIR/lib/brain.sh"
if [ ! -f "$LIBSH" ]; then
    fail "lib/brain.sh отсутствует — промпты ссылаются на несуществующий файл"
else
    problems=""
    bash -n "$LIBSH" 2>/dev/null || problems+="синтаксическая ошибка в lib/brain.sh"$'\n'
    # Любой вызов CLI обязан быть под timeout: запуском это не поймать (стенд отвечает
    # мгновенно), а зависший `obsidian` вешает сессию целиком — та же причина, по
    # которой guard вообще существует.
    # Считаем только настоящие вызовы бинаря, не слово «obsidian» в тексте: строки с
    # `obsidian vault …` вне комментария обязаны нести timeout. Первая редакция этой
    # проверки грепала любое вхождение слова и краснела на собственном usage-тексте.
    if grep -nE '(^|[^-a-z])obsidian +vault' "$LIBSH" |
       grep -v '^[0-9]*:[[:space:]]*#' | grep -qv 'timeout [0-9]'; then
        problems+="вызов obsidian без timeout в lib/brain.sh"$'\n'
    fi
    # (1) Пустой аргумент — обязан отказать, а не сравнивать пустое с пустым.
    bash "$LIBSH" obsidian-available "" >/dev/null 2>&1 &&
        problems+="guard принял пустой vault"$'\n'
    # (2) Заведомо чужой vault: даже с открытым GUI имя не совпадёт. Именно этот случай
    #     v1.5.0 и добавлял — exit code подтверждает лишь «открыт какой-то vault».
    bash "$LIBSH" obsidian-available "/nonexistent/other-vault" >/dev/null 2>&1 &&
        problems+="guard подтвердил чужой vault"$'\n'
    # (3) HOME без SingletonLock — GUI считается закрытым, CLI трогать нельзя.
    FAKEHOME=$(mktemp -d)
    HOME="$FAKEHOME" bash "$LIBSH" obsidian-available "$HOME/Workspace/second-brain-vault" \
        >/dev/null 2>&1 && problems+="guard сработал без SingletonLock"$'\n'
    rm -rf "$FAKEHOME"
    # (4) Неизвестная подкоманда обязана падать, а не молча ничего не делать.
    bash "$LIBSH" definitely-not-a-command >/dev/null 2>&1 &&
        problems+="lib/brain.sh принял неизвестную подкоманду"$'\n'
    # (5) ПОЗИТИВНЫЙ случай, полностью герметичный: поддельный HOME с SingletonLock,
    #     указывающим на НЕсуществующий target (именно так и делает Electron), плюс
    #     поддельный `obsidian` в PATH. Guard обязан сказать «доступен».
    #     Без этого случая проверка состоит из одних отказов и не отличит рабочий guard
    #     от сломанного в другую сторону — подмена `-L` на `-e` прошла бы незамеченной,
    #     хотя `-e` резолвит target и потому всегда ложен. Проверено негативным тестом.
    POSHOME=$(mktemp -d)
    mkdir -p "$POSHOME/.config/obsidian" "$POSHOME/bin" "$POSHOME/vaultdir/my-vault"
    ln -s "definitely-missing-$$" "$POSHOME/.config/obsidian/SingletonLock"
    printf '#!/bin/sh\necho my-vault\n' > "$POSHOME/bin/obsidian"
    chmod +x "$POSHOME/bin/obsidian"
    if ! HOME="$POSHOME" PATH="$POSHOME/bin:$PATH" \
         bash "$LIBSH" obsidian-available "$POSHOME/vaultdir/my-vault" >/dev/null 2>&1; then
        problems+="guard не подтвердил доступность в заведомо рабочем состоянии (проверь -L против -e)"$'\n'
    fi
    rm -rf "$POSHOME"
    if [ -n "$problems" ]; then
        fail "lib/brain.sh: guard ведёт себя неверно (проверено запуском)" "$problems"
    else
        pass "lib/brain.sh: guard запущен — 3 отказа + рабочее состояние + timeout"
    fi
fi

# ─── 4c. vault-sync и stamp-updated отрабатывают на настоящих файлах ─────────
if [ -f "$LIBSH" ]; then
    problems=""
    TMPLIB=$(mktemp -d)
    # stamp-updated обязан тронуть одну строку и не переформатировать соседние —
    # ровно то, чем property:set портил данные (кавычки, инлайн-списки, 007 -> 7).
    printf -- '---\ntags: [session, x]\nversion: "1.4.3"\nupdated: 2026-01-01\ncount: 007\n---\n\nbody\n' \
        > "$TMPLIB/a.md"
    bash "$LIBSH" stamp-updated "$TMPLIB/a.md" 2026-08-03 >/dev/null 2>&1 ||
        problems+="stamp-updated упал на нормальном файле"$'\n'
    grep -q '^updated: 2026-08-03$' "$TMPLIB/a.md" || problems+="stamp-updated не проставил дату"$'\n'
    grep -q '^tags: \[session, x\]$' "$TMPLIB/a.md" || problems+="stamp-updated развернул инлайн-список"$'\n'
    grep -q '^version: "1.4.3"$' "$TMPLIB/a.md" || problems+="stamp-updated снял кавычки"$'\n'
    grep -q '^count: 007$' "$TMPLIB/a.md" || problems+="stamp-updated переписал 007"$'\n'
    # Файла без frontmatter трогать нельзя.
    printf -- '# no frontmatter\n' > "$TMPLIB/b.md"
    bash "$LIBSH" stamp-updated "$TMPLIB/b.md" 2026-08-03 >/dev/null 2>&1 &&
        problems+="stamp-updated принял файл без frontmatter"$'\n'
    # vault-sync: локальный vault без remote — штатный сетап, обязан пропустить с 0.
    mkdir -p "$TMPLIB/v" && git -C "$TMPLIB/v" init -q 2>/dev/null
    bash "$LIBSH" vault-sync "$TMPLIB/v" >/dev/null 2>&1 ||
        problems+="vault-sync не пропустил vault без remote"$'\n'
    # Не-репозиторий — тоже пропуск, а не отказ.
    mkdir -p "$TMPLIB/plain"
    bash "$LIBSH" vault-sync "$TMPLIB/plain" >/dev/null 2>&1 ||
        problems+="vault-sync не пропустил не-git vault"$'\n'
    # Несуществующий путь — отказ, иначе «синхронизировано» означало бы «ничего не делал».
    bash "$LIBSH" vault-sync "$TMPLIB/nope" >/dev/null 2>&1 &&
        problems+="vault-sync принял несуществующий путь"$'\n'
    rm -rf "$TMPLIB"
    if [ -n "$problems" ]; then
        fail "lib/brain.sh: vault-sync/stamp-updated ведут себя неверно" "$problems"
    else
        pass "lib/brain.sh: stamp-updated щадит соседние поля, vault-sync различает исходы"
    fi
fi

# ─── 5. Legacy-форма supersession ────────────────────────────────────────────
# `status: superseded-by: x` — двойное двоеточие, невалидный YAML: Obsidian не читает
# frontmatter такой заметки целиком и она выпадает из всех property-запросов.
# Читаем список без `mapfile`: он появился в bash 4.0, а на macOS /bin/bash — 3.2.
# До 2026-08-02 здесь стоял mapfile, и на Mac проверки 5-6 не выполнялись ВООБЩЕ:
# массив оставался unbound, grep получал пустой вход, обе печатали ✓. Ворота релиза
# сами были ложно-зелёными на одной из двух рабочих машин.
ALL_MD=()
while IFS= read -r _f; do ALL_MD+=("$_f"); done < <(find "$SCRIPT_DIR" -name '*.md' -not -path '*/.git/*')
if [ "${#ALL_MD[@]}" -eq 0 ]; then
    fail "не найдено ни одного .md — проверки 5-6 не отработали (пустой вход, не чистый репозиторий)"
fi
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
# Проверка обязана падать, когда выполнить её нечем или не на чем. До 2026-08-03
# отсутствие python3 пропускало её молча и целиком, а отсутствующий PyYAML давал
# `sys.exit(0)` — на macOS, где модуль не установлен, она печатала ✓, не разобрав
# ни одного блока. Ровно тот же класс, что `mapfile` в проверках 5-6, и найден он
# был в ту же неделю, одной функцией ниже. Зелёное обязано означать «выполнено и
# чисто», никогда «не выполнено». Ср. проверку 14 и правило пустого входа.
# Кандидаты интерпретатора по порядку: явный $PYTHON, репозиторный .venv,
# системный python3. Берётся первый, у которого PyYAML реально импортируется —
# «python3 нашёлся» и «проверку есть чем выполнить» это разные факты, и раньше
# скрипт путал их в пользу зелёного. .venv лежит в .gitignore и заводится один
# раз: python3 -m venv .venv && .venv/bin/pip install pyyaml
PYBIN=""
for cand in "${PYTHON:-}" "$SCRIPT_DIR/.venv/bin/python" python3; do
    [ -n "$cand" ] || continue
    command -v "$cand" >/dev/null 2>&1 || continue
    "$cand" -c 'import yaml' >/dev/null 2>&1 || continue
    PYBIN="$cand"
    break
done
if [ -z "$PYBIN" ]; then
    fail "нет интерпретатора с PyYAML — проверка YAML не выполнена" \
         "завести: python3 -m venv .venv && .venv/bin/pip install pyyaml"
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
        fail "невалидный YAML во frontmatter" "$bad"
    elif [ -z "$parsed" ] || [ "$parsed" -eq 0 ]; then
        fail "проверка YAML не нашла ни одного frontmatter-блока — вход пуст, а не чист"
    else
        pass "frontmatter во всех .md парсится ($parsed блоков)"
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

# ─── 9. Conventional Commits с даты принятия правила ─────────────────────────
# Adopted 2026-07-23. История до этой даты не переписывается задним числом —
# тот же принцип, что и у semver выше. release: — свой тип этого репо для
# коммитов-тегов (см. `release: adopt semver, tag v1.4.0`).
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
    fail "коммиты с $CC_CUTOFF не соответствуют Conventional Commits" "$hits"
else
    pass "коммиты с $CC_CUTOFF соответствуют Conventional Commits"
fi

# ─── 10. Шаблон CLAUDE.md не заводит секцию состояния ────────────────────────
# Найдено 2026-07-25 на живом dimarch: `## Current state` в проектном CLAUDE.md
# разросся до 490 строк датированной хроники и вёз 6 фактов, которые vault уже
# исправил. Файл грузится целиком каждую сессию, до того как известна тема, —
# состоянию там не место. Проверяем именно fenced-блок Step 4 (шаблон CLAUDE.md):
# у шаблона _PROJECT.md в этом же файле секция `## Current state` легитимна.
CLAUDE_TPL=$(awk '
    /^## Step 4: Create CLAUDE.md/ { seen = 1; next }
    !seen { next }
    /^[[:space:]]*```/ { fence++; if (fence == 2) exit; next }
    fence == 1 { print }
' "$SCRIPT_DIR/commands/brain-init.md")
if [ -z "$CLAUDE_TPL" ]; then
    fail "не найден шаблон CLAUDE.md в brain-init.md Step 4 — проверка не сработала"
elif echo "$CLAUDE_TPL" | grep -qE '^#{2,3} +(Current state|Статус)'; then
    fail "шаблон CLAUDE.md в brain-init.md завёл секцию состояния — она принадлежит _PROJECT.md"
else
    pass "шаблон CLAUDE.md не заводит секцию состояния"
fi

# ─── 11. Критерий разделения трёх памятей на месте ───────────────────────────
# Правило существует только пока его текст есть в промптах: SKILL.md несёт сам
# критерий, brain-save применяет его в Step 0a при правке CLAUDE.md Block 2.
missing=""
grep -qi 'What belongs where' "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: нет раздела «What belongs where»"$'\n'
grep -qi 'can this be false tomorrow' "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: нет expiry-теста"$'\n'
grep -qi 'expiry test' "$SCRIPT_DIR/commands/brain-save.md" || missing+="brain-save.md: Step 0a не ссылается на expiry-тест"$'\n'
if [ -n "$missing" ]; then
    fail "потерян критерий «что живёт в CLAUDE.md, а что в vault»" "$missing"
else
    pass "критерий разделения памятей на месте (SKILL.md + brain-save Step 0a)"
fi

# ─── 12. Синхронизация vault до записи ───────────────────────────────────────
# Общие реестры 00-system/*.md правит каждая сессия на каждой машине, поэтому
# запись поверх устаревшего checkout гарантирует конфликт на push. Шаг обязан
# стоять ДО первой записи (иначе он бесполезен) и не имеет права блокировать
# сохранение при недоступной сети — несохранённая сессия дороже отложенного sync.
# С v1.7.0 сам pull живёт в lib/brain.sh, поэтому требование проверяется по месту:
# механика — в библиотеке, порядок вызова — в промпте. Ослаблением это не является,
# обе половины обязательны, отсутствие любой роняет проверку.
BS="$SCRIPT_DIR/commands/brain-save.md"
missing=""
if [ -f "$LIBSH" ]; then
    grep -q 'pull --rebase --autostash' "$LIBSH" || missing+="lib/brain.sh: нет pull --rebase --autostash"$'\n'
    grep -qE 'timeout [0-9]+ git .*pull' "$LIBSH" || missing+="lib/brain.sh: pull не обёрнут в timeout — недоступный remote повесит сессию"$'\n'
    grep -q 'return 3' "$LIBSH" || missing+="lib/brain.sh: конфликт не отличён от прочих отказов (нет кода 3)"$'\n'
    grep -q 'return 2' "$LIBSH" || missing+="lib/brain.sh: недоступный remote не отличён от успеха (нет кода 2)"$'\n'
else
    missing+="lib/brain.sh отсутствует — синхронизировать нечем"$'\n'
fi
# Все четыре команды трогают vault, значит все четыре синхронизируют его. До v1.7.0
# проверка смотрела только brain-save, поэтому разрыв между правилом Block 2 («команда,
# которая пишет в vault») и реализацией (одна команда из четырёх) был машинно невидим —
# правило существовало, а три команды его не исполняли, и ничто этого не показывало.
# Пара «команда → её первая запись»: sync обязан стоять строго выше. Шаг после первой
# записи не слабее, он инертен.
for pair in \
    "brain-save.md:^## Step 0b" \
    "brain-init.md:^## Step 2" \
    "brain-ingest.md:^## Step 3" \
    "brain-lint.md:^## Step 5"; do
    cmd_name="${pair%%:*}"
    write_marker="${pair#*:}"
    cf="$SCRIPT_DIR/commands/$cmd_name"
    if [ ! -f "$cf" ]; then
        missing+="$cmd_name отсутствует — проверка синхронизации не отработала"$'\n'
        continue
    fi
    sync_ln=$(grep -n 'vault-sync' "$cf" | head -1 | cut -d: -f1)
    write_ln=$(grep -n "$write_marker" "$cf" | head -1 | cut -d: -f1)
    if [ -z "$sync_ln" ]; then
        missing+="$cmd_name: не вызывает vault-sync"$'\n'
    elif [ -z "$write_ln" ]; then
        missing+="$cmd_name: не найден маркер первой записи ($write_marker) — проверка порядка не сработала"$'\n'
    elif [ "$sync_ln" -ge "$write_ln" ]; then
        missing+="$cmd_name: sync стоит после первой записи (строка $sync_ln против $write_ln)"$'\n'
    fi
done
if [ -n "$missing" ]; then
    fail "потерян шаг синхронизации vault перед записью" "$missing"
else
    pass "все 4 команды синхронизируют vault до первой записи, pull под timeout"
fi

# ─── 12b. Синхронизация перед ЧТЕНИЕМ (протокол старта сессии) ───────────────
# Симметрична 12 и заведена по той же причине с обратным знаком: запись закрыли
# первой, потому что конфликт на push громкий, а чтение молчит. Сессия штатно
# открывает _PROJECT.md и taskboard.md в состоянии «на момент прошлого визита на эту
# машину», ничем себя не выдавая — файлы на месте и выглядят актуальными. Отсюда
# ложные выводы о том, что задача открыта, хотя вчера её закрыли на другой машине.
# Два места, оба обязательны: SKILL.md действует во всех проектах (включая 9 уже
# созданных, до которых шаблон не доедет), шаблон в brain-init гарантирует исполнение
# в новых.
missing=""
sk="$SCRIPT_DIR/SKILL.md"
sync_ln=$(grep -n 'vault-sync' "$sk" | head -1 | cut -d: -f1)
read_ln=$(grep -n 'Always load at session start' "$sk" | head -1 | cut -d: -f1)
if [ -z "$sync_ln" ]; then
    missing+="SKILL.md: протокол старта не синхронизирует vault перед чтением"$'\n'
elif [ -z "$read_ln" ]; then
    missing+="SKILL.md: не найден маркер загрузки на старте — проверка не сработала"$'\n'
fi
grep -q 'vault-sync' "$SCRIPT_DIR/commands/brain-init.md" ||
    missing+="brain-init.md: шаблон CLAUDE.md не несёт шага синхронизации на старте"$'\n'
# В шаблоне шаг обязан стоять выше строки, которая велит читать _PROJECT.md.
tpl_sync=$(grep -n 'At session start' -A6 "$SCRIPT_DIR/commands/brain-init.md" | grep 'vault-sync' | head -1 | cut -d: -f1)
[ -n "$tpl_sync" ] ||
    missing+="brain-init.md: vault-sync есть, но не внутри блока «At session start»"$'\n'
if [ -n "$missing" ]; then
    fail "чтение vault не синхронизировано — стухший checkout читается как актуальный" "$missing"
else
    pass "старт сессии синхронизирует vault до чтения (SKILL.md + шаблон brain-init)"
fi

# ─── 13. Поиск по vault всегда с -F или -E ───────────────────────────────────
# Замерено 2026-08-02 на живом vault: литерал `[[architecture-map]]` без -F дал 304
# файла вместо 17 (скобки читаются как символьный класс), а `docker|colima` без -E —
# 1 файл вместо 37 (в базовой регулярке `|` не оператор). Оба промаха молчат и
# возвращают обычный exit-код, поэтому сессия верит ответу: в одну сторону тонет в
# шуме, в другую решает, что в vault ничего нет, и идёт дальше. Правило намеренно
# строже необходимого — флаг обязателен даже там, где паттерн заведомо безобиден:
# «в паттерне есть метасимвол?» требует разбора, «флаг на месте?» не требует ничего.
# Документировать сломанную форму в этих файлах нельзя — писать словами или без -r.
missing=""
grep -qi 'Searching the vault' "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: нет раздела про поиск по vault"$'\n'
for flag in '`grep -rF`' '`grep -rE`'; do
    grep -qF "$flag" "$SCRIPT_DIR/SKILL.md" || missing+="SKILL.md: не предписан $flag"$'\n'
done
for f in "${TARGETS[@]}"; do
    h=$(grep -no 'grep -r[a-zA-Z]*' "$f" | grep -vE ':grep -r[a-zA-Z]*[EF]' || true)
    [ -n "$h" ] && missing+="$(basename "$f"): голый grep -r без -F/-E в строках $(echo "$h" | cut -d: -f1 | tr '\n' ' ')"$'\n'
done
if [ -n "$missing" ]; then
    fail "поиск по vault предписан без -F/-E (молча неверный результат)" "$missing"
else
    pass "поиск по vault всегда с -F или -E, правило на месте в SKILL.md"
fi

# ─── 14. Скрипты совместимы с bash 3.2 ───────────────────────────────────────
# macOS отдаёт /bin/bash 3.2 — это одна из двух рабочих машин, не экзотика.
# Инцидент 2026-08-02: сам этот файл использовал mapfile (bash 4.0), на Mac массив
# оставался unbound, проверки 5-6 получали пустой вход и печатали ✓, ни разу не
# выполнившись. Ворота релиза были слепы на половине парка десять дней.
# `bash -n` такое не ловит: синтаксис валиден, отсутствует лишь builtin в рантайме.
# Литералы собраны из кусков намеренно — иначе файл заматчил бы сам себя, ровно та
# причина, по которой TARGETS не включает preflight.sh (см. шапку).
B4="(map""file|read""array|declare -""A|local -""A|\\\$\\{[A-Za-z_][A-Za-z0-9_]*(\\^\\^|,,)\\})"
hits=""
for s in "$SCRIPT_DIR"/*.sh; do
    h=$(grep -nE "$B4" "$s" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    [ -n "$h" ] && hits+="$(basename "$s"): $h"$'\n'
done
if [ -n "$hits" ]; then
    fail "конструкция bash 4+ в скрипте (на macOS /bin/bash — 3.2)" "$hits"
else
    pass "скрипты совместимы с bash 3.2 (4 конструкции bash 4+ не встречаются)"
fi

# ─── 15. /brain-lint сам ищет неоднозначные ссылки по всему vault ────────────
# Проверка 6 выше грепает РЕПОЗИТОРИЙ — шаблоны в SKILL.md и commands/. Аудитора
# самого vault у этого класса не было вовсе: все четыре починки (135+ ссылок,
# 07-14, 07-15, 07-26 и сегодня) делались разовыми скриптами, поэтому класс и
# возвращался — постоянного инструмента, который его видит, не существовало.
# Хуже: 2026-08-03 замерено, что дисциплина автора тут вообще ни при чём. Пять
# заметок puzzlebot-voronka от 06-28…07-04 несли 33 ВЕРНЫЕ голые ссылки, пока
# 07-29 не появился goprofi-voronka с теми же пятью именами — ссылки стали
# неоднозначными задним числом, без правки в них, через три дня после того, как
# линт объявил vault чистым по этому классу. Значит ловится только регулярным
# vault-wide свипом «а имя всё ещё уникально», и Step 4b обязан существовать.
missing=""
LINT="$SCRIPT_DIR/commands/brain-lint.md"
[ -s "$LINT" ] || fail "commands/brain-lint.md пуст или отсутствует — проверка 15 не отработала"
grep -qF 'Step 4b' "$LINT" || missing+="brain-lint.md: нет шага 4b (свип неоднозначных ссылок)"$'\n'
grep -qF 'uniq -d' "$LINT" || missing+="brain-lint.md: шаг 4b не ищет неуникальные basename (uniq -d)"$'\n'
grep -qE 'grep -rn?F' "$LINT" || missing+="brain-lint.md: шаг 4b ищет без -F"$'\n'
grep -qiE 'whole vault regardless of scope|vault-wide' "$LINT" ||
    missing+="brain-lint.md: шаг 4b не объявлен vault-wide (в рамках проекта он слеп)"$'\n'
grep -qiE 'already exists in another project|not unique across the whole vault' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md: правило сужено до _PROJECT.md — потерян ретроактивный случай"$'\n'
if [ -n "$missing" ]; then
    fail "неоднозначные ссылки не проверяются в vault (класс возвращался 4 раза)" "$missing"
else
    pass "/brain-lint Step 4b свипает vault на неоднозначные ссылки, правило в SKILL.md общее"
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
        ".claude/skills/second-brain/lib/brain.sh" \
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
        pass "все 12 ожидаемых файлов на месте"
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
