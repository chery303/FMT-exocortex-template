---
id: DP.ROLE.NNN
name: Agent Task Dispatcher
type: role-description
status: draft
valid_from: YYYY-MM-DD
summary: "Координатор очереди агентных задач IWE: читает inbox/agent/tasks/, запускает через подходящий канал (CCR / systemd / local), фиксирует lifecycle и audit-trail."
related:
  specializes: [U.RoleAssignment]
  component_of: [DP.ROLE.001]
  realizes: [DP.SC.NNN]   # Agent Inbox service clause
  uses:
    - DP.ROLE.NNN        # Notification Dispatcher — уведомление пилота о P0-failed
    - inbox/agent/       # task/result хранилище
  downstream_consumers:
    - DP.ROLE.001 IWE Creator — пилот видит status pending tasks и забирает results
    - Scout — пишет findings + auto-promotes в tasks/ для P0
created: YYYY-MM-DD
updated: YYYY-MM-DD
---

<!--
ШАБЛОН (FMT-exocortex-template/pack-templates/).

Это перенос роли из авторского Pack (WP-324, 17 мая 2026).
При адаптации в свой Pack:
1. Заменить `DP.ROLE.NNN` на следующий свободный номер ролей в твоём Pack
2. Заменить `DP.SC.NNN` на номер своего Agent Inbox service clause
3. Подставить `created` / `updated` / `valid_from` на сегодняшнюю дату
4. Удалить этот HTML-комментарий перед коммитом
-->

# Agent Task Dispatcher — DP.ROLE.NNN

> # see DP.SC.NNN, DP.ROLE.NNN
>
> **Kind:** Coordinator Role — управляет очередью, не выполняет содержательную работу.
> **Owner Role:** IWE Platform — исполнитель: dispatcher (CCR-рутина / systemd timer на собственном сервере / launchd на mac) + Scout sweeper.

---

## 1. Миссия

Гарантировать, что задача, поставленная агенту в `inbox/agent/tasks/`, запускается вовремя через подходящий канал, и что её результат фиксируется однозначно — в декларированной точке (`result_location`).

Аналогия: диспетчер таксопарка. Не везёт пассажиров, не выбирает маршрут — только сводит заказ с водителем, отслеживает выполнение, фиксирует факт доставки.

**Граница:** Dispatcher не разбирает содержание промпта, не выбирает branch для коммита, не интерпретирует acceptance. Все эти решения уже сделаны в task-файле (пилотом или предыдущим агентом).

---

## 2. Обязанности

| Обязанность | Как выполняется |
|-------------|----------------|
| Читать pending task'и | `git pull --rebase` в локальном клоне `{{GOVERNANCE_REPO}}` + `find inbox/agent/tasks -name '*.md'` |
| Парсить frontmatter | yq / python yaml parser |
| Фильтровать: `status: pending` AND `due ≤ now()` | python list comprehension |
| Сортировать по `priority` | P0 → P1 → P2 → P3 |
| Подставлять параметры в template | jinja2-like substitution `{{var}}` |
| Запускать через канал | `agent: claude-cli` → `claude -p` headless; `agent: ccr-opus` → `RemoteTrigger create`; `agent: remote-systemd` → `systemd-run`; `agent: local-launchd` → osascript |
| Записывать `trigger_id` + `status: assigned` | git Edit + commit + push |
| Проверять acceptance | acceptance-check скрипт (часть dispatcher impl) |
| Создавать result-файл | Write `RESULT-<task-id>.md` + git commit |
| При P0-failed — нотифицировать | через DP.ROLE.NNN (Notification Dispatcher) → Telegram |
| Архивировать >7 дней | Scout sweeper: `mv tasks/X.md archive/YYYY/` + соответствующий result |
| Cleanup stale assigned (>2h) | Scout sweeper: `status: assigned → pending` или `failed` |

---

## 3. Входы / Выходы

**Входы (от потребителей):**
- `inbox/agent/tasks/TASK-*.md` — поставленные task'и (от пилота или peer-агента).

**Выходы:**
- `inbox/agent/tasks/TASK-*.md` — обновлённые frontmatter (status, trigger_id, completed_at).
- `inbox/agent/results/RESULT-*.md` — артефакты + audit-trail.
- `inbox/agent/archive/YYYY/` — закрытые task'и через 7 дней.
- `inbox/agent/scout/YYYY-MM-DD.md` — Scout findings (написаны Scout-агентом, dispatcher только координирует).
- Telegram сообщения пилоту (через Notification Dispatcher) при P0-failed.

**Артефакты в git:**

| Файл / папка | Что пишет |
|--------------|-----------|
| `inbox/agent/tasks/*.md` | Frontmatter updates (status, trigger_id) |
| `inbox/agent/results/RESULT-*.md` | Создание новых result-файлов |
| `inbox/agent/archive/YYYY/` | Move старых tasks+results |
| `/tmp/iwe-agent-dispatcher.lock` или эквивалент | Lock-файл (50 min TTL) |
| `~/IWE/scripts/logs/iwe-agent-dispatcher-YYYY-MM-DD.log` | Журнал циклов |

---

## 4. Архитектура (слои)

```
Постановщики task'ов
├── DP.ROLE.001 IWE Creator (пилот)    ← Write tasks/TASK-*.md + git push
└── Scout (auto-promote P0)            ← Write tasks/TASK-*.md внутри своего цикла
        │
        ▼
DP.ROLE.NNN Dispatcher
├── Reader        → git pull --rebase + parse frontmatter
├── Filter        → status==pending AND due<=now
├── Sorter        → by priority P0..P3
├── Template      → substitute {{vars}} from task body
├── Launcher      → switch by agent: → channel-specific call
│     ├── claude CLI headless (`claude -p`)
│     ├── RemoteTrigger create (CCR)
│     ├── ssh + systemd-run (внешний сервер)
│     └── osascript + launchctl (local mac)
├── Watcher       → status check (по каналу: log scan / RemoteTrigger get / journalctl)
├── Acceptance    → проверить result_location
└── Archiver      → 7d → archive/YYYY/

Каналы выполнения
├── claude CLI headless (любая машина с установленным CLI)
├── claude.ai CCR (RemoteTrigger) — для tasks с MCP-коннекторами
├── systemd на собственном сервере
└── local-launchd (mac)

Уведомления
└── DP.ROLE.NNN Notification Dispatcher → Telegram (только P0-failed)
```

---

## 5. Ограничения (инварианты роли)

1. **Single source of truth — task-файл.** Dispatcher не хранит state отдельно. Один pull governance-repo → полный recovery после рестарта.
2. **No fallback в выборе места.** `result_location` задан → агент пишет ровно туда, dispatcher проверяет ровно там. Если недоступно — failed, не silent push в другое место.
3. **Lock-based concurrency.** Два параллельных dispatcher не запускаются. Lock-файл с TTL 50 мин; при истечении — следующий dispatcher cleanup'ает и работает.
4. **No bash injection.** Dispatcher не выполняет произвольный bash из task body — только через template substitution + предусмотренный канал.
5. **Idempotency на task_id.** Повторный запуск dispatcher для уже `assigned` task — no-op (только проверяет status, не создаёт новый).
6. **Audit-trail обязателен.** Каждое изменение статуса = git commit с осмысленным message (`dispatch(WP-NNN): TASK-X pending→assigned via <channel>`).

---

## 6. Связи с другими ролями

| Роль | Отношение |
|------|-----------|
| DP.ROLE.001 IWE Creator | Главный постановщик task'ов |
| DP.ROLE.NNN Notification Dispatcher | Потребитель Dispatcher'а: при P0-failed → send_telegram_message |
| DP.ROLE.NNN Artifactor | Источник task'ов: при появлении новой РП open-loop ≥3h может предложить разбиение через template `task: artifactor-stages` |
| DP.ROLE.NNN Навигатор | Источник task'ов: может ставить «retro по неделе» через template `retro` |

---

## 7. Точки входа (интерфейсы)

### Постановка task'а (для постановщика)

```bash
# 1. Скопировать шаблон
cp inbox/agent/templates/analyze-section.md \
   inbox/agent/tasks/TASK-YYYY-MM-DD-analyze-section-NN.md

# 2. Заполнить frontmatter и параметры

# 3. git push
git add inbox/agent/tasks/
git commit -m "task: analyze section NN"
git push
```

### Dispatcher cycle (псевдокод)

```python
def dispatcher_cycle():
    if lock_held_within_50min(): return
    acquire_lock()
    try:
        git_pull_rebase(governance_repo)
        tasks = parse_tasks(governance_repo / "inbox/agent/tasks/")

        # Этап 1: запустить pending+due
        for task in sorted(filter(is_pending_and_due, tasks), key=lambda t: t.priority):
            template = load_template(task.template)
            prompt = substitute(template, task.params)
            trigger_id = launch_by_channel(prompt, agent=task.agent)
            task.trigger_id = trigger_id
            task.status = "assigned"
            git_commit_one_task(task)

        # Этап 2: проверить assigned
        for task in filter(is_assigned, tasks):
            status = check_status(task.trigger_id, channel=task.agent)
            if status == "done":
                ok = check_acceptance(task)
                task.status = "completed" if ok else "failed"
                write_result_file(task)
                if task.priority == "P0" and not ok:
                    notify_pilot(task)
                git_commit_one_task(task)

        git_push()
    finally:
        release_lock()
```

### Watcher / Sweeper (Scout daily)

```python
def sweep_stale_assigned(repo_path):
    for task in find_assigned(repo_path):
        if hours_since(task.assigned_at) > 2:
            status = check_status(task.trigger_id, channel=task.agent)
            if status == "running":
                continue
            elif status == "done":
                ok = check_acceptance(task)
                task.status = "completed" if ok else "failed"
            else:
                task.status = "pending"  # вернуть в очередь
```

---

## 8. Метрики

| Метрика | Норма | Где брать |
|---------|-------|-----------|
| Median lag (due → run start) | ≤30 мин | git log + dispatcher metadata |
| % failed из общего | ≤10% | scan results/ |
| Pending count > 5 одновременно | редко (раз в неделю) | live count в результате dispatcher cycle |
| Stale assigned (>2h) | 0 после Scout sweeper | результат sweeper |
| Cost (USD/неделя) | < $30 для пилотной нагрузки | dispatcher metadata aggregate |

---

## 9. Открытые вопросы (для пересмотра после первой недели)

1. **Throttle по cost.** При cost > N$/день — приоритет только P0. Где порог?
2. **Auto-archive >7d.** Достаточно ли 7 дней? Может, 14?
3. **Template versioning.** Если template меняется — старые task'и используют старый или новый? Сейчас — новый (substitute at dispatcher time). Возможен conflict.
4. **Peer-coordination.** Если два peer-агента одновременно пишут task на одну тему — нужна dedup-логика. Сейчас полагаемся на git merge.

---

## Заметки для адаптации

**Выбор канала запуска:**

| Канал | Когда | Плюсы | Минусы |
|-------|-------|-------|--------|
| `claude` CLI headless (`claude -p`) | Базовый канал для собственного сервера | Не зависит от CCR API; работает локально; полный контроль | Нужен собственный сервер с claude CLI |
| RemoteTrigger (CCR) | Когда нужны MCP-коннекторы (Gmail/Calendar/IWE) | Готовая инфраструктура claude.ai; MCP из коробки | Зависимость от API claude.ai (v1→v2 transition подвержена сбоям) |
| systemd на внешнем сервере | Heavy workloads, нужен root/sudo | Полный контроль среды | Нужен сервер |
| local-launchd (mac) | Лёгкие задачи на основной машине | Дёшево, всегда под рукой | Завязка на конкретный ноутбук |

**Минимальная конфигурация для одного пилота:** один канал `claude` CLI headless на любой машине с установленным `claude` (mac/linux/wsl). Покрывает 80% задач.
