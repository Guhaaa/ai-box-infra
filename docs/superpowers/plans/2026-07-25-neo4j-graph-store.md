# Neo4j Community + GDS в общий стек — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить сервис `neo4j` (Community 5.26.28 + GDS 2.13.4) в shared-стек ai-box-infra, чтобы реестр получил графовое хранилище на eco-контуре по `bolt://neo4j:7687`.

**Architecture:** Сервис по шаблону `qdrant` в базовом `docker-compose.yml` (сеть `ecosystem`, loopback-публикация, именованный том). Плагин GDS ставим сами идемпотентным `make neo4j-plugins` (пин версии + sha256, bind-mount `neo4j/plugins:/plugins:ro`) — без рантайм-резолвера `NEO4J_PLUGINS`, чтобы снять egress со старта контейнера. Схему графа накатывает реестр, не мы.

**Tech Stack:** Docker Compose, Neo4j 5.26.x Community, Neo4j GDS 2.13.x, GNU Make, bash/curl/sha256sum.

## Global Constraints

- Образ Neo4j: **`neo4j:5.26.28-community`** (последний 5.x LTS; тег есть на Docker Hub; на 5.26.0 баг установки GDS — не использовать).
- GDS: версия **`2.13.4`**, url `https://github.com/neo4j/graph-data-science/releases/download/2.13.4/neo4j-graph-data-science-2.13.4.jar`, размер `64058557`, sha256 **`10e072f73992224f1159f246c9d6a89da5f3b3434aeffa5be42647edda13a8d8`**.
- Bolt `7687` и HTTP `7474` — публиковать ТОЛЬКО на `127.0.0.1` (наружу закрыто).
- Имя сервиса строго `neo4j` (контракт реестра `bolt://neo4j:7687`).
- Не трогать другие сервисы и посторонние правки рабочего дерева (в дереве уже есть несвязанные изменения вики — их не касаться).
- Язык комментариев/доков/коммитов — русский. Conventional Commits: `<type>(<scope>): описание`. **Без** `Co-Authored-By`.
- Валидация compose — через отдельный env-файл (в стеке много `${VAR:?}`): создать `$SCRATCH/neo4j-validate.env` (Task 2) и использовать `docker compose --env-file $SCRATCH/neo4j-validate.env ... config --quiet`. `$SCRATCH` = `/tmp/claude-1000/-var-www-html-ai-box-infra/9a7591b3-8834-4eb0-9cd0-e5ca2501438c/scratchpad`.
- Коммиты Task 1–4 (нет правок вики) — с трейлером `Wiki: skip` (вся вика единым коммитом в Task 5, подавляем предупреждение git-хука). Task 5 — без `Wiki: skip`.
- **Живой прогон контейнера (`up`/`neo4j-smoke`) в этот план НЕ входит** — его выполняет главная сессия на этапе верификации (хост может быть боевым). Здесь — только статическая валидация (`config --quiet`, `make -n`) и безопасный `make neo4j-plugins` (просто скачивает jar в gitignored-каталог, контейнеры не поднимает).
- Формат «изменение → проверка командой с ожидаемым выводом» вместо unit-TDD (инфра-конфиг).

---

### Task 1: Каталог плагинов + идемпотентный fetch GDS

**Files:**
- Create: `neo4j/plugins/.gitkeep`
- Modify: `.gitignore` (добавить `neo4j/plugins/*.jar`)
- Modify: `Makefile` (переменные GDS, цель `neo4j-plugins`, `.PHONY`)

**Interfaces:**
- Produces: цель `make neo4j-plugins` — идемпотентно кладёт `neo4j/plugins/neo4j-graph-data-science-2.13.4.jar`; переменные `NEO4J_GDS_VERSION`/`NEO4J_GDS_SHA256`/`NEO4J_GDS_URL`/`NEO4J_PLUGINS_DIR`/`NEO4J_GDS_JAR`.

- [ ] **Step 1: Создать маркер каталога**

Создать пустой файл `neo4j/plugins/.gitkeep` (каталог должен существовать в репо, jar в него не коммитим).

- [ ] **Step 2: Игнор для jar'ов плагина**

В конец `.gitignore` добавить:

```
# Плагин Neo4j GDS — ставится make neo4j-plugins (пин+sha256), не коммитим
neo4j/plugins/*.jar
```

- [ ] **Step 3: Переменные GDS в Makefile**

В `Makefile` после блока с `CERT_EMAIL ?= admin@amulex.ru` (перед `.PHONY`) вставить:

```makefile
# Neo4j: плагин GDS ставим сами (пин версии + sha256), НЕ через NEO4J_PLUGINS —
# так нет egress-зависимости на старте контейнера. Версию Neo4j↔GDS пинить
# по матрице совместимости GDS (2.13.x — единственная линия под Neo4j 5.26.x).
NEO4J_GDS_VERSION ?= 2.13.4
NEO4J_GDS_SHA256  ?= 10e072f73992224f1159f246c9d6a89da5f3b3434aeffa5be42647edda13a8d8
NEO4J_GDS_URL     ?= https://github.com/neo4j/graph-data-science/releases/download/$(NEO4J_GDS_VERSION)/neo4j-graph-data-science-$(NEO4J_GDS_VERSION).jar
NEO4J_PLUGINS_DIR := neo4j/plugins
NEO4J_GDS_JAR     := $(NEO4J_PLUGINS_DIR)/neo4j-graph-data-science-$(NEO4J_GDS_VERSION).jar
```

- [ ] **Step 4: Цель `neo4j-plugins` в Makefile**

В конец `Makefile` добавить:

```makefile
# Идемпотентная установка плагина GDS в neo4j/plugins (bind-mount :/plugins:ro).
# Валидный jar на месте → skip. Иначе: удалить прочие версии, скачать во
# временный файл, ЖЁСТКО сверить sha256 (mismatch → abort), атомарно перенести.
# Предшаг перед `up` (host-каталог должен быть пополнён до старта контейнера).
neo4j-plugins:
	@mkdir -p $(NEO4J_PLUGINS_DIR)
	@if [ -f "$(NEO4J_GDS_JAR)" ] && echo "$(NEO4J_GDS_SHA256)  $(NEO4J_GDS_JAR)" | sha256sum -c - >/dev/null 2>&1; then \
		echo "GDS $(NEO4J_GDS_VERSION): jar на месте, sha256 ок — skip"; \
	else \
		echo "GDS $(NEO4J_GDS_VERSION): качаю $(NEO4J_GDS_URL)"; \
		rm -f $(NEO4J_PLUGINS_DIR)/neo4j-graph-data-science-*.jar; \
		curl -fsSL -o "$(NEO4J_GDS_JAR).tmp" "$(NEO4J_GDS_URL)"; \
		echo "$(NEO4J_GDS_SHA256)  $(NEO4J_GDS_JAR).tmp" | sha256sum -c - || { rm -f "$(NEO4J_GDS_JAR).tmp"; echo "GDS sha256 MISMATCH — abort"; exit 1; }; \
		mv "$(NEO4J_GDS_JAR).tmp" "$(NEO4J_GDS_JAR)"; chmod 644 "$(NEO4J_GDS_JAR)"; \
		echo "GDS $(NEO4J_GDS_VERSION): установлен"; \
	fi
```

- [ ] **Step 5: Зарегистрировать цель в `.PHONY`**

В строку `.PHONY: ...` добавить `neo4j-plugins` (в конец списка перечисления).

- [ ] **Step 6: Проверка — скачивание и идемпотентность**

Run: `make neo4j-plugins && echo "--- второй прогон ---" && make neo4j-plugins`
Expected: первый прогон печатает `качаю ...` и `установлен`; второй печатает `jar на месте, sha256 ок — skip`.

Run: `sha256sum neo4j/plugins/neo4j-graph-data-science-2.13.4.jar`
Expected: `10e072f73992224f1159f246c9d6a89da5f3b3434aeffa5be42647edda13a8d8  neo4j/plugins/neo4j-graph-data-science-2.13.4.jar`

Run: `git status --porcelain neo4j/plugins/`
Expected: только `neo4j/plugins/.gitkeep` (jar игнорируется).

- [ ] **Step 7: Commit**

```bash
git add neo4j/plugins/.gitkeep .gitignore Makefile
git commit -m "build(neo4j): идемпотентный fetch плагина GDS 2.13.4

Wiki: skip"
```

---

### Task 2: Сервис `neo4j` в `docker-compose.yml` + том + `.env.example`

**Files:**
- Modify: `docker-compose.yml` (сервис `neo4j` после `browserless`; том `neo4j_data`)
- Modify: `.env.example` (блок Neo4j)
- Create: `$SCRATCH/neo4j-validate.env` (только для валидации, не в репо)

**Interfaces:**
- Consumes: сеть `ecosystem`, каталог `neo4j/plugins` (Task 1).
- Produces: сервис `neo4j` на `ecosystem` (`neo4j:7687`); переменные окружения `NEO4J_PASSWORD` (обяз.), `NEO4J_VERSION`/`NEO4J_HEAP`/`NEO4J_PAGECACHE` (опц.).

- [ ] **Step 1: env-файл для валидации compose**

Создать `$SCRATCH/neo4j-validate.env` с содержимым:

```
ROOT_DOMAIN=example.test
FRONT_DOMAIN=app.example.test
API_DOMAIN=api.example.test
ADMIN_DOMAIN=admin.example.test
DB_ROOT_PASSWORD=x
AI_BOX_DB_PASSWORD=x
AI_BOX_DR_DB_PASSWORD=x
AI_BOX_MCP_DB_PASSWORD=x
REDIS_PASSWORD=x
BROWSERLESS_TOKEN=x
NEO4J_PASSWORD=x
```

- [ ] **Step 2: Добавить сервис `neo4j`**

В `docker-compose.yml` между концом блока `browserless` (строка с `- ecosystem` его секции `networks:`) и строкой `volumes:` вставить:

```yaml
  neo4j:
    # Граф-хранилище knowledge реестра. Стоковый образ, БЕЗ NEO4J_PLUGINS:
    # плагин GDS ставим сами в neo4j/plugins (make neo4j-plugins, пин+sha256).
    # Версия Neo4j↔GDS пинится согласованно (5.26.x ↔ GDS 2.13.x).
    image: neo4j:${NEO4J_VERSION:-5.26.28-community}
    container_name: infra_neo4j
    restart: unless-stopped
    # Наружу не светим; loopback — ручная диагностика (Bolt + Neo4j Browser).
    # Приложения ходят по сети ecosystem на neo4j:7687 напрямую.
    ports:
      - "127.0.0.1:7687:7687"   # Bolt (клиенты, cypher-shell)
      - "127.0.0.1:7474:7474"   # HTTP Neo4j Browser (диагностика)
    environment:
      NEO4J_AUTH: neo4j/${NEO4J_PASSWORD:?NEO4J_PASSWORD обязателен}
      # Слушать интерфейс контейнера, чтобы app-контейнеры на ecosystem достучались
      # (наружу закрыто loopback-публикацией, как mariadb/qdrant).
      NEO4J_server_default__listen__address: 0.0.0.0
      # GDS требует unrestricted, иначе процедуры gds.* не грузятся.
      NEO4J_dbms_security_procedures_unrestricted: gds.*
      # Память под RAM хоста (.env; дефолты малы и безопасны — как MARIADB_BUFFER_POOL).
      NEO4J_server_memory_heap_initial__size: ${NEO4J_HEAP:-512m}
      NEO4J_server_memory_heap_max__size: ${NEO4J_HEAP:-512m}
      NEO4J_server_memory_pagecache_size: ${NEO4J_PAGECACHE:-512m}
    volumes:
      - neo4j_data:/data
      - ./neo4j/plugins:/plugins:ro   # jar кладёт make neo4j-plugins; ro — Neo4j только читает
    networks:
      - ecosystem
```

- [ ] **Step 3: Добавить том `neo4j_data`**

В блоке `volumes:` после строки `  qdrant_data:` добавить:

```yaml
  neo4j_data:
```

- [ ] **Step 4: Блок Neo4j в `.env.example`**

В конец `.env.example` добавить:

```
# Neo4j (граф-хранилище knowledge реестра). Пароль — секрет и точка стыковки с
# реестром: реестр в СВОЁМ .env ставит NEO4J_BOLT_URL=bolt://neo4j:7687,
# NEO4J_USER=neo4j, NEO4J_PASSWORD=<то же значение>.
NEO4J_PASSWORD=
# Версия образа Neo4j (версия GDS пинится в Makefile: NEO4J_GDS_VERSION).
#NEO4J_VERSION=5.26.28-community
# Память Neo4j под RAM хоста (дефолты 512m безопасны; на doitai/прод — больше).
#NEO4J_HEAP=512m
#NEO4J_PAGECACHE=512m
```

- [ ] **Step 5: Проверка — конфиг валиден и сервис виден**

Run: `docker compose --env-file $SCRATCH/neo4j-validate.env config --quiet && echo OK`
Expected: `OK` (без ошибок валидации).

Run: `docker compose --env-file $SCRATCH/neo4j-validate.env config | grep -E 'infra_neo4j|127.0.0.1:7687|neo4j:5.26.28-community'`
Expected: строки с `image: neo4j:5.26.28-community`, `container_name: infra_neo4j`, публикацией `127.0.0.1:7687`.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml .env.example
git commit -m "feat(neo4j): сервис neo4j 5.26.28-community в общий стек

Wiki: skip"
```

---

### Task 3: Overlay-ремапы портов (transition + local)

**Files:**
- Modify: `docker-compose.transition.yml`
- Modify: `docker-compose.local.yml`

**Interfaces:**
- Consumes: сервис `neo4j` (Task 2).

- [ ] **Step 1: transition — сдвиг loopback-портов**

В `docker-compose.transition.yml` в конец блока `services:` (после блока `qdrant`) добавить:

```yaml
  neo4j:
    # 7687/7474 могут быть заняты на переходном хосте — сдвигаем loopback.
    ports: !override
      - "127.0.0.1:7688:7687"
      - "127.0.0.1:7475:7474"
```

- [ ] **Step 2: local — не публиковать**

В `docker-compose.local.yml` в конец блока `services:` (после блока `qdrant`) добавить:

```yaml
  neo4j:
    # Диагностика — docker exec; порты на dev-машине не публикуем.
    ports: !override []
```

- [ ] **Step 3: Проверка — оба overlay валидны и ремап применён**

Run: `docker compose --env-file $SCRATCH/neo4j-validate.env -f docker-compose.yml -f docker-compose.transition.yml config | grep -E '127.0.0.1:7688|127.0.0.1:7475'`
Expected: обе строки присутствуют (Bolt→7688, HTTP→7475).

Run: `docker compose --env-file $SCRATCH/neo4j-validate.env -f docker-compose.yml -f docker-compose.local.yml config | grep -A15 'neo4j:' | grep -c '7687'`
Expected: `0` (в local сервис neo4j без опубликованных портов — совпадений `7687` в published нет; если появляется в image-теге, уточнить grep на `published`).

- [ ] **Step 4: Commit**

```bash
git add docker-compose.transition.yml docker-compose.local.yml
git commit -m "feat(neo4j): overlay-ремап портов neo4j (transition/local)

Wiki: skip"
```

---

### Task 4: Makefile — cli/smoke/dump/restore + `up` prereq

**Files:**
- Modify: `Makefile` (цели `neo4j-cli`/`neo4j-smoke`/`neo4j-dump`/`neo4j-restore`; `up` зависит от `neo4j-plugins`; `.PHONY`)

**Interfaces:**
- Consumes: `neo4j-plugins` (Task 1), сервис `neo4j` (Task 2), `NEO4J_PASSWORD` из `.env`.

- [ ] **Step 1: `up` зависит от `neo4j-plugins`**

В `Makefile` заменить строку:

```makefile
up:
	$(COMPOSE) up -d
```

на:

```makefile
# neo4j-plugins — предшаг: host-каталог neo4j/plugins должен быть пополнён
# до старта контейнера neo4j (иначе GDS не загрузится, поймает neo4j-smoke).
up: neo4j-plugins
	$(COMPOSE) up -d
```

- [ ] **Step 2: Цели работы с Neo4j**

В конец `Makefile` добавить:

```makefile
neo4j-cli:
	$(COMPOSE) exec neo4j cypher-shell -u neo4j -p "$$NEO4J_PASSWORD"

# Проверка живого GDS: ОБЯЗАН вернуть $(NEO4J_GDS_VERSION). Ловит рассинхрон
# Neo4j↔GDS (несовместимый плагин Neo4j не загрузит → gds.version() не найдётся).
neo4j-smoke:
	$(COMPOSE) exec neo4j cypher-shell -u neo4j -p "$$NEO4J_PASSWORD" "RETURN gds.version() AS gds"

# Ручной офлайн-дамп community: стоп сервиса → дамп одноразовым контейнером на
# том же томе → старт. Дамп в ./backups/neo4j.dump. (Авто-бэкап — ai-box-infra-4tb.)
neo4j-dump:
	@mkdir -p backups
	$(COMPOSE) stop neo4j
	$(COMPOSE) run --rm -v $(PWD)/backups:/backups neo4j neo4j-admin database dump neo4j --to-path=/backups --overwrite-destination=true
	$(COMPOSE) start neo4j

# Восстановление из ./backups/neo4j.dump (ПЕРЕЗАПИШЕТ БД). Сервис остановлен на время.
neo4j-restore:
	$(COMPOSE) stop neo4j
	$(COMPOSE) run --rm -v $(PWD)/backups:/backups neo4j neo4j-admin database load neo4j --from-path=/backups --overwrite-destination=true
	$(COMPOSE) start neo4j
```

- [ ] **Step 3: Зарегистрировать цели в `.PHONY`**

В строку `.PHONY: ...` добавить `neo4j-cli neo4j-smoke neo4j-dump neo4j-restore` (в конец перечисления; `neo4j-plugins` уже добавлен в Task 1).

- [ ] **Step 4: Проверка — рецепты рендерятся без выполнения**

Run: `make -n up`
Expected: сначала действия `neo4j-plugins` (mkdir/if…), затем `docker compose up -d`.

Run: `make -n neo4j-smoke`
Expected: `docker compose exec neo4j cypher-shell -u neo4j -p "$NEO4J_PASSWORD" "RETURN gds.version() AS gds"`.

Run: `make -n neo4j-dump`
Expected: последовательность `docker compose stop neo4j` → `docker compose run --rm ... neo4j-admin database dump neo4j --to-path=/backups ...` → `docker compose start neo4j`.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "feat(neo4j): make-цели cli/smoke/dump/restore, up тянет neo4j-plugins

Wiki: skip"
```

---

### Task 5: Документация и вика

**Files:**
- Modify: `README.md` (строка таблицы сервисов + переменные зависимостей)
- Modify: `.claude/wiki/entities/shared-stack.md` (строка таблицы + prod-тюнинг + `updated`)
- Create: `.claude/wiki/decisions/neo4j-graph-store.md`
- Modify: `.claude/wiki/index.md` (строка decision)
- Modify: `.claude/wiki/log.md` (запись ingest)

**Interfaces:**
- Consumes: всё выше (сервис, make-цели, пины).

- [ ] **Step 1: README — строка таблицы сервисов**

В `README.md` в таблице «Состав стека» после строки `| qdrant | ... |` добавить:

```
| neo4j | neo4j:5.26.28-community | сеть `ecosystem`; 127.0.0.1:7687 (Bolt) / 7474 (Browser) для диагностики; GDS 2.13.4 через `make neo4j-plugins` |
```

- [ ] **Step 2: README — переменные зависимостей**

В `README.md` в блок «Хосты зависимостей в `.env` приложений» после строки `QDRANT_URL=...` добавить:

```
NEO4J_BOLT_URL=bolt://neo4j:7687       # только data-registry (+ NEO4J_USER=neo4j, NEO4J_PASSWORD=<секрет стека>)
```

- [ ] **Step 3: Вика — строка в таблицу shared-stack**

В `.claude/wiki/entities/shared-stack.md` в таблицу сервисов после строки `| qdrant | ... |` добавить:

```
| neo4j | neo4j:5.26.28-community | граф-хранилище knowledge реестра; GDS 2.13.4 ставит `make neo4j-plugins` (пин+sha256, не NEO4J_PLUGINS); loopback 7687/7474; см. [[decision:neo4j-graph-store]] |
```

- [ ] **Step 4: Вика — prod-тюнинг и `updated`**

В `.claude/wiki/entities/shared-stack.md` в предпоследнем абзаце секции «Prod-тюнинг» (строка «Env под RAM хоста …») дополнить перечень переменных: после `REDIS_MAXMEMORY` добавить `, `NEO4J_HEAP`/`NEO4J_PAGECACHE` (heap+pagecache Neo4j, дефолт по 512m)`.
Во frontmatter изменить `updated: 2026-07-04` → `updated: 2026-07-25`.

- [ ] **Step 5: Вика — decision-страница**

Создать `.claude/wiki/decisions/neo4j-graph-store.md` с содержимым:

```markdown
---
title: Neo4j + GDS в общем стеке
type: decision
tags: [docker, compose, neo4j, gds, infrastructure, data-registry]
sources: [docker-compose.yml, Makefile, neo4j/plugins, docs/superpowers/specs/2026-07-25-neo4j-graph-store-design.md]
updated: 2026-07-25
---

# Neo4j Community + GDS в общем стеке

Реестр (`ai-box-data-registry`) вводит графовый слой для knowledge-датасетов на
Neo4j + GDS. На eco-контуре БД/Qdrant/Redis живут в общей инфре — Neo4j встаёт
туда же, сервисом `neo4j` на сети `ecosystem` (`bolt://neo4j:7687`). Владелец —
ai-box-infra; схему графа накатывает реестр (`neo4j:schema-sync`), от нас — живой
сервис.

## Почему в общей инфре, а не в eco-стеке реестра

По Makefile реестра дефолтный STACK=eco берёт mariadb/redis/qdrant из
ai-box-infra. Свой Neo4j реестр поднимает только в legacy-стеке (локальная
разработка/интеграционные тесты). Дублировать сервис в eco его compose = второй
источник инфры. Поэтому Neo4j — здесь, рядом с qdrant.

## GDS ставим сами, идемпотентно (не NEO4J_PLUGINS)

`NEO4J_PLUGINS=["graph-data-science"]` тянет GDS при старте контейнера — egress
на каждый первый `up` и неявная версия. Вместо этого: стоковый образ
`neo4j:5.26.28-community` + `make neo4j-plugins` кладёт пиненный jar
(`neo4j-graph-data-science-2.13.4.jar`, sha256-сверка) в `neo4j/plugins/`,
bind-mount `:/plugins:ro`. Trade-off: сняли egress со старта контейнера ценой
ручного ведения пары версия+sha256 и предшага fetch перед `up`. `make
neo4j-smoke` (`RETURN gds.version()`) ловит рассинхрон сразу.

## Пин версий Neo4j↔GDS

Neo4j 5.26 — последний 5.x (LTS). GDS-линия под 5.26.x — только 2.13.x (2.14+
уже под календарные Neo4j 2025.xx); берём последний патч 2.13.4. Патч Neo4j —
5.26.28 (на 5.26.0 известен баг установки GDS в докере, neo4j/neo4j#13563). При
смене минора Neo4j пару пересматривать по матрице совместимости GDS.

## Бэкапы

Ручной `make neo4j-dump`/`neo4j-restore` (офлайн-дамп community) — паритет с
текущей инфрой (у mariadb/qdrant авто-бэкапов в репо тоже нет). Единая крон-схема
бэкапов — [[bead:ai-box-infra-4tb]], Neo4j доносится туда.

## Риск для air-gapped прод

GDS-jar тянется на `make neo4j-plugins` (не на старте контейнера). На addons с
закрытым egress jar приносится в `neo4j/plugins/` руками — sha256 всё равно
проверится.

## Связи

- [[entity:shared-stack]]
- [[concept:deployment-topologies]]

## Связанные Beads

- [[bead:ai-box-infra-f15]] — реализация (этот репозиторий)
- [[bead:ai-box-infra-4tb]] — крон-бэкапы (Neo4j доносится)
```

- [ ] **Step 6: Вика — index и log**

В `.claude/wiki/index.md` в секцию «Решения (`decisions/`)» добавить строку:

```
- [[decision:neo4j-graph-store]] — Neo4j + GDS в общем стеке для knowledge-графа реестра (GDS идемпотентным fetch'ем, пин 5.26.28↔2.13.4).
```

В конец `.claude/wiki/log.md` добавить:

```
## [2026-07-25] ingest | Neo4j + GDS в общий стек (decision + shared-stack, задача ai-box-infra-f15 / источник ai-box-dr-drf)
```

- [ ] **Step 7: Проверка — ссылки и якоря на месте**

Run: `grep -R "decision:neo4j-graph-store" .claude/wiki/index.md .claude/wiki/entities/shared-stack.md`
Expected: совпадения в обоих файлах.

Run: `grep -E "bead:ai-box-infra-f15|bead:ai-box-infra-4tb" .claude/wiki/decisions/neo4j-graph-store.md`
Expected: обе `[[bead:…]]`-ссылки присутствуют.

Run: `grep -c "neo4j" README.md`
Expected: `>= 2` (строка таблицы + переменная).

- [ ] **Step 8: Commit**

```bash
git add README.md .claude/wiki/entities/shared-stack.md .claude/wiki/decisions/neo4j-graph-store.md .claude/wiki/index.md .claude/wiki/log.md
git commit -m "docs(wiki): Neo4j + GDS в общий стек — decision, shared-stack, README"
```

---

## Post-plan (главная сессия — верификация, НЕ входит в этот план)

- Свести дифф риск-мест (compose-сервис, Makefile-цели, overlay-ремапы).
- Живой прогон на безопасном контуре (local-overlay или согласованный хост):
  `make neo4j-plugins` → `docker compose -f docker-compose.yml -f docker-compose.local.yml up -d neo4j` → `make neo4j-smoke` (ожидание `2.13.4`) → Bolt из временного контейнера на `ecosystem` (`RETURN 1`) → `ss -tlnp` подтверждает loopback-only.
- `bd close ai-box-infra-f15` после успешной верификации; отметить связь с `ai-box-dr-drf` соседям.
- Сообщить команде реестра про ошибочный `wiki_refs: integrations/llm-proxy.md` в `ai-box-dr-drf`.
- Пуш ветки `feat/neo4j-graph-store` (master ai-box-infra пушить можно; слить по finishing-a-development-branch).
