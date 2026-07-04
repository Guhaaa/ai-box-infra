# ai-box-infra — правила для AI-агентов

## Язык

- Отвечай и пиши комментарии по-русски.

## Что это за репозиторий

Shared-инфраструктура экосистемы AiBox: docker-compose стека (nginx+TLS,
MariaDB, Redis, Qdrant, browserless), базовый PHP-образ, nginx-шаблоны,
runbook'и переездов. Кода приложений здесь нет — только инфраструктура.
Обзор — `README.md`, дизайн — `docs/superpowers/specs/`, процедуры —
`docs/runbooks/`.

## Рабочий процесс

- В репозитории ведётся вика (`.claude/wiki/`) — перед задачей и по ходу
  изменений действуй по `.claude/rules/wiki.md`.
- Конфиги валидируются перед коммитом: `docker compose config --quiet`
  (со всеми overlay-файлами и заполненным окружением), nginx-шаблоны —
  рендером в контейнере (`nginx -t`, см. runbook'и).
- Изменения контрактов (имена контейнеров, порты, DB-индексы Redis, пути
  кода) согласовывай с README и app-репозиториями — контракты используют
  ai-box, ai-box-data-registry, ai-box-mcp, pdn-cleaner, ollama-router.
- Conventional Commits на русском: `<type>(<scope>): <описание>`.
  Без Co-Authored-By.
- Боевые операции (addons.amulex.ru) — только по runbook'ам из
  `docs/runbooks/` и с явного разрешения человека.

## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Память

В проекте параллельно работают две системы памяти. Чтобы не дублировать
и не конфликтовать, разделяй по **назначению** знания:

- **`bd remember`** (beads) — **проектное** знание, относящееся к этому
  репозиторию: гочи реализации, технические нюансы, ссылки на
  shared-системы (Jira, GitLab, дашборды), командные конвенции, не
  дотянувшиеся до `CLAUDE.md` или `.claude/wiki/`. Видно через
  `bd prime` в каждой сессии Claude Code в этом репо.
- **Claude auto-memory** (`~/.claude/projects/.../memory/`) — **личное**
  знание текущего разработчика: профиль (`user`), личные предпочтения
  общения (`feedback`). Не пиши сюда проектные команды и shared-ссылки
  — это в `bd remember`.

Если знание спорное (личное или общекомандное?) — спроси.

Уточнение к правилу из секции «Beads Issue Tracker» выше («do NOT use
MEMORY.md files»): оно касается **проектного** persistent knowledge —
оно идёт в `bd remember`. Claude auto-memory остаётся в силе как
канал **только** для личного знания.

### Замечание про репликацию `bd remember`

`bd remember` хранится в локальной Dolt-БД (`.beads/embeddeddolt/`).
**По умолчанию канал локальный** — записи живут только на машине того
разработчика, кто их сделал. Для шаринга между клонами нужно настроить
Dolt-репликацию: `bd dolt remote add` (DoltHub или self-hosted Dolt
sql-server) либо опция `backup.git-push` в комбинации с
`bd backup init`. Это инфраструктурное решение проекта.

Политика выше **работает в обоих режимах**: при включении репликации
запись в `bd remember` автоматически становится shared для всех клонов;
без репликации канал остаётся локально-проектным (но всё равно по
назначению — про этот репозиторий, не про разработчика лично). Если
репликация в проекте не настроена сознательно — зафиксируй это
отдельной страницей в `.claude/wiki/decisions/` с trade-off'ами,
чтобы в новой сессии агент не предлагал это «исправить».
