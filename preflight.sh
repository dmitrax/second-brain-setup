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

# unquoted_globs <file> — печатает строки shell-блоков, где `*` не закавычена.
# Блоки, объявленные markdown/yaml, пропускаются намеренно: это шаблоны заметок, а не
# команды, и звёздочка в них — разметка.
# Почему посимвольно, а не грепом: закавыченный glob (`find -name "*.md"`) — это и есть
# требуемое исправление, а не нарушение; отличить его от голого можно только пройдя
# строку с учётом состояния кавычек. Греп по `*` краснел бы на собственной починке.
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
    bash "$LIBSH" stamp-field "$TMPLIB/a.md" updated 2026-08-03 >/dev/null 2>&1 ||
        problems+="stamp-field упал на нормальном файле"$'\n'
    grep -q '^updated: 2026-08-03$' "$TMPLIB/a.md" || problems+="stamp-field не проставил дату"$'\n'
    grep -q '^tags: \[session, x\]$' "$TMPLIB/a.md" || problems+="stamp-field развернул инлайн-список"$'\n'
    grep -q '^version: "1.4.3"$' "$TMPLIB/a.md" || problems+="stamp-field снял кавычки"$'\n'
    grep -q '^count: 007$' "$TMPLIB/a.md" || problems+="stamp-field переписал 007"$'\n'
    # Отсутствующий ключ добавляется, существующие не трогаются.
    bash "$LIBSH" stamp-field "$TMPLIB/a.md" brain-version '"v1.7.0"' >/dev/null 2>&1 ||
        problems+="stamp-field не добавил отсутствующий ключ"$'\n'
    grep -q '^brain-version: "v1.7.0"$' "$TMPLIB/a.md" || problems+="stamp-field не записал brain-version"$'\n'
    grep -q '^count: 007$' "$TMPLIB/a.md" || problems+="stamp-field испортил соседний ключ при добавлении"$'\n'
    # Ключ с посторонними символами — отказ, иначе можно вписать что угодно в блок.
    bash "$LIBSH" stamp-field "$TMPLIB/a.md" 'weird: key' x >/dev/null 2>&1 &&
        problems+="stamp-field принял ключ с посторонними символами"$'\n'
    # Файла без frontmatter трогать нельзя.
    printf -- '# no frontmatter\n' > "$TMPLIB/b.md"
    bash "$LIBSH" stamp-field "$TMPLIB/b.md" updated 2026-08-03 >/dev/null 2>&1 &&
        problems+="stamp-field принял файл без frontmatter"$'\n'
    # version обязана что-то печатать всегда: нет файла VERSION -> "unknown", не пусто.
    [ -n "$(bash "$LIBSH" version 2>/dev/null)" ] ||
        problems+="version не печатает ничего (должна хотя бы unknown)"$'\n'

    # archive: перенос Done в архив. Проверяем ровно то, ради чего он писался —
    # что ничего не теряется и не дублируется, и что чужие секции не тронуты.
    printf -- '## In progress\n- [x] закрытый подпункт живой задачи\n- [ ] сама задача\n\n## Done\n- [x] 2026-06-01 — старая\n      её вторая строка\n- ✅ 2026-07-01 — галочкой\n- [x] 2026-12-01 — новая\n- [x] без даты\n\n## Backlog\n- [ ] хвост\n' > "$TMPLIB/tb.md"
    printf -- '# Архив\n' > "$TMPLIB/ar.md"
    # dry-run обязан ничего не писать
    bash "$LIBSH" archive "$TMPLIB/tb.md" "$TMPLIB/ar.md" --before 2026-08-01 >/dev/null 2>&1 || true
    [ "$(grep -c . "$TMPLIB/ar.md")" -eq 1 ] ||
        problems+="archive: dry-run записал в архив"$'\n'
    bash "$LIBSH" archive "$TMPLIB/tb.md" "$TMPLIB/ar.md" --before 2026-08-01 --apply >/dev/null 2>&1 ||
        problems+="archive: упал на нормальном входе"$'\n'
    grep -q '2026-06-01' "$TMPLIB/ar.md" || problems+="archive: не перенёс старую запись"$'\n'
    grep -q 'её вторая строка' "$TMPLIB/ar.md" || problems+="archive: потерял продолжение записи"$'\n'
    grep -q '2026-07-01' "$TMPLIB/ar.md" || problems+="archive: не знает маркер ✅"$'\n'
    grep -q '2026-12-01' "$TMPLIB/tb.md" || problems+="archive: унёс свежую запись"$'\n'
    grep -q 'без даты' "$TMPLIB/tb.md" || problems+="archive: унёс запись без даты"$'\n'
    grep -q 'закрытый подпункт' "$TMPLIB/tb.md" || problems+="archive: тронул секцию In progress"$'\n'
    grep -q 'хвост' "$TMPLIB/tb.md" || problems+="archive: потерял секцию после Done"$'\n'
    grep -q '2026-06-01' "$TMPLIB/tb.md" && problems+="archive: продублировал запись (осталась в таскборде)"$'\n'
    # Кривая дата и отсутствие файла — отказ, а не «ничего не нашёл».
    bash "$LIBSH" archive "$TMPLIB/tb.md" "$TMPLIB/ar.md" --before вчера >/dev/null 2>&1 &&
        problems+="archive: принял неверный формат даты"$'\n'
    bash "$LIBSH" archive "$TMPLIB/nope.md" "$TMPLIB/ar.md" --before 2026-08-01 >/dev/null 2>&1 &&
        problems+="archive: принял несуществующий таскборд"$'\n'
    # lint-diff: ключ сравнивается, деталь только показывается. Проверяем ровно это —
    # иначе известная находка с изменившимся числом каждый раз считалась бы новой,
    # а смысл механизма в том, чтобы отделять регрессию от припаркованного долга.
    printf 'prose-budget\tgoprofi: 154\nmap-stale\tcadrika\n' > "$TMPLIB/f1.txt"
    command cat "$TMPLIB/f1.txt" | bash "$LIBSH" lint-diff "$TMPLIB/base.txt" --seal >/dev/null 2>&1 ||
        problems+="lint-diff: упал на первом прогоне"$'\n'
    [ -s "$TMPLIB/base.txt" ] || problems+="lint-diff: --seal не записал baseline"$'\n'
    # деталь изменилась, ключ тот же -> находка НЕ новая
    printf 'prose-budget\tgoprofi: 999\nmap-stale\tcadrika\n' > "$TMPLIB/f2.txt"
    out=$(command cat "$TMPLIB/f2.txt" | bash "$LIBSH" lint-diff "$TMPLIB/base.txt" 2>&1)
    case "$out" in
        *NEW*) problems+="lint-diff: изменившееся число сделало известную находку новой"$'\n' ;;
    esac
    # новый ключ -> новая находка; исчезнувший -> GONE
    printf 'prose-budget\tgoprofi: 154\nzone-missing\tgoprofi\n' > "$TMPLIB/f3.txt"
    out=$(command cat "$TMPLIB/f3.txt" | bash "$LIBSH" lint-diff "$TMPLIB/base.txt" 2>&1)
    case "$out" in
        *"+ zone-missing"*) : ;;
        *) problems+="lint-diff: не заметил новую находку"$'\n' ;;
    esac
    case "$out" in
        *"- map-stale"*) : ;;
        *) problems+="lint-diff: не заметил исчезнувшую находку"$'\n' ;;
    esac
    # без --seal baseline обязан остаться прежним
    grep -q 'zone-missing' "$TMPLIB/base.txt" &&
        problems+="lint-diff: записал baseline без --seal"$'\n'
    # шаг обязан быть в промпте, иначе код есть, а вызывать его некому
    LINTMD="$SCRIPT_DIR/commands/brain-lint.md"
    # Паттерн с двоеточием, а не голое «Step 12»: подстрока матчит и «Step 12z», из-за
    # чего негативный тест на переименование шага проходил как зелёный (третий случай
    # ловушки с подстрокой за сессию — см. также vault-sync-DISABLED).
    grep -qiE '^## Step [0-9]+[a-z]?: Report the delta' "$LINTMD" ||
        problems+="brain-lint.md: нет шага сверки с baseline"$'\n'
    grep -qF 'lint-diff' "$LINTMD" || problems+="brain-lint.md: шаг дельты не вызывает lint-diff"$'\n'
    grep -qF 'lint-collect' "$LINTMD" ||
        problems+="brain-lint.md: проверки не вызываются из lib (снова проза)"$'\n'
    # Требование полноты переехало в код вместе с проверками: lint-collect обязан
    # ронять на пустом входе, а промпт — не подменять его ручными грепами.
    grep -qiE 'do not fall back to' "$LINTMD" ||
        problems+="brain-lint.md: потерян запрет подменять lint-collect ручными грепами"$'\n'
    grep -qiE 'refusing to report a clean vault' "$LIBSH" ||
        problems+="lint-collect не роняет на пустом входе"$'\n'

    # Наличие обеих страховок — грепом.
    grep -q 'refused — .*moved.*kept' "$LIBSH" ||
        problems+="archive: снята сверка числа записей до/после"$'\n'
    grep -q 'refused — line balance off' "$LIBSH" ||
        problems+="archive: снята сверка числа строк"$'\n'
    grep -q 'done_sec && /\^\[\[:space:\]\]\*-' "$LIBSH" ||
        problems+="archive: счёт записей идёт не по секции Done"$'\n'
    # А работают ли они — проверяется ЗАПУСКОМ на намеренно сломанной копии.
    # Иначе страховка непроверяема по построению: пока остальной код верен, её
    # отключение не даёт наблюдаемого эффекта, и «она есть» подтверждается только
    # тем, что строка кода на месте. Ломаем парсер так, чтобы одна запись пропала,
    # и требуем: отказ (ненулевой код) И оба файла нетронуты.
    # Разделитель sed — `#`: в тексте замены есть `||`, и с `|` sed падает, оставляя
    # пустой файл. Пустая «сломанная копия» ничего не делает, выходит с 0 и читается
    # как «страховка пропустила» — поймано на себе 2026-08-03. Отсюда три проверки
    # ниже: копия непуста, отличается от оригинала и синтаксически валидна.
    sed 's#print > (w "/" dest)#if (!(dest == "moved" \&\& n["moved"] == 1)) print > (w "/" dest)#' \
        "$LIBSH" > "$TMPLIB/broken.sh" 2>/dev/null
    if [ ! -s "$TMPLIB/broken.sh" ] ||
       cmp -s "$TMPLIB/broken.sh" "$LIBSH" ||
       ! bash -n "$TMPLIB/broken.sh" 2>/dev/null; then
        problems+="archive: не удалось собрать сломанную копию — страховка не проверена"$'\n'
    fi
    printf -- '## Done\n- [x] 2026-01-01 — первая\n- [x] 2026-02-01 — вторая\n- [x] 2026-12-01 — свежая\n' > "$TMPLIB/tb2.md"
    printf -- '# Архив\n' > "$TMPLIB/ar2.md"
    tb2_sum=$(command cksum < "$TMPLIB/tb2.md"); ar2_sum=$(command cksum < "$TMPLIB/ar2.md")
    if bash "$TMPLIB/broken.sh" archive "$TMPLIB/tb2.md" "$TMPLIB/ar2.md" \
            --before 2026-08-01 --apply >/dev/null 2>&1; then
        problems+="archive: сломанный парсер ТЕРЯЕТ запись, а страховка пропустила это"$'\n'
    fi
    [ "$(command cksum < "$TMPLIB/tb2.md")" = "$tb2_sum" ] ||
        problems+="archive: при отказе таскборд всё равно изменён"$'\n'
    [ "$(command cksum < "$TMPLIB/ar2.md")" = "$ar2_sum" ] ||
        problems+="archive: при отказе архив всё равно изменён"$'\n'
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
        fail "lib/brain.sh: vault-sync/stamp-field ведут себя неверно" "$problems"
    else
        pass "lib/brain.sh: stamp-field щадит соседние поля, vault-sync различает исходы"
    fi
fi

# ─── 4e. lint-collect отрабатывает на фикстурном vault ───────────────────────
# Проверяется ЗАПУСКОМ на ваулте, где каждый класс находки представлен ровно
# одним экземпляром — как 4b/4c проверяют guard и archive. Греп по форме здесь
# бесполезен вдвойне: до переезда в lib/ эти проверки жили прозой, каждая сессия
# писала их заново, и замер 2026-08-04 показал 11 ложных находок из 11 у одной
# такой реализации. Фикстура фиксирует и то, что находкой БЫТЬ НЕ ДОЛЖНО.
if [ -f "$LIBSH" ]; then
    problems=""
    LCV=$(mktemp -d)
    mkdir -p "$LCV/proj/wiki" "$LCV/proj/sessions" "$LCV/other/wiki" "$LCV/00-system"

    # Реестр знает оба проекта — плюс один, которого нет на диске.
    printf -- '# Index\n- [[proj/_PROJECT|proj]]\n- [[other/_PROJECT|other]]\n- [[ghost/_PROJECT|ghost]]\n' \
        > "$LCV/00-system/index.md"

    # proj: проза за бюджетом, For future Claude за бюджетом, updated протух.
    {
        printf -- '---\nproject: proj\nupdated: 2020-01-01\n---\n\n## Current state\n'
        i=0; while [ $i -lt 55 ]; do echo "строка состояния $i"; i=$((i + 1)); done
        printf -- '\n## For future Claude\n'
        i=0; while [ $i -lt 25 ]; do echo "константа $i"; i=$((i + 1)); done
    } > "$LCV/proj/_PROJECT.md"

    # Таскборд: за всеми тремя порогами, оба маркера закрытия.
    {
        printf -- '## In progress\n'
        i=0; while [ $i -lt 320 ]; do echo "- [ ] задача $i"; i=$((i + 1)); done
        printf -- '\n## Done\n'
        i=0; while [ $i -lt 12 ]; do echo "- [x] 2026-01-01 — сделано $i"; i=$((i + 1)); done
        i=0; while [ $i -lt 12 ]; do echo "- ✅ 2026-01-02 — сделано ✅ $i"; i=$((i + 1)); done
        i=0; while [ $i -lt 300 ]; do echo "хвост $i"; i=$((i + 1)); done
    } > "$LCV/proj/taskboard.md"

    # Карта старше последней сессии.
    printf -- '---\nupdated: 2026-01-01\n---\n# map\n' > "$LCV/proj/architecture-map.md"
    # Три сессии: у двух есть zone, у третьей нет -> key-uniformity.
    printf -- '---\ndate: 2026-06-01\nzone: root\n---\nx\n'  > "$LCV/proj/sessions/2026-06-01_1000_session.md"
    printf -- '---\ndate: 2026-06-02\nzone: back\n---\nx\n'  > "$LCV/proj/sessions/2026-06-02_1000_session.md"
    printf -- '---\ndate: 2026-08-01\n---\nx\n'              > "$LCV/proj/sessions/2026-08-01_1000_session.md"

    # Заметки: одна без обратной ссылки, одна без соседней, одна вообще без ссылок.
    printf -- '---\ndate: 2026-06-01\n---\nтело [[note-sibling]]\n'        > "$LCV/proj/wiki/note-backless.md"
    printf -- '---\ndate: 2026-06-01\n---\nтело [[../_PROJECT|_PROJECT]]\n' > "$LCV/proj/wiki/note-sibling.md"
    printf -- '---\ndate: 2026-06-01\n---\nни одной ссылки\n'              > "$LCV/proj/wiki/note-alone.md"

    # Черновик старше 14 дней.
    printf -- '---\ndate: 2026-01-01\nstatus: draft\n---\nчерновик\n' > "$LCV/proj/wiki/draft-old.md"

    # Decision-заметки: off-schema status, битая ссылка, legacy-форма — и ДВА
    # случая, которые находкой быть не должны: `supersedes: ~` (YAML null) и
    # цитата legacy-формы внутри fenced-блока.
    printf -- '---\nstatus: partially-superseded-by x\ndate: 2026-06-01\n---\n[[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/proj/wiki/decision-offschema.md"
    printf -- '---\nstatus: accepted\nsuperseded-by: decision-nowhere\n---\n[[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/proj/wiki/decision-brokenref.md"
    printf -- '---\nstatus: superseded-by: decision-x.md\n---\n[[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/proj/wiki/decision-legacyform.md"
    printf -- '---\nstatus: accepted\nsupersedes: ~\n---\n[[../_PROJECT|_PROJECT]]\n```\nstatus: superseded-by: decision-x.md\n```\n' \
        > "$LCV/proj/wiki/decision-clean.md"

    # Незакрытый frontmatter.
    printf -- '---\ndate: 2026-06-01\nтело без закрывающей черты\n' > "$LCV/proj/wiki/broken-fm.md"

    # Ключ, который шаблон печатает ПУСТЫМ почти везде, — не конвенция. Замерено
    # 2026-08-04: `supersedes:` пуст в 29 заметках cadrika из 32, и порог, считавший
    # присутствие ключа, объявлял нарушителями те три, где пустой строки нет.
    # Здесь: `supersedes:` пуст у трёх из четырёх, отсутствует у одной. Находкой
    # это быть не должно; если порог снова начнёт считать присутствие — станет.
    i=1; while [ $i -le 3 ]; do
        printf -- '---\nstatus: accepted\ndate: 2026-06-0%s\nsupersedes:\n---\n[[../_PROJECT|_PROJECT]] [[decision-empty-1]]\n' \
            "$i" > "$LCV/other/wiki/decision-empty-$i.md"
        i=$((i + 1))
    done
    printf -- '---\nstatus: accepted\ndate: 2026-06-04\n---\n[[../_PROJECT|_PROJECT]] [[decision-empty-1]]\n' \
        > "$LCV/other/wiki/decision-nosupersedes.md"

    # other: не в реестре нет — он есть; зато даёт неуникальное имя note-alone,
    # из-за чего голая [[note-alone]] в его заметке становится неоднозначной.
    printf -- '---\nproject: other\nupdated: 2026-08-01\n---\n## Current state\nкоротко\n' \
        > "$LCV/other/_PROJECT.md"
    printf -- '---\ndate: 2026-06-01\n---\nссылка [[note-alone]] и [[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/other/wiki/note-alone.md"
    # Цитата той же голой ссылки в бэктиках — находкой быть НЕ должна. Плюс
    # непарный бэктик выше по файлу: без сброса состояния на пустой строке он
    # переворачивал чтение всего остатка (замерено на живом connections.md).
    printf -- '---\ndate: 2026-06-01\n---\nабзац с непарным бэктиком `вот\n\nцитата `[[note-alone]]` в бэктиках [[../_PROJECT|_PROJECT]]\n' \
        > "$LCV/other/wiki/note-quotes.md"

    # Проект, которого нет в реестре.
    mkdir -p "$LCV/unreg"
    printf -- '---\nproject: unreg\nupdated: 2026-08-01\n---\n## Current state\nкоротко\n' \
        > "$LCV/unreg/_PROJECT.md"

    # Проект, ВЛОЖЕННЫЙ в другой проект. Именно этот класс инвентарь и терял:
    # замерено 2026-08-04, `nf-content/MWR-Dima` — свой _PROJECT.md, свой taskboard,
    # своя wiki, запись в реестре — был невидим для всех проектных проверок, потому
    # что перечень проектов строился по верхнему уровню. Файловые свипы его видели
    # всегда, отчего расхождение читалось как регрессия, а не как дыра в охвате.
    mkdir -p "$LCV/other/nested"
    printf -- '---\nproject: nested\nupdated: 2020-01-01\n---\n## Current state\nкоротко\n' \
        > "$LCV/other/nested/_PROJECT.md"

    # Файл под .gitignore обязан быть найден: свип ходит по файловой системе, а не
    # по индексу git. Оболочка сессии на Mac подменяет grep на ugrep с
    # --ignore-files, и он такой файл пропускает молча — здесь этого быть не должно.
    printf -- 'ignored/\n' > "$LCV/.gitignore"
    mkdir -p "$LCV/ignored"
    printf -- '---\ndate: 2026-01-01\nstatus: draft\n---\nскрытый черновик\n' > "$LCV/ignored/hidden-draft.md"

    out="$LCV/out.txt"
    if bash "$LIBSH" lint-collect "$LCV" > "$out" 2>"$LCV/err.txt"; then :; else
        problems+="lint-collect упал на фикстуре: $(head -1 "$LCV/err.txt")"$'\n'
    fi
    want() { grep -q "^$1	" "$out" || problems+="не нашёл класс: $1"$'\n'; }
    nope() { grep -q "^$1	" "$out" && problems+="ложная находка: $1"$'\n'; }

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
    # Вложенный проект обязан попасть в проектные проверки, а не только в файловые.
    want 'stale-project:other/nested'
    want 'project-unregistered:other/nested'
    # Чего быть не должно.
    nope 'decision-ref:proj/wiki/decision-clean.md'
    nope 'decision-legacy:proj/wiki/decision-clean.md'
    nope 'ambiguous-link:other/wiki/note-quotes.md'
    nope 'stale-project:other'
    nope 'key-uniformity:other/decisions'
    # Счётчик Done обязан видеть оба маркера: 12 + 12 = 24 > 20, по одному не сработал бы.
    grep -q '^taskboard-done:proj	24 ' "$out" ||
        problems+="счётчик Done не сложил [x] и ✅ (ожидалось 24)"$'\n'
    # Контракт вывода: ключи уникальны, иначе lint-diff откажется работать.
    d=$(cut -f1 "$out" | sort | uniq -d)
    [ -z "$d" ] || problems+="ключи не уникальны: $(printf '%s' "$d" | tr '\n' ' ')"$'\n'
    # Каждая строка обязана быть key<TAB>detail.
    grep -qv "	" "$out" && problems+="есть строки без табуляции — контракт вывода нарушен"$'\n'

    # Пустой вход обязан ронять, а не печатать зелёное. Это уже дважды стоило
    # двух недель слепых ворот (mapfile, except ImportError).
    mkdir -p "$LCV/nothing"
    bash "$LIBSH" lint-collect "$LCV/nothing" >/dev/null 2>&1 &&
        problems+="lint-collect напечатал зелёное на пустом каталоге"$'\n'
    mkdir -p "$LCV/nomd" && printf -- '# x\n' > "$LCV/nomd/a.md"
    bash "$LIBSH" lint-collect "$LCV/nomd" >/dev/null 2>&1 &&
        problems+="lint-collect не потребовал ни одного _PROJECT.md"$'\n'
    bash "$LIBSH" lint-collect "$LCV/nope" >/dev/null 2>&1 &&
        problems+="lint-collect принял несуществующий путь"$'\n'

    rm -rf "$LCV"
    if [ -n "$problems" ]; then
        fail "lint-collect неверен на фикстуре" "$problems"
    else
        pass "lint-collect прогнан на фикстуре: 20 классов находок, 4 не-находки, пустой вход роняет"
    fi
fi

# ─── 4d. Версия не хардкодится в шаблонах ────────────────────────────────────
# `brain-version:` был мёртвым полем: литерал в шаблоне brain-init, который надо было
# править руками при каждом релизе — и не правили. Замерено 2026-08-03: 8 проектов
# несут "1.3", два "1.5.0", ни один 1.6.0, и ни одна команда поле не читала.
# Теперь версия берётся из установленного VERSION, а /brain-save её штампует.
missing=""
if grep -qE '^brain-version:[[:space:]]*"[0-9]' "$SCRIPT_DIR/commands/brain-init.md"; then
    missing+="brain-init.md: brain-version захардкожен литералом — при релизе разойдётся молча"$'\n'
fi
grep -q 'BRAIN_VERSION' "$SCRIPT_DIR/commands/brain-init.md" ||
    missing+="brain-init.md: в шаблоне нет подстановки версии"$'\n'
grep -qE 'brain\.sh" version|brain\.sh version' "$SCRIPT_DIR/commands/brain-init.md" ||
    missing+="brain-init.md: не сказано, откуда брать версию (вызов brain.sh version)"$'\n'
grep -q 'stamp-field .*brain-version' "$SCRIPT_DIR/commands/brain-save.md" ||
    missing+="brain-save.md: brain-version не штампуется — поле снова станет мёртвым"$'\n'
for s in install.sh update.sh; do
    grep -q 'lib/VERSION' "$SCRIPT_DIR/$s" ||
        missing+="$s: не пишет lib/VERSION — установленная система не знает своей версии"$'\n'
    # Штамп обязан различать чистое дерево и грязное. Обычный порядок работы —
    # правка → update.sh (обкатать) → коммит, поэтому без --dirty VERSION фиксирует
    # describe ДО коммита и отстаёт молча: замерено 2026-08-03, _PROJECT.md получил
    # -10-g34f5287 при фактически установленных -12-g9a657fe.
    grep -qE 'describe[^|]*--dirty' "$SCRIPT_DIR/$s" ||
        missing+="$s: describe без --dirty — штамп версии отстаёт при правке до коммита"$'\n'
done
if [ -n "$missing" ]; then
    fail "версия системы не отслеживается (мёртвое поле brain-version)" "$missing"
else
    pass "версия берётся из установленного VERSION и штампуется при сохранении"
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

# ─── 10b. Шаблон CLAUDE.md не заводит третью копию инвентаря ─────────────────
# Сестра проверки 10, тот же разбор fenced-блока Step 4. Ответ на вопрос 5 (стек)
# писался сразу в три файла: _PROJECT.md (Step 3), architecture-map.md (Step 3c) и
# CLAUDE.md (Step 4). Первые два ведёт /brain-save, третий — никто, и для публичного
# репо Step 5 кладёт его в .gitignore, так что это единственная копия, которую не
# видно меняющейся. Замерено 2026-08-04 на самом second-brain-setup: копия называла
# три bash-скрипта ещё шесть недель после того, как lib/brain.sh стал четвёртым,
# при верной копии в vault. Пустой $CLAUDE_TPL уже отработан проверкой 10 выше.
if [ -z "$CLAUDE_TPL" ]; then
    : # 10 уже упала на этом, второй раз не шумим
elif echo "$CLAUDE_TPL" | grep -qE '^#{2,3} +(Stack|Стек)'; then
    fail "шаблон CLAUDE.md в brain-init.md завёл секцию инвентаря — она принадлежит _PROJECT.md и architecture-map.md"
elif echo "$CLAUDE_TPL" | grep -qF 'ANSWER TO QUESTION 5'; then
    fail "шаблон CLAUDE.md в brain-init.md подставляет ответ 5 целиком — в Rules идут только ограничения из него"
else
    pass "шаблон CLAUDE.md не дублирует инвентарь стека"
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
LIB="$SCRIPT_DIR/lib/brain.sh"
grep -qF 'ambiguous-link:' "$LIB" || missing+="lib: нет свипа неоднозначных ссылок"$'\n'
grep -qF 'uniq -d' "$LIB" || missing+="lib: свип не ищет неуникальные basename (uniq -d)"$'\n'
grep -qE 'grep -rn?F' "$LIB" || missing+="lib: свип ищет без -F"$'\n'
grep -qiE 'whatever the scope|whole vault' "$LIB" ||
    missing+="lib: свип не объявлен vault-wide (в рамках проекта он слеп)"$'\n'
grep -qF 'ambiguous-link' "$LINT" ||
    missing+="brain-lint.md: находка ambiguous-link не описана — сессия не знает, что с ней делать"$'\n'
grep -qiE 'already exists in another project|not unique across the whole vault' "$SCRIPT_DIR/SKILL.md" ||
    missing+="SKILL.md: правило сужено до _PROJECT.md — потерян ретроактивный случай"$'\n'
if [ -n "$missing" ]; then
    fail "неоднозначные ссылки не проверяются в vault (класс возвращался 4 раза)" "$missing"
else
    pass "/brain-lint Step 4b свипает vault на неоднозначные ссылки, правило в SKILL.md общее"
fi

# ─── 16. Шаблоны frontmatter объявлены минимумом + шаг поиска локальных ключей ─
# Проект может требовать ключи, которых пакет не знает (goprofi-voronka: `zone:` на
# session-логах и decision-заметках — монорепо, разбитое на зоны). Дефект был не в том,
# что в шаблоне «забыли поле»: правило лежало в CLAUDE.md проекта и грузилось каждую
# сессию, но в момент записи fenced-блок с тремя ключами читается как исчерпывающий.
# Явный шаблон под рукой побеждает правило, прочитанное двести сообщений назад —
# поэтому шаблон обязан вслух объявлять себя неполным, а перед записью обязан стоять
# шаг поиска. Замерено 2026-08-03: 4 лога из 55 и 2 decision-заметки из 100 без `zone:`,
# последние два — 01.08, дважды за день.
missing=""
BS="$SCRIPT_DIR/commands/brain-save.md"
grep -qF 'Step 0c' "$BS" || missing+="brain-save.md: нет шага поиска локальных конвенций (0c)"$'\n'
# Шаг обязан предшествовать обоим шаблонам, иначе он inert — как и sync после записи.
c_ln=$(grep -n '^## Step 0c' "$BS" | head -1 | cut -d: -f1)
s1_ln=$(grep -n '^## Step 1:' "$BS" | head -1 | cut -d: -f1)
if [ -z "$c_ln" ] || [ -z "$s1_ln" ]; then
    missing+="brain-save.md: не найден Step 0c или Step 1 — проверка порядка не сработала"$'\n'
elif [ "$c_ln" -ge "$s1_ln" ]; then
    missing+="brain-save.md: шаг поиска стоит после первого шаблона (строка $c_ln против $s1_ln)"$'\n'
fi
# Оба шаблона — и лога, и decision-заметки — обязаны называть себя минимумом.
grep -qiE 'minimum, not the full list' "$BS" ||
    missing+="brain-save.md: шаблон session-лога не объявлен минимумом"$'\n'
grep -qiE 'Minimum frontmatter' "$BS" ||
    missing+="brain-save.md: шаблон decision-заметки не объявлен минимумом"$'\n'
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
