#!/bin/bash
# PreCompact Checkpoint Hook (issue #1183)
# Event: PreCompact
# Перед сжатием контекста снимает слепок рабочего состояния. Вернёт его агенту
# хук precompact-restore.sh на событии SessionStart (matcher "compact").
#
# Почему так: PreCompact не имеет канала к модели — Claude Code выбрасывает его
# systemMessage/continue, additionalContext для него не предусмотрен
# (https://code.claude.com/docs/en/hooks). Поэтому здесь ничего не печатается:
# хук только пишет файл, доставка — на SessionStart после сжатия.
#
# Слепок содержит реплики пользователя и ассистента — хранить его в репозитории
# небезопасно: `.gitignore`, которым это помечено в шаблоне, update.sh доставляет
# не на всех установках (issue #1183, холодное ревью). Поэтому файл лежит в
# персональном каталоге Claude Code, а не в рабочей копии проекта.
export LC_ALL=C

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Некорректный/длинный идентификатор отклоняем, а не вычищаем: иначе "a/b" и
# "ab" дали бы один файл, а id в тысячи символов уронит mv (ENAMETOOLONG).
case "$SESSION_ID" in '' | *[!A-Za-z0-9_-]* ) exit 0 ;; esac
[ "${#SESSION_ID}" -le 128 ] || exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
TRIGGER=$(printf '%s' "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)
CHECKPOINT_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/iwe-checkpoints"
mkdir -p "$CHECKPOINT_DIR" 2>/dev/null || exit 0
chmod 700 "$CHECKPOINT_DIR" 2>/dev/null
CHECKPOINT_FILE="$CHECKPOINT_DIR/checkpoint-$SESSION_ID.md"

# Хвост транскрипта: последние реплики пользователя и последний ответ ассистента.
# JSONL разбираем терпимо (fromjson?, не пайп в jq целиком): "tail -n" может
# отдать недописанную последнюю строку параллельно пишущего процесса, и один
# битый JSON не должен обрывать разбор всего хвоста.
USER_TAIL=""
ASSISTANT_TAIL=""
if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  RECENT=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null)
  # Фильтр служебных вставок — на уровне КАЖДОГО text-блока, не склеенного
  # сообщения: Claude Code добавляет <system-reminder> отдельным вторым
  # блоком того же сообщения пользователя, и фильтр по началу строки после
  # join его не ловит (issue #1183, холодное ревью, M2).
  USER_TAIL=$(printf '%s\n' "$RECENT" | jq -R -r '
      (fromjson? // empty)
      | select(.type == "user")
      | .message.content
      | if type == "string" then [.] else [.[]? | select(.type == "text") | .text] end
      | map(select(test("^<(system-reminder|command-|local-command|ide_)") | not) | gsub("\n"; " "))
      | join(" ")
      | select(length > 0)
      | .[0:600]' 2>/dev/null | tail -n 3)
  ASSISTANT_TAIL=$(printf '%s\n' "$RECENT" | jq -R -r '
      (fromjson? // empty)
      | select(.type == "assistant")
      | .message.content
      | if type == "string" then [.] else [.[]? | select(.type == "text") | .text] end
      | map(gsub("\n"; " "))
      | join(" ")
      | select(length > 0)' 2>/dev/null | tail -n 1 | cut -c1-1500)
fi

TMP=$(mktemp "$CHECKPOINT_DIR/.checkpoint.XXXXXX") || exit 0
chmod 600 "$TMP"
{
  echo "# Checkpoint перед сжатием контекста"
  echo "- Сессия: $SESSION_ID"
  echo "- Время: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Причина сжатия: $TRIGGER"
  echo
  echo "## Последние запросы пользователя"
  if [ -n "$USER_TAIL" ]; then printf '%s\n' "$USER_TAIL" | sed 's/^/- /'; else echo "- (не удалось прочитать транскрипт)"; fi
  echo
  echo "## Последний ответ ассистента"
  if [ -n "$ASSISTANT_TAIL" ]; then printf '%s\n' "$ASSISTANT_TAIL"; else echo "(не удалось прочитать транскрипт)"; fi
  # Защита в глубину: даже после фильтрации блоков выше нейтрализуем остаток
  # похожих тегов, чтобы вывод restore-хука нельзя было выдать за системную
  # вставку (issue #1183, холодное ревью, M2/Б1).
} | sed -E 's/<(\/?)(system-reminder|command-[a-z-]*|local-command-?[a-z-]*|ide_selection)>/[\1\2]/g' > "$TMP"
if ! mv "$TMP" "$CHECKPOINT_FILE"; then rm -f "$TMP"; fi

# Слепки старых сессий копить незачем.
find "$CHECKPOINT_DIR" -maxdepth 1 -name 'checkpoint-*.md' -mtime +7 -delete 2>/dev/null
exit 0
