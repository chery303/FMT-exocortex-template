# Template: _template (skeleton)

> Скопируй этот файл, переименуй в `<kind>.md`, заполни параметры и acceptance.

## Frontmatter для task-файла

```yaml
---
id: TASK-YYYY-MM-DD-<slug>
kind: <kind>                         # одно из: analyze | scout | evolution | soak | retro | research | publish
status: pending
priority: P2                         # P0=critical, P1=high, P2=medium, P3=low
agent: ccr-opus                      # ccr-opus | ccr-sonnet | remote-systemd | local-launchd
template: <name>                     # имя файла в templates/ без .md
created: YYYY-MM-DDTHH:MM:SS+03:00
due: YYYY-MM-DDTHH:MM:SS+03:00
wp: NNN                              # опционально — связь с РП
result_location:
  repo: <repo-name>
  branch: main
  path: <path/to/artifact.md>
acceptance:
  - <условие 1>
  - <условие 2>
params:
  <key>: <value>
---
```

## Промпт (передаётся агенту)

```
{{header}}

## Задача
{{task_description}}

## Контекст
{{context}}

## Шаги
1. {{step1}}
2. {{step2}}
...

## Acceptance
- Сохранить результат: `{{result_location.repo}}/{{result_location.branch}}/{{result_location.path}}`
- Все пункты из task.acceptance должны быть выполнены.

## Failure modes (НЕ silent succeed)
- Если `{{step_critical}}` не удалось → `status: failed`, объясни причину в чате
- Если push в `{{result_location.branch}}` не прошёл → `status: failed`, **не делай fallback в другую ветку/PR**
- Если acceptance частично выполнен → `status: partial`, перечисли что сделано / не сделано
```

## Acceptance template

```yaml
acceptance:
  - "Файл существует в `{{result_location}}`"
  - "Frontmatter валиден (yq parse passes)"
  - "Все пункты задачи отмечены ✓/✗ с обоснованием"
```
