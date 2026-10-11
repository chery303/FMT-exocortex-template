# Template: scout-daily

> Дневная разведка медленных источников (требующих LLM-анализа), комплементарная к локальному overnight-scout.

## Параметры (params)

| Параметр | Тип | Пример |
|----------|-----|--------|
| `date` | date | 2026-05-17 |
| `focus_areas` | list | [platform, content, community, world, iwe] |
| `sources` | list | github_repos, twitter_handles, hn_threads, telegram_channels |
| `result_repo` | str | `{{GOVERNANCE_ORG}}/{{GOVERNANCE_REPO}}` |

## Промпт

```
Ты агент-разведчик. За последние 24 часа найди значимые сигналы из медленных источников.

## Фокус-области ({{focus_areas}})

- **platform** — что нового в нашей инфраструктуре (PR'ы, deploy, инциденты)
- **content** — релевантные публикации (LongReads, AI news, систематология)
- **community** — что обсуждают пользователи, в чём затруднения
- **world** — геополитика/экономика (только если влияет на R1-R6)
- **iwe** — претензии к IWE, фича-запросы, баги

## Шаги

1. Для каждой `source` — прочитать новые материалы за последние 24h.
2. Отфильтровать: шум → выкинуть; релевантное → сохранить с цитатой.
3. Классифицировать findings по `priority`: P0 (action required <24h), P1 (note), P2 (ignore for now).
4. Для каждого P0 — предложить task для постановки в Agent Inbox.

## Шаг 5: Запиши результат

Путь: `{{result_repo}}/inbox/agent/scout/{{date}}.md`

Структура:
```
---
date: {{date}}
generated_by: ccr-scout
findings_count:
  P0: N
  P1: M
  P2: K
---

# Scout {{date}}

## Platform
- [P1] <короткое описание> | <ссылка> | действие: <что предлагаешь>

## Content
- [P2] ...

## Community
- [P0] ...

## World
- ...

## IWE
- ...

## Auto-promoted tasks (P0)

Если хотя бы один P0 → создай task-файл:

`{{result_repo}}/inbox/agent/tasks/TASK-{{date}}-<slug>.md`

Со status: pending, priority: P0, agent: ccr-sonnet (или ccr-opus для сложных).
```

## Шаг 6: Commit + push

```bash
cd /path/to/{{result_repo}}
git add inbox/agent/scout/{{date}}.md inbox/agent/tasks/TASK-*.md
git commit -m "scout({{date}}): findings + auto-promoted P0 tasks"
git push
```

## Failure modes

- Источник недоступен → пропустить, отметить в результате «source <name> unavailable».
- Нет findings → создать файл с `findings_count: 0` (важно — Day Open читает наличие файла).
- git push fail → status: failed, не fallback в feature branch.

## Acceptance

- Файл `inbox/agent/scout/{{date}}.md` существует на main.
- Содержит секции по всем `focus_areas`.
- Если P0 > 0 → созданы task-файлы в `tasks/`.
```
