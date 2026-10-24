#!/bin/bash
# pull-on-touch.sh — PreToolUse hook: ленивая подтяжка git-репо при первом касании за сессию.
#
# Реализует правило Pull-on-Touch (CLAUDE.md §2 п.5) детерминированно, а не "по памяти агента".
# Причина: правило поведенческое → системно пропускается (инцидент 5 мая 2026 и 14 июня 2026 —
# ложный диагноз "Day Open пропущен" из-за чтения устаревшей локальной копии).
#
# Контракт:
#   Триггер: первое за сессию касание пути под ~/IWE/<repo> любым из инструментов
#            Read | Write | Edit | MultiEdit | NotebookEdit | Bash.
#   Вход:    stdin JSON {tool_name, tool_input, session_id}.
#   Действие: классификация read-only (scripts/lib/git-sync-status.sh, ls-remote,
#             никогда не трогает stash/rebase/refs) + на заведомо чистом дереве —
#             атомарный `git merge --ff-only` — один раз на репо на сессию.
#             НИКОГДА не делает autostash: issue #1245 (16.10.2026, рецидив
#             bug-2026-07-17) — конфликт при возврате стеша тихо топил несохранённые
#             правки, предупреждение было видно только в additionalContext одной сессии.
#   Отказы:  НИКОГДА не блокирует (exit 0 всегда). Грязное дерево / сетевой сбой / история
#            разошлась → подтяжка пропущена, в additionalContext пометка "данные potentially stale".
#   Состояние: ~/.claude/state/repo-pulled-<session>.txt (одно имя репо на строку).

set -uo pipefail

[[ "${1:-}" == "--help" ]] && {
    echo "pull-on-touch.sh — lazy read-only freshness check + safe ff-only fast-forward on first repo touch per session (CLAUDE.md §2 п.5)"
    exit 0
}

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

# Быстрый отсев: нет упоминания репо под IWE → нечего тянуть.
echo "$INPUT" | grep -q "IWE/" || exit 0

IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"

# Имя сессии для файла состояния.
SESSION_ID=$(echo "$INPUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("session_id",""))' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_SESSION_ID:-default}"

STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/repo-pulled-${SESSION_ID}.txt"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Извлечь имена репо (первый сегмент под IWE/) из пути (Read/Edit) или команды (Bash).
REPOS=$(INPUT="$INPUT" IWE_ROOT="$IWE_ROOT" python3 -c '
import sys, json, re, os
d = json.loads(os.environ["INPUT"])
ti = d.get("tool_input", {}) or {}
blob = (ti.get("file_path") or ti.get("path") or "") + "\n" + (ti.get("command") or "")
root = os.environ["IWE_ROOT"]
seen, out = set(), []
for name in re.findall(r"IWE/([A-Za-z0-9._-]+)", blob):
    if name in seen:
        continue
    seen.add(name)
    if os.path.isdir(os.path.join(root, name, ".git")):
        out.append(name)
print("\n".join(out))
' 2>/dev/null)

[ -z "$REPOS" ] && exit 0

TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 20"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/git-sync-status.sh
. "$HOOK_DIR/../../scripts/lib/git-sync-status.sh"

warns=""
pulled=""
while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    grep -qxF "$repo" "$STATE_FILE" && continue   # уже трогали этот репо в сессии
    echo "$repo" >> "$STATE_FILE"                  # пометить ДО pull (lazy: одна попытка на сессию)

    dir="$IWE_ROOT/$repo"
    branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)

    # Больше никогда не стешит (issue #1245, рецидив bug-2026-07-17): autostash
    # мог конфликтовать на возврате и тихо топить несохранённые правки — в stash,
    # с предупреждением, видимым только в additionalContext этого тул-колла.
    # Теперь: грязное дерево (tracked ИЛИ untracked) — вообще не трогаем репо,
    # чтобы не рисковать локальной работой. Чистое дерево — классифицируем
    # read-only (ls-remote, та же библиотека, что Sync Gate) и продвигаем ветку
    # только атомарным `merge --ff-only`: он либо чисто продвигает HEAD, либо
    # отказывает без побочных эффектов — промежуточного состояния не существует.
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        warns="${warns}${repo}: есть несохранённые правки, свежее с origin не подтягиваю (чтобы не рисковать ими), данные potentially stale. "
        continue
    fi

    check_git_sync_status "$dir" "$branch" 20
    case "$GIT_SYNC_STATUS" in
        OK)
            ;;
        STALE)
            # Single-ref fetch, not the library's "never fetch" guarantee: we
            # need the new commit object locally before `merge --ff-only` can
            # use it. Narrower than a full fetch, and `&&`-gated — a concurrent
            # session's lock on the same ref surfaces as the warning below,
            # not as a partial state.
            if $TO git -C "$dir" fetch --quiet origin "$branch" 2>/dev/null \
                && git -C "$dir" merge --ff-only --quiet "origin/$branch" 2>/dev/null; then
                pulled="${pulled}${repo} "
            else
                warns="${warns}${repo}: подтяжка не удалась (сеть/конфликт при обновлении ветки), данные potentially stale. "
            fi
            ;;
        *)
            warns="${warns}${repo}: подтяжка не удалась ($GIT_SYNC_STATUS), данные potentially stale. "
            ;;
    esac
done <<< "$REPOS"

# Сообщить агенту только если есть что сказать (свежие данные или пометка stale).
msg=""
[ -n "$pulled" ] && msg="🔄 Подтянул свежее: ${pulled}"
[ -n "$warns" ] && msg="${msg}⚠️ ${warns}"

if [ -n "$msg" ]; then
    printf '%s' "$msg" | python3 -c 'import sys,json; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.stdin.read()}}))'
fi

exit 0
