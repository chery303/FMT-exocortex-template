#!/bin/bash
# session-manifest-write.sh — писатель attest-манифеста сессии (F1, консенсус
# пир-сессии 2026-08-21-02-day-close-anomaly-classes, WP-484).
#
# Зачем: догоняющее закрытие уже запушенной сессии не должно повторно
# коммитить/пушить. commit-push.sh получил ранний выход, который доказывает
# «всё на remote» по неизменяемому манифесту, а не по слову вызывающего.
# Этот скрипт — единственный писатель такого манифеста.
#
# Двухфазная семантика (консенсус, ход 6): вызывается ПОСЛЕ payload-коммитов
# (report.md и все артефакты сессии уже закоммичены в ветке), ДО isolate-push.
# Манифест = отдельный attest-коммит, содержащий ТОЛЬКО session-manifest.json;
# его собственный OID в `commits` не входит (цикличность снята двухфазностью).
#
# Usage: session-manifest-write.sh <session_worktree> <session_id> [target_branch=main]
# Exit: 0 — attest-коммит создан; 1 — предусловие нарушено (диагностика в stderr).

set -euo pipefail

WORKTREE="${1:-}"
SESSION_ID="${2:-}"
TARGET_BRANCH="${3:-main}"

usage() {
  echo "Использование: session-manifest-write.sh <session_worktree> <session_id> [target_branch]" >&2
  exit 1
}
[ -n "$WORKTREE" ] && [ -n "$SESSION_ID" ] || usage
[ -d "$WORKTREE" ] || { echo "session-manifest-write: нет каталога $WORKTREE" >&2; exit 1; }

MONTH="${SESSION_ID:0:7}"
DAY="${SESSION_ID:8:2}"
# WP-526 Ф2: $WORKTREE is expected to be the MC-sessions checkout now,
# not a DS-strategy worktree -- session content lives at its root
# (the transfer stripped the old sessions/ prefix), not under sessions/.
SESSION_DIR="$WORKTREE/$MONTH/$DAY/$SESSION_ID"
META="$SESSION_DIR/meta.yaml"
REPORT="$SESSION_DIR/report.md"

[ -f "$META" ] || { echo "session-manifest-write: нет $META" >&2; exit 1; }
[ -f "$REPORT" ] || { echo "session-manifest-write: нет $REPORT — payload ещё не готов" >&2; exit 1; }
grep -q "session_id: \"$SESSION_ID\"" "$META" || grep -q "session_id: $SESSION_ID" "$META" \
  || { echo "session-manifest-write: meta.yaml не про эту сессию ($SESSION_ID)" >&2; exit 1; }

# WP-530/537 Ф22 (05.09, ArchGate + холодное ревью): $WORKTREE — общий чекаут
# MC-sessions, разделяемый ВСЕМИ параллельными сессиями (WP-526 Ф2), не
# изолированная копия под эту сессию. Безусловный `git status --porcelain`
# на всё дерево видит грязь ЛЮБОЙ соседней сессии и ложно отказывает в
# закрытии полностью синхронизированной работы — живой симптом РП-537
# «находка 02.09/05.09». Область — только каталог этой сессии; путь
# ($MONTH/$DAY/$SESSION_ID) уникален по конструкции (дата+слаг), поэтому
# сужение pathspec не может случайно захватить чужую работу.
SESSION_PATH="$MONTH/$DAY/$SESSION_ID"
if [ -n "$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH")" ]; then
  echo "session-manifest-write: каталог сессии грязный — сначала закоммить все артефакты сессии" >&2
  git -C "$WORKTREE" status --short -- "$SESSION_PATH" >&2
  exit 1
fi

git -C "$WORKTREE" fetch origin "$TARGET_BRANCH" --quiet 2>/dev/null || true
PAYLOAD_COMMITS=$(git -C "$WORKTREE" rev-list --reverse "origin/$TARGET_BRANCH..HEAD" -- "$SESSION_PATH" 2>/dev/null || echo "")
[ -n "$PAYLOAD_COMMITS" ] || { echo "session-manifest-write: нет payload-коммитов, трогающих каталог сессии (HEAD не опережает origin/$TARGET_BRANCH по $SESSION_PATH)" >&2; exit 1; }

# Cold review (05.09): HEAD может опережать origin коммитами, которые
# $SESSION_PATH не затрагивают, -- манифест их тихо не учитывает, а
# downstream isolate-push доставляет payload именно по patch_ids отсюда.
# Не отказ (это может быть штатный коммит другой параллельной сессии на той
# же общей ветке, не наша забота) -- но видимый warn, а не молчание.
ALL_AHEAD_COUNT=$(git -C "$WORKTREE" rev-list --count "origin/$TARGET_BRANCH..HEAD" 2>/dev/null || echo 0)
SCOPED_AHEAD_COUNT=$(wc -l <<< "$PAYLOAD_COMMITS" | tr -d ' ')
if [ "$ALL_AHEAD_COUNT" -gt "$SCOPED_AHEAD_COUNT" ]; then
  echo "session-manifest-write: WARN -- HEAD опережает origin/$TARGET_BRANCH на $ALL_AHEAD_COUNT коммитов, из них $SCOPED_AHEAD_COUNT трогают $SESSION_PATH; остальные в манифест не войдут (чужая работа на общей ветке или собственный коммит вне каталога сессии)" >&2
fi

REPORT_BLOB=$(git -C "$WORKTREE" hash-object "$MONTH/$DAY/$SESSION_ID/report.md")
REPORT_REL="$MONTH/$DAY/$SESSION_ID/report.md"
MANIFEST_REL="$MONTH/$DAY/$SESSION_ID/session-manifest.json"

# review-01 Critical-3: TOCTOU между проверкой чистоты и коммитом. Весь блок
# «status → write → add → verify → commit» под одним lock-файлом; перед commit
# доказываем, что единственное изменение — сам манифест.
# review-01 Critical-3 + review-02: весь блок «status → write → add → verify →
# commit» под обязательным lock; без рабочего механизма блокировки — fail
# closed (продолжение без сериализации вернуло бы TOCTOU-окно целиком).
# lock-файл — от абсолютного git-common-dir (rev-parse может вернуть
# относительный путь, иначе открытие упадёт при запуске вне $WORKTREE).
GIT_COMMON=$(git -C "$WORKTREE" rev-parse --git-common-dir)
case "$GIT_COMMON" in
  /*) : ;;
  *) GIT_COMMON="$WORKTREE/$GIT_COMMON" ;;
esac
MANIFEST_LOCK="$GIT_COMMON/session-manifest-write.lock"
exec 8>"$MANIFEST_LOCK"
if command -v flock >/dev/null 2>&1; then
  flock 8 || { echo "session-manifest-write: lock $MANIFEST_LOCK не взят — отказ" >&2; exit 1; }
elif command -v shlock >/dev/null 2>&1; then
  shlock -f "$MANIFEST_LOCK.pid" -p $$ || { echo "session-manifest-write: shlock не взят — отказ" >&2; exit 1; }
  trap 'rm -f "$MANIFEST_LOCK.pid"' EXIT
else
  # Последний переносимый механизм: mkdir атомарен на всех целевых ОС.
  if ! mkdir "$MANIFEST_LOCK.d" 2>/dev/null; then
    echo "session-manifest-write: ни flock, ни shlock, ни mkdir-lock недоступны — отказ (fail closed)" >&2
    exit 1
  fi
  trap 'rm -rf "$MANIFEST_LOCK.d"' EXIT
fi

# Повторная проверка внутри критической секции: за окном ожидания lock дерево
# могло измениться. Тот же скоуп сессии, что и первая проверка выше.
if [ -n "$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH")" ]; then
  echo "session-manifest-write: каталог сессии стал грязным к моменту записи — отказ" >&2
  exit 1
fi

python3 - "$SESSION_DIR/session-manifest.json" "$SESSION_ID" "$REPORT_BLOB" "$REPORT_REL" "$WORKTREE" "$PAYLOAD_COMMITS" <<'PYEOF'
import json, sys, time, subprocess
path, session_id, blob, report_rel, worktree, commits = sys.argv[1:7]
oids = commits.split()
# Консенсус ход 7: isolate-push доставляет через cherry-pick, который
# переписывает OID — payload доказывается по стабильному patch-id (контентный
# адрес), OID-проверка остаётся для прямых push.
patch_ids = []
for oid in oids:
    show = subprocess.run(["git", "-C", worktree, "show", oid], capture_output=True, check=True)
    pid = subprocess.run(["git", "-C", worktree, "patch-id", "--stable"], input=show.stdout,
                         capture_output=True, check=True)
    patch_ids.append(pid.stdout.decode().split()[0])
json.dump({
    "session_id": session_id,
    "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "commits": oids,
    "patch_ids": patch_ids,
    "report_path": report_rel,
    "report_blob_sha": blob,
}, open(path, "w"), indent=2, ensure_ascii=False)
PYEOF

git -C "$WORKTREE" add -- "$MANIFEST_REL"

# Доказательство покрытия: staged ровно один путь — манифест; worktree за его
# пределами чист. Иначе удаляем незакоммиченный манифест и падаем.
STAGED=$(git -C "$WORKTREE" diff --cached --name-only)
REST=$(git -C "$WORKTREE" status --porcelain -- "$SESSION_PATH" ":!$MANIFEST_REL")
if [ "$STAGED" != "$MANIFEST_REL" ] || [ -n "$REST" ]; then
  git -C "$WORKTREE" reset -q -- "$MANIFEST_REL" 2>/dev/null || true
  rm -f "$SESSION_DIR/session-manifest.json"
  echo "session-manifest-write: к моменту коммита изменилось что-то кроме манифеста — манифест удалён, отказ" >&2
  exit 1
fi

git -C "$WORKTREE" commit -q -m "chore(session): attest manifest $SESSION_ID" -- "$MANIFEST_REL"

# Этот коммит идёт напрямую через git, не через Write/Edit, поэтому scope
# gate session-guard не увидит путь без явной регистрации. `--slug` без
# `--wp` достаточно (select_semaphore резолвит по слагу). Не роняем сам
# attest при отказе note-file -- коммит уже сделан, откат хуже предупреждения.
# Путь -- абсолютный ($SESSION_DIR, не относительный $MANIFEST_REL): note-file
# резолвит репозиторий по cwd, когда путь относительный, а cwd вызывающего
# скрипт процесса не обязан совпадать с $WORKTREE.
GUARD="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
[ -x "$GUARD" ] || GUARD="$HOME/IWE/scripts/session-guard.sh"
if ! NOTE_ERR=$(bash "$GUARD" note-file "$SESSION_DIR/session-manifest.json" --slug "$SESSION_ID" 2>&1); then
  echo "session-manifest-write: WARN -- note-file для $MANIFEST_REL не прошёл ($NOTE_ERR); attest-коммит сделан, но close откажет без повторной регистрации" >&2
fi

echo "session-manifest-write: attest-коммит создан ($MANIFEST_REL, payload: $(echo "$PAYLOAD_COMMITS" | wc -l | tr -d ' ') коммитов) — дальше isolate-push"
