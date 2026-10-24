#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# iwe-backup-protect.sh — защита источников перед разрушительной операцией
#
# WP-7 Ф237б, 2026-10-16 (пир-сессия 2026-10-16-18-iwe-template-backup).
#
# ОБЕЩАНИЕ: создать и ПРОВЕРИТЬ зашифрованный снимок источников ДО запуска
# переданной команды; если снимок не удался или не подтверждён — команда
# НЕ запускается вовсе. Технический контракт, не инструкция агенту "сначала
# сделай бэкап" (находка пир-сессии, Codex): отдельная команда "сделать
# копию" не гарантирует отмену следующего действия при её сбое, обёртка —
# гарантирует.
#
# ИЗВЕСТНАЯ ГРАНИЦА: защищает только операции, запущенные ЧЕРЕЗ эту обёртку.
# Прямой rm/перезапись мимо неё не перехватывается — честная граница
# гарантии, не скрытый пробел (зафиксировано явно, не для доработки позже).
#
# USAGE:
#   iwe-backup-protect.sh <path...> [--reason TEXT] -- <command> [args...]
#
# EXIT CODES:
#   0 — снимок подтверждён, команда запущена (код возврата — её собственный)
#   1 — снимок не удался/не подтверждён, команда НЕ запущена
#   2 — ошибка аргументов (usage)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

usage() {
    cat >&2 <<'EOF'
iwe-backup-protect.sh <path...> [--reason TEXT] -- <command> [args...]

Создаёт и проверяет зашифрованный снимок указанных путей, затем запускает
команду. Если снимок не удался — команда не запускается, exit 1.
EOF
}

SOURCES=()
REASON=""

while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; break ;;
        --reason)
            if [ $# -lt 2 ]; then
                echo "[protect] --reason требует значение" >&2
                usage
                exit 2
            fi
            REASON="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) SOURCES+=("$1"); shift ;;
    esac
done

if [ "${#SOURCES[@]}" -eq 0 ] || [ $# -eq 0 ]; then
    echo "[protect] не хватает аргументов: нужны пути-источники и команда после --" >&2
    usage
    exit 2
fi

COMMAND=("$@")

if ! command -v restic >/dev/null 2>&1; then
    echo "❌ [protect] restic не установлен — операция НЕ выполнена" >&2
    exit 1
fi

PROTECT_DIR="$HOME/.iwe-backup"
REPO_DIR="$PROTECT_DIR/protect-repo"
KEY_FILE="$PROTECT_DIR/protect-repo.key"
LOG_FILE="$PROTECT_DIR/protect-log.jsonl"

mkdir -p "$PROTECT_DIR"
chmod 700 "$PROTECT_DIR"

if [ ! -s "$KEY_FILE" ]; then
    # Атомарная запись (временный файл + mv): две параллельные первые
    # попытки инициализации не могут записать смешанный/обрезанный ключ
    # в финальный путь — побеждает ровно одна `mv`, вторая перезаписывает
    # тем же способом без повреждения (ключ не используется третьей
    # стороной параллельно). `-s` вместо `-f` выше также ловит пустой
    # файл, оставшийся от прерванного предыдущего запуска.
    KEY_TMP="$(mktemp "$PROTECT_DIR/.protect-repo.key.XXXXXX")"
    ( umask 077 && head -c32 /dev/urandom | base64 > "$KEY_TMP" )
    mv "$KEY_TMP" "$KEY_FILE"
    echo "ℹ️  [protect] создан новый ключ шифрования защитного хранилища: $KEY_FILE" >&2
    echo "    Сохраните резервную копию этого файла отдельно — его потеря делает все будущие protect-копии нечитаемыми." >&2
fi

export RESTIC_REPOSITORY="$REPO_DIR"
export RESTIC_PASSWORD_FILE="$KEY_FILE"

if [ ! -d "$REPO_DIR" ]; then
    echo "[protect] инициализирую защитное хранилище: $REPO_DIR" >&2
    if ! restic init >/dev/null 2>&1; then
        echo "❌ [protect] не удалось инициализировать репозиторий restic — операция НЕ выполнена" >&2
        exit 1
    fi
fi

echo "[protect] создаю снимок перед операцией: ${SOURCES[*]}" >&2

BACKUP_OUTPUT=""
BACKUP_STATUS=0
BACKUP_OUTPUT=$(restic backup --json --tag protect "${SOURCES[@]}" 2>&1) || BACKUP_STATUS=$?

if [ "$BACKUP_STATUS" -ne 0 ]; then
    echo "❌ [protect] снимок не удался (restic exit $BACKUP_STATUS) — операция НЕ выполнена" >&2
    echo "$BACKUP_OUTPUT" >&2
    exit 1
fi

SNAPSHOT_ID=""
SNAPSHOT_ID=$(printf '%s\n' "$BACKUP_OUTPUT" | python3 -c '
import json
import sys

snapshot_id = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(obj, dict) and obj.get("message_type") == "summary":
        snapshot_id = obj.get("snapshot_id", "")
print(snapshot_id)
') || SNAPSHOT_ID=""

if [ -z "$SNAPSHOT_ID" ]; then
    echo "❌ [protect] снимок создан, но идентификатор не извлечён из вывода restic — операция НЕ выполнена (сохранность не подтверждена)" >&2
    exit 1
fi

if ! restic snapshots "$SNAPSHOT_ID" >/dev/null 2>&1; then
    echo "❌ [protect] снимок $SNAPSHOT_ID не подтверждён репозиторием — операция НЕ выполнена" >&2
    exit 1
fi

# Журнал — только аудиторское удобство, не часть гарантии сохранности:
# снимок уже создан и подтверждён репозиторием выше. Сбой записи лога
# НЕ должен отменять уже доказанно безопасную операцию — поэтому весь
# блок best-effort (предупреждение в stderr, не exit).
if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
    echo "⚠️  [protect] не удалось создать каталог журнала $(dirname "$LOG_FILE") — запись пропущена, снимок всё равно подтверждён" >&2
else
    TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    SOURCES_JOINED=$(printf '%s\x1e' "${SOURCES[@]}")
    COMMAND_JOINED=$(printf '%s ' "${COMMAND[@]}")
    if ! python3 -c '
import json
import sys

timestamp, snapshot_id, sources_joined, reason, command_joined, log_file = sys.argv[1:7]
entry = {
    "timestamp": timestamp,
    "snapshot_id": snapshot_id,
    "sources": [s for s in sources_joined.split("\x1e") if s],
    "reason": reason,
    "command": command_joined.strip(),
}
with open(log_file, "a") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
' "$TIMESTAMP" "$SNAPSHOT_ID" "$SOURCES_JOINED" "$REASON" "$COMMAND_JOINED" "$LOG_FILE"; then
        echo "⚠️  [protect] запись в журнал $LOG_FILE не удалась — снимок всё равно подтверждён" >&2
    fi
fi

echo "✅ [protect] снимок $SNAPSHOT_ID подтверждён — запускаю операцию" >&2

# -u снимает RESTIC_REPOSITORY/RESTIC_PASSWORD_FILE перед exec: иначе они
# остаются в окружении обёрнутой команды (exec не создаёт новый процесс,
# только меняет образ) — если команда сама вызывает restic, она иначе
# неожиданно увидела бы путь к этому protect-репозиторию.
exec env -u RESTIC_REPOSITORY -u RESTIC_PASSWORD_FILE "${COMMAND[@]}"
