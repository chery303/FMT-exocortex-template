#!/usr/bin/env bash
# routing: hook  see DP.SC.048, DP.ROLE.062
# Pre-tool-use guard: блокирует Write/Edit на путях SPF/, FPF/ когда активна
# сессия скилла /pack-creator. Fail-safe от усталости (DP.ROLE.062 §FM.02).
#
# Срабатывает только если переменная окружения PACK_CREATOR_ACTIVE=1.
# Иначе — pass-through (другие скиллы не блокируются).
#
# Exit codes:
#   0 — действие разрешено
#   2 — действие заблокировано (PreToolUse contract — Claude получит ошибку)

set -uo pipefail

# Если не в режиме pack-creator — pass-through
if [ "${PACK_CREATOR_ACTIVE:-0}" != "1" ]; then
    exit 0
fi

# Читаем PreToolUse JSON из stdin (Claude Code formal contract)
# Парсим целиком (вход может быть в одну или несколько строк).
TOOL_NAME=""
FILE_PATH=""
PAYLOAD=$(cat)

case "$PAYLOAD" in
    *'"tool_name"'*)
        TOOL_NAME=$(printf '%s' "$PAYLOAD" | sed -E 's/.*"tool_name":[[:space:]]*"([^"]+)".*/\1/' | head -n1)
        ;;
esac
case "$PAYLOAD" in
    *'"file_path"'*)
        FILE_PATH=$(printf '%s' "$PAYLOAD" | sed -E 's/.*"file_path":[[:space:]]*"([^"]+)".*/\1/' | head -n1)
        ;;
esac
# NotebookEdit's real tool_input key is "notebook_path", not "file_path" --
# without this branch the guard silently passed through every NotebookEdit
# call despite listing it in the tool-name allow-list two lines below
# (found by adversarial review, 2026-10-06: a real NotebookEdit payload
# targeting SPF/ was not blocked).
if [ -z "$FILE_PATH" ]; then
    case "$PAYLOAD" in
        *'"notebook_path"'*)
            FILE_PATH=$(printf '%s' "$PAYLOAD" | sed -E 's/.*"notebook_path":[[:space:]]*"([^"]+)".*/\1/' | head -n1)
            ;;
    esac
fi

# Защищаем только Write/Edit/MultiEdit/NotebookEdit
case "$TOOL_NAME" in
    Write|Edit|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
esac

# Проверяем path на блокируемые директории. $CLAUDE_PROJECT_DIR is Claude
# Code's own, always-set-in-a-real-session project root (same idiom already
# used in inject-fault-profile.sh and sibling hooks) -- a bare "$HOME/IWE"
# guessed wrong on any non-default workspace location, the same bug class
# issue #1094 fixes elsewhere in this template (found by adversarial
# review, 2026-10-06). The bare fallback stays only for this hook's own
# unit test, which runs outside a real Claude Code session.
IWE_HOME="${CLAUDE_PROJECT_DIR:-$HOME/IWE}"
case "$FILE_PATH" in
    "$IWE_HOME"/SPF/*|"$IWE_HOME"/FPF/*)
        cat >&2 <<EOF
🚫 BLOCKED by pack-creator-spf-guard (DP.ROLE.062 §FM.02)

Write в upstream-локацию запрещён в режиме /pack-creator:
  $FILE_PATH

Это нарушит upgrade SPF при update.sh. Используй extension-механизм:
  → PACK-X/pack/X/<соответствующий-раздел>/

Подробнее: SPF/process/00-process-overview.md#extension-mechanism

Если изменение системного характера (касается всех Pack) — это отдельный
РП на правку SPF, а не работа /pack-creator. См. SPF/CLAUDE.md §8.1.
EOF
        exit 2
        ;;
esac

exit 0
