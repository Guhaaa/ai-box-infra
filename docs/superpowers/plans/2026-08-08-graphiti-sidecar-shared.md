# Перенос graphiti-sidecar в shared-стек — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Сервис `graphiti-sidecar` в docker-compose.yml инфры (build из checkout'а DR), env-per-stend, README-контракты и вика — по спеке `docs/superpowers/specs/2026-08-08-graphiti-sidecar-shared-design.md`.

**Architecture:** Один новый сервис в существующем `docker-compose.yml` (рядом с `neo4j`), образ собирается инфрой из `${APPS_ROOT}/ai-box-data-registry/sidecar/graphiti` (`build:` + `image: aibox/graphiti-sidecar`). Сборка вшивается в цель `up` через `--build`. Значения — через слои `env/<стенд>/config.env`; новых секретов нет.

**Tech Stack:** docker compose, GNU make, markdown (README/вика), beads (`bd`).

## Global Constraints

- Язык комментариев, документации, коммитов — русский. Conventional Commits: `<type>(<scope>): <описание>`, БЕЗ Co-Authored-By.
- Рабочая директория — `/var/www/html/ai-box-infra`; `cd` не использовать (Bash стартует в ней).
- Имя сервиса `graphiti-sidecar` — DNS-контракт потребителей (`http://graphiti-sidecar:8000`), менять нельзя.
- Валидация каждой правки compose/env: `make config` (стенд local, exit 0).
- git-хук может печатать предупреждение «изменения кода без правок вики» на промежуточных коммитах — это нормально: вика обновляется задачей 5 в той же ветке.
- Не пушить. Только локальные коммиты в master этого репозитория.

---

### Task 1: Сервис graphiti-sidecar в docker-compose.yml + `--build` в цели `up`

**Files:**
- Modify: `docker-compose.yml` (после сервиса `neo4j`, строки ~160-187; перед комментарием сервиса `landing-php`)
- Modify: `Makefile` (цель `up`, строки ~72-75)

**Interfaces:**
- Produces: сервис compose `graphiti-sidecar` (env-переменные `GRAPHITI_*`, которые задача 2 раскладывает по стендам); цель `make up`, собирающая образ `aibox/graphiti-sidecar`.

- [ ] **Step 1: Вставить сервис в docker-compose.yml**

В `docker-compose.yml` сразу ПОСЛЕ блока сервиса `neo4j` (он заканчивается строками `networks:\n      - ecosystem` перед комментарием `# php-fpm обработчика контактной формы лендинга`) вставить:

```yaml

  # Graphiti-сайдкар — shared-сервис графового инжеста/поиска поверх neo4j
  # (эпик ai-box-dr-v18). Код живёт в репозитории ai-box-data-registry
  # (sidecar/graphiti), образ собирает ЭТОТ стек — релизный цикл сайдкара
  # отвязан от релизов DR (у сайдкара два потребителя: реестр и корпоративная
  # вики, релизы DR не должны давать окон недоступности инжеста вики).
  # Потребители ходят по сети ecosystem на http://graphiti-sidecar:8000.
  graphiti-sidecar:
    build: ${APPS_ROOT:-/var/www}/ai-box-data-registry/sidecar/graphiti
    image: aibox/graphiti-sidecar
    container_name: infra_graphiti
    restart: unless-stopped
    depends_on:
      - neo4j
    environment:
      NEO4J_URI: bolt://neo4j:7687
      NEO4J_USER: neo4j
      NEO4J_PASSWORD: ${NEO4J_PASSWORD:?}
      # Канонический LLM-путь — внутренний OpenAI-совместимый прокси ai-box
      # (gateway:8085/api/internal/llm/v1, спека ai-box-back-pssf); он
      # игнорирует Authorization, поэтому дефолт ключей — заглушка internal.
      # Пустым ключ быть НЕ может: graphiti-core создаёт эмбеддер уже на
      # старте и пустой ключ роняет контейнер в краш-луп. Реальные ключи
      # (прямой внешний провайдер) — через env/<стенд>/secrets.env.
      LLM_BASE_URL: ${GRAPHITI_LLM_BASE_URL:-}
      LLM_API_KEY: ${GRAPHITI_LLM_API_KEY:-internal}
      EMBEDDER_BASE_URL: ${GRAPHITI_EMBEDDER_BASE_URL:-}
      EMBEDDER_API_KEY: ${GRAPHITI_EMBEDDER_API_KEY:-internal}
      # Коды моделей — из каталога llm_models ai-box (kind=chat/embedding).
      # Дефолты пустые НАМЕРЕННО (а не gpt-4o-mini, как было в compose DR):
      # молчаливый OpenAI-дефолт при работе через прокси дал бы 422
      # MODEL_NOT_FOUND; незаполненный стенд должен падать громко на первом
      # вызове (сам сайдкар при этом стартует — модель уходит в тело запроса).
      DEFAULT_MODEL: ${GRAPHITI_DEFAULT_MODEL:-}
      DEFAULT_EMBEDDING_MODEL: ${GRAPHITI_DEFAULT_EMBEDDING_MODEL:-}
      DEFAULT_EMBEDDING_DIM: ${GRAPHITI_DEFAULT_EMBEDDING_DIM:-1536}
      SEMAPHORE_LIMIT: ${GRAPHITI_SEMAPHORE_LIMIT:-10}
      KNOWN_CONSUMERS: ${GRAPHITI_KNOWN_CONSUMERS:-dr,wiki}
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request;urllib.request.urlopen('http://localhost:8000/healthz')\" || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks:
      - ecosystem
```

Порты наружу/на loopback НЕ публиковать (потребители — только по сети `ecosystem`; диагностика — `docker exec`).

- [ ] **Step 2: `--build` в цели `up` Makefile**

В `Makefile` заменить:

```make
# neo4j-plugins — предшаг: host-каталог neo4j/plugins должен быть пополнён
# до старта контейнера neo4j (иначе GDS не загрузится, поймает neo4j-smoke).
up: neo4j-plugins
	$(COMPOSE) up -d
```

на:

```make
# neo4j-plugins — предшаг: host-каталог neo4j/plugins должен быть пополнён
# до старта контейнера neo4j (иначе GDS не загрузится, поймает neo4j-smoke).
# --build пересобирает ТОЛЬКО сервисы с ключом build: — это ровно
# graphiti-sidecar (образ из checkout'а ai-box-data-registry по ${APPS_ROOT};
# checkout обязан существовать на стенде). Слои pip кэшируются — пересборка
# без изменений кода сайдкара занимает секунды.
up: neo4j-plugins
	$(COMPOSE) up -d --build
```

- [ ] **Step 3: Валидация рендера compose**

Run: `make config`
Expected: печатает `[stand] local (env/local + …)` и exit 0. Если упало на `NEO4J_PASSWORD` — проверить, что запуск идёт на машине с заполненным `env/local/secrets.env` (it11 — заполнен).

- [ ] **Step 4: Сборка образа**

Run: `docker compose --env-file env/local/config.env --env-file env/local/secrets.env build graphiti-sidecar`
Expected: exit 0, в конце `docker image ls aibox/graphiti-sidecar` показывает образ. Build-контекст — `/var/www/html/ai-box-data-registry/sidecar/graphiti` (APPS_ROOT local = `/var/www/html`).

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml Makefile
git commit -m "feat(compose): graphiti-sidecar как shared-сервис рядом с neo4j"
```

---

### Task 2: Env-слои стендов

**Files:**
- Modify: `env/example/config.env` (дописать блок в конец файла)
- Modify: `env/example/secrets.env` (дописать блок в конец файла)
- Modify: `env/doitai/config.env` (дописать блок в конец файла)
- Modify: `env/local/config.env` (дописать блок в конец файла)

**Interfaces:**
- Consumes: переменные `GRAPHITI_*` из сервиса compose (задача 1).
- Produces: заполненные слои; `env/doitai` — с пустыми кодами моделей до посадки `ai-box-back-pssf`.

- [ ] **Step 1: env/example/config.env — документация блока**

В конец `env/example/config.env` дописать:

```
# Graphiti-сайдкар (shared-сервис графового инжеста; образ собирается из
# ${APPS_ROOT}/ai-box-data-registry/sidecar/graphiti — checkout DR обязан
# существовать на стенде). Канонический LLM-путь — внутренний
# OpenAI-совместимый прокси ai-box (тарификация чата по каталогу llm_models,
# эмбеддинги через Ollama бесплатно). Ключи при прокси не нужны —
# дефолт-заглушка internal уже в compose (Authorization прокси игнорирует);
# при прямом внешнем провайдере base_url провайдера сюда, а РЕАЛЬНЫЕ ключи —
# в secrets.env, не здесь.
#GRAPHITI_LLM_BASE_URL=http://gateway:8085/api/internal/llm/v1
#GRAPHITI_EMBEDDER_BASE_URL=http://gateway:8085/api/internal/llm/v1
# Коды моделей — из каталога llm_models ai-box (kind=chat / kind=embedding);
# размерность — по выбранной эмбеддинг-модели (bge-m3 → 1024).
#GRAPHITI_DEFAULT_MODEL=
#GRAPHITI_DEFAULT_EMBEDDING_MODEL=
#GRAPHITI_DEFAULT_EMBEDDING_DIM=1536
#GRAPHITI_SEMAPHORE_LIMIT=10
#GRAPHITI_KNOWN_CONSUMERS=dr,wiki
```

- [ ] **Step 2: env/example/secrets.env — комментарий про реальные ключи**

В конец `env/example/secrets.env` дописать:

```
# LLM-ключи Graphiti-сайдкара нужны ТОЛЬКО при прямом внешнем провайдере
# (base_url в config.env указывает не на прокси gateway:8085) — тогда:
# GRAPHITI_LLM_API_KEY=
# GRAPHITI_EMBEDDER_API_KEY=
# При прокси не задавать вовсе: в compose дефолт-заглушка internal.
```

(Именно комментарием, не пустыми ключами: пустое значение переопределило бы дефолт-заглушку compose и уронило сайдкар в краш-луп на старте.)

- [ ] **Step 3: env/doitai/config.env — рабочие значения**

В конец `env/doitai/config.env` дописать:

```
# Graphiti-сайдкар: LLM-путь — внутренний прокси ai-box (спека
# ai-box-back-pssf). Ключи не задаём — заглушка internal в compose
# (Authorization прокси игнорирует).
GRAPHITI_LLM_BASE_URL=http://gateway:8085/api/internal/llm/v1
GRAPHITI_EMBEDDER_BASE_URL=http://gateway:8085/api/internal/llm/v1
# Коды моделей каталога llm_models — вписать ПОСЛЕ посадки ai-box-back-pssf
# (миграция pssf сеет эмбеддинг-модели; чат — существующий каталожный код).
# Пусто = сайдкар стартует, но инжест падает громко (422 у прокси) до
# заполнения. Размерность выставить по выбранной эмбеддинг-модели
# (bge-m3 → 1024).
GRAPHITI_DEFAULT_MODEL=
GRAPHITI_DEFAULT_EMBEDDING_MODEL=
GRAPHITI_DEFAULT_EMBEDDING_DIM=1024
```

- [ ] **Step 4: env/local/config.env — dev-стенд**

В конец `env/local/config.env` дописать:

```
# Graphiti-сайдкар: тот же прокси-путь, что на doitai (eco-стек it11 несёт
# internal-ai-box.conf, gateway:8085 резолвится). Коды моделей на dev не
# заполнены — сайдкар стартует, инжест до заполнения падает громко.
GRAPHITI_LLM_BASE_URL=http://gateway:8085/api/internal/llm/v1
GRAPHITI_EMBEDDER_BASE_URL=http://gateway:8085/api/internal/llm/v1
```

- [ ] **Step 5: Валидация**

Run: `make config`
Expected: `[stand] local …`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add env/example/config.env env/example/secrets.env env/doitai/config.env env/local/config.env
git commit -m "feat(env): GRAPHITI_* по стендам (example, doitai, local)"
```

---

### Task 3: Подъём на local-стенде и healthcheck

**Files:** нет правок — только запуск и проверка.

**Interfaces:**
- Consumes: сервис compose (задача 1), env local (задача 2).

- [ ] **Step 1: Поднять стек**

Run: `make up`
Expected: exit 0; образ пересобрался (или из кэша), контейнер `infra_graphiti` создан. Остальные сервисы не пересоздаются (env не менялся).

- [ ] **Step 2: Дождаться healthy**

Run: `sleep 30 && docker ps --filter name=infra_graphiti --format '{{.Names}} {{.Status}}'`
Expected: `infra_graphiti Up … (healthy)`. Если `unhealthy`/`Restarting` — `docker logs --tail 30 infra_graphiti` и остановиться: НЕ чинить наугад, зафиксировать вывод логов в отчёте.

- [ ] **Step 3: /healthz изнутри контейнера**

Run: `docker exec infra_graphiti python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8000/healthz').status)"`
Expected: `200`.

- [ ] **Step 4: Санити DNS с сети ecosystem**

Run: `docker run --rm --network ecosystem curlimages/curl:latest -s -o /dev/null -w '%{http_code}\n' http://graphiti-sidecar:8000/healthz`
Expected: `200`. (Если образа curl нет и его нельзя тянуть — допустимо пропустить шаг, отметив это в отчёте: DNS-имя равно имени сервиса и проверено шагом 3 косвенно.)

Коммита в этой задаче нет (правок файлов нет).

---

### Task 4: README — состав стека и контракты

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: имена/порты из задачи 1.

- [ ] **Step 1: Строка в таблицу «Состав стека»**

В таблицу после строки `| neo4j | … |` добавить:

```markdown
| graphiti-sidecar | aibox/graphiti-sidecar (build из `${APPS_ROOT}/ai-box-data-registry/sidecar/graphiti`) | только сеть `ecosystem` (`http://graphiti-sidecar:8000`), healthcheck `/healthz` |
```

- [ ] **Step 2: Абзац в «Контракты для приложений»**

После абзаца про `ai-box-pdn-cleaner` (заканчивается «…общий Redis (DB 6).») вставить:

```markdown
**graphiti-sidecar** (Python/FastAPI, код в `ai-box-data-registry/sidecar/graphiti`,
деплой — этим стеком) — shared-сервис графового инжеста/поиска поверх `neo4j`.
Потребители — ai-box-data-registry и корпоративная вики
(ai-box-template-wiki-global) — ходят на `http://graphiti-sidecar:8000`
(изоляция потребителей — префиксы `group_id` и заголовок `X-Consumer`, контракт
на стороне сайдкара). LLM-путь сайдкара — внутренний OpenAI-совместимый прокси
ai-box `http://gateway:8085/api/internal/llm/v1` (env `GRAPHITI_*` в
`env/<stend>/config.env`).
```

- [ ] **Step 3: Строка в блок env-хостов**

В код-блок «Хосты зависимостей в `.env` приложений» после строки `NEO4J_BOLT_URL=…` добавить:

```
GRAPHITI_BASE_URL=http://graphiti-sidecar:8000  # графовый инжест (data-registry, вики)
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): контракты graphiti-sidecar (shared-сервис)"
```

---

### Task 5: Вика + метаданные bead

**Files:**
- Create: `.claude/wiki/decisions/graphiti-sidecar-shared.md`
- Modify: `.claude/wiki/entities/shared-stack.md`
- Modify: `.claude/wiki/concepts/contracts.md`
- Modify: `.claude/wiki/index.md`
- Modify: `.claude/wiki/log.md` (append)

**Interfaces:**
- Consumes: факты из задач 1-4.

- [ ] **Step 1: Decision-страница**

Создать `.claude/wiki/decisions/graphiti-sidecar-shared.md`:

```markdown
---
title: Graphiti-сайдкар — shared-сервис, собираемый инфрой из репозитория DR
type: decision
tags: [docker, compose, graphiti, neo4j, llm, data-registry, wiki-global]
sources: [docker-compose.yml, Makefile, env/example/config.env, docs/superpowers/specs/2026-08-08-graphiti-sidecar-shared-design.md]
updated: 2026-08-08
---

# Graphiti-сайдкар в общем стеке

Сайдкар Graphiti (FastAPI, графовый инжест/поиск поверх [[decision:neo4j-graph-store]])
переехал из eco-compose реестра в этот стек: у него два потребителя (реестр и
корпоративная вики ai-box-template-wiki-global, эпик `ai-box-dr-v18`), и релизы
DR не должны давать окон недоступности инжеста вики. Имя сервиса
`graphiti-sidecar` — DNS-контракт (`http://graphiti-sidecar:8000`), контейнер —
`infra_graphiti`.

## Сборка: инфра, из чужого репозитория

Registry в экосистеме нет — образ `aibox/graphiti-sidecar` собирает этот стек
из `${APPS_ROOT}/ai-box-data-registry/sidecar/graphiti` (`build:` + `image:` в
compose, `--build` в цели `up`; `--build` пересобирает только сервисы с ключом
`build:` — это ровно сайдкар). Прецедент доступа к чужому checkout'у — nginx
уже монтирует код приложений из `APPS_ROOT`. Trade-off: обновление кода
сайдкара = `git pull` DR + `make up` инфры — осознанно, релизный цикл отвязан
от релизов DR. Отклонённая альтернатива (DR публикует тег, инфра только
`image:`): деплой DR получил бы право трогать чужой стек, а окно рестарта
осталось бы привязанным к релизам DR.

## LLM-путь и ключи

Канонический путь — внутренний OpenAI-совместимый прокси ai-box
(`http://gateway:8085/api/internal/llm/v1`, спека `ai-box-back-pssf`): чат —
по каталогу `llm_models` с тарификацией, эмбеддинги — Ollama, бесплатно.
Прокси игнорирует `Authorization`, поэтому дефолт ключей в compose —
заглушка `internal`. Пустым ключ быть не может: graphiti-core создаёт
эмбеддер на старте процесса, и пустой ключ роняет контейнер в краш-луп —
именно так сайдкар тест-контура DR умирал на doitai с момента запуска.
Дефолты кодов моделей пустые (не OpenAI'шные): незаполненный стенд падает
громко на первом вызове (422 от прокси), а не молча ходит мимо каталога.

## Порядок ввода и риски

1. Деплой инфры → сайдкар поднят, `/healthz` зелёный (LLM зовётся только на
   инжесте). 2. Посадка `ai-box-back-pssf` → вписать коды моделей в
   `env/doitai/config.env`, `make up`. 3. Выпил сайдкара из eco-compose DR —
   отдельный bead в трекере DR (до него на doitai временно сосуществует
   крашлупящийся `ai-box-dr-test-graphiti`; в DNS он почти не светится).

**Открытый риск (вне этой задачи):** прокси требует обязательный
`X-Client-Id` (ULID тенанта, иначе 400), сайдкар шлёт `X-Consumer: dr|wiki`
(`ai-box-dr-cb3`) — нестыковку обязаны примирить pssf/cb3, до этого инжест
через прокси будет получать 400.

## Связи

- [[decision:neo4j-graph-store]]
- [[entity:shared-stack]]
- [[concept:contracts]]
- [[decision:env-per-stend]]

## Связанные Beads

- [[bead:ai-box-infra-vl8]] — перенос деплоя (этот репозиторий)
```

- [ ] **Step 2: shared-stack.md**

В `.claude/wiki/entities/shared-stack.md`:
- в таблицу сервисов после строки `| neo4j | … |` добавить:

```markdown
| graphiti-sidecar | aibox/graphiti-sidecar (build из `${APPS_ROOT}/ai-box-data-registry/sidecar/graphiti`) | shared графовый инжест/поиск (реестр + вики); DNS-контракт `graphiti-sidecar:8000`; env `GRAPHITI_*`; см. [[decision:graphiti-sidecar-shared]] |
```

- в секции «Makefile» заменить `` `up/down/logs`, `` на `` `up` (с `--build` — пересборка образа сайдкара из checkout'а DR)/`down`/`logs`, ``
- `updated:` во frontmatter → `2026-08-08`.

- [ ] **Step 3: contracts.md**

В `.claude/wiki/concepts/contracts.md`:
- в списке «Имена на сети ecosystem» в пункт «инфра-сервисы» после `browserless`, добавить `graphiti-sidecar:8000` (получится: `` `mariadb`, `redis`, `qdrant`, `browserless`, `graphiti-sidecar:8000` (графовый инжест: data-registry + вики), `gateway` … ``);
- в секцию «Env-хосты в .env приложений» после `QDRANT_BASE_URL=…` добавить `` `GRAPHITI_BASE_URL=http://graphiti-sidecar:8000` (DR, вики), ``;
- `updated:` → `2026-08-08`.

- [ ] **Step 4: index.md**

В секцию «Решения (`decisions/`)» после строки `[[decision:env-per-stend]]` добавить:

```markdown
- [[decision:graphiti-sidecar-shared]] — Graphiti-сайдкар как shared-сервис: сборка инфрой из репозитория DR, LLM через внутренний прокси ai-box.
```

- [ ] **Step 5: log.md**

В конец `.claude/wiki/log.md` дописать:

```markdown

## [2026-08-08] ingest | Graphiti-сайдкар переехал в shared-стек

Сервис `graphiti-sidecar` в docker-compose.yml (build из
`${APPS_ROOT}/ai-box-data-registry/sidecar/graphiti`, image
aibox/graphiti-sidecar, `--build` в `make up`), env `GRAPHITI_*` по стендам,
LLM — внутренний прокси ai-box (gateway:8085). Мотивация: два потребителя
(реестр + корпоративная вики), релизы DR без окон недоступности инжеста.
Новая [[decision:graphiti-sidecar-shared]]; обновлены [[entity:shared-stack]],
[[concept:contracts]], README. Bead [[bead:ai-box-infra-vl8]].
```

- [ ] **Step 6: wiki_refs в bead**

```bash
bd update ai-box-infra-vl8 --metadata '{"wiki_refs":["decisions/graphiti-sidecar-shared.md","entities/shared-stack.md","concepts/contracts.md"]}'
```

- [ ] **Step 7: Commit**

```bash
git add .claude/wiki/ .beads/issues.jsonl
git commit -m "docs(wiki): решение graphiti-sidecar-shared, контракты и shared-stack"
```

(`.beads/issues.jsonl` добавлять только если хук beads его изменил.)

---

## Итоговая проверка исполнителя

- `make config` — exit 0;
- `docker ps --filter name=infra_graphiti` — `(healthy)`;
- `git log --oneline -5` — четыре коммита задач 1, 2, 4, 5 поверх исходного HEAD;
- `git status` — чисто (кроме возможных некоммитных файлов, которые были до начала).

Деплой doitai в план НЕ входит (боевые операции — человек по спеке §6).
