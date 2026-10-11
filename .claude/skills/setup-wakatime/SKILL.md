---
name: setup-wakatime
description: Set up WakaTime time-tracking for Claude Code and VS Code.
user_invocable: true
browser_safe: false
routing:
  executor: sonnet
  deterministic: false
---

# Setup WakaTime Time Tracking

Автоматическая настройка WakaTime для отслеживания рабочего времени.

## Что устанавливается

1. **wakatime-cli** — CLI для отправки heartbeat'ов
2. **Хук Claude Code** — автоматический трекинг при работе с Claude (категория "AI Coding")
3. **WakaTime Desktop App** (опционально) — трекинг фокуса окна (чтение, браузер)

## Инструкция для Claude

Выполни шаги последовательно. На каждом шаге проверяй, не сделано ли уже.

### Шаг 1: wakatime-cli

```bash
# Проверить наличие
~/.wakatime/wakatime-cli --version 2>/dev/null || wakatime-cli --version 2>/dev/null
```

Если не установлен:
```bash
brew install wakatime-cli
mkdir -p ~/.wakatime
ln -sf $(which wakatime-cli) ~/.wakatime/wakatime-cli
```

### Шаг 2: API Key

```bash
cat ~/.wakatime.cfg 2>/dev/null
```

Если файл не существует или нет `api_key`:
1. Скажи пользователю: «Нужен WakaTime API-ключ. Получи его на https://wakatime.com/settings/api-key (нужна регистрация). Вставь ключ сюда.»
2. Дождись ответа
3. Запиши:
```bash
# ~/.wakatime.cfg
[settings]
api_key = <ключ от пользователя>
```

### Шаг 3: Хук-скрипт

Этот хук не входит в поставку шаблона (снят с платформы в v0.34 — user-installed hook only, issue #215): создай файл напрямую с этим содержимым, не копируй из репозитория.
```bash
mkdir -p ~/.claude/hooks
cat > ~/.claude/hooks/wakatime-heartbeat.sh << 'EOF'
#!/bin/bash
# Claude Code → WakaTime heartbeat hook
# Sends heartbeats to track AI coding time per project.
# Events: UserPromptSubmit, PostToolUse, Stop

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Detect project from git or folder name
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  PROJECT=$(cd "$CWD" && git config --local remote.origin.url 2>/dev/null | sed 's#.*/\([^.]*\)#\1#;s#\.git$##')
  PROJECT=${PROJECT:-$(basename "$CWD")}
else
  PROJECT="Unknown"
fi

# Category based on event/tool
CATEGORY="ai coding"
if [ "$EVENT" = "PostToolUse" ]; then
  case "$TOOL" in
    WebSearch|WebFetch) CATEGORY="researching" ;;
    Read|Grep|Glob)    CATEGORY="code reviewing" ;;
    Edit|Write)        CATEGORY="coding" ;;
  esac
fi

# Send heartbeat in background (non-blocking, silent)
(~/.wakatime/wakatime-cli \
  --entity-type app \
  --entity "Claude Code" \
  --category "$CATEGORY" \
  --project "$PROJECT" \
  --plugin "claude-code-wakatime/0.1.0" \
  --write \
  >/dev/null 2>&1 &)

exit 0
EOF
chmod +x ~/.claude/hooks/wakatime-heartbeat.sh
```

### Шаг 4: Настройка хуков в settings.json

Прочитай `~/.claude/settings.json`. Добавь в секцию `hooks` (не затирая существующие хуки):

- **UserPromptSubmit** — добавь hook group:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh"}]}
  ```
- **PostToolUse** — добавь:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh", "async": true}]}
  ```
- **Stop** — добавь:
  ```json
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/wakatime-heartbeat.sh", "async": true}]}
  ```

### Шаг 5: WakaTime Desktop App (спроси пользователя)

Спроси: «Установить WakaTime Desktop App? Он трекает время фокуса окна (когда читаешь ответы, работаешь в браузере). Требует Accessibility-разрешение в macOS.»

Если да:
```bash
brew install --cask wakatime
open -a WakaTime
```
Скажи: «Разреши Accessibility доступ в System Settings → Privacy & Security → Accessibility.»

### Шаг 6: Тест

```bash
echo '{"cwd": "'$(pwd)'", "hook_event_name": "UserPromptSubmit", "prompt": "test"}' | ~/.claude/hooks/wakatime-heartbeat.sh
sleep 3
~/.wakatime/wakatime-cli --today
```

Покажи результат пользователю. Скажи: «Хуки подхватятся при следующем запуске Claude Code (хуки загружаются при старте сессии).»

### Шаг 7: Итог

Покажи таблицу:

| Компонент | Статус |
|-----------|--------|
| wakatime-cli | ✅/❌ |
| API key | ✅/❌ |
| Хук-скрипт | ✅/❌ |
| Хуки в settings.json | ✅/❌ |
| Desktop App | ✅/❌/пропущен |
| Тест heartbeat | ✅/❌ |

Скажи: «Дашборд: https://wakatime.com/dashboard. Данные появятся через 5-15 минут.»
