# env-по-стендам (эталон на infra) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Версионировать несекретный конфиг стендов infra в git (`env/<stend>/config.env`), секреты держать некоммитным `env/<stend>/secrets.env` на сервере, стенд выбирать переменной `STAND`, пост-деплой вынести в идемпотентный `deploy/post-deploy.sh`. Плоский `.env` — выпилить.

**Architecture:** Makefile выбирает каталог стенда по `STAND ?= local`, слоями подключает `config.env` → (условно) `testzone.env` → `secrets.env` и через `docker compose --env-file` (несколько раз, секреты поверх конфига). Никакого fallback на старый `.env` — чистый переход. Боевой доплой doitai триггерится push'ем в master, поэтому правки Makefile+workflow сцеплены и боевая миграция серверов вынесена в отдельную гейтованную Фазу 2.

**Tech Stack:** docker compose (v2, `--env-file` многократно), GNU make (`-include`, `?=`, `$(wildcard)`), bash, GitHub Actions (SSH-деплой).

## Global Constraints

- Язык всех файлов, комментариев, вики и коммитов — **русский**. Conventional Commits: `<type>(<scope>): <описание>`, **без** Co-Authored-By.
- **Истина — в коде.** Спека `docs/superpowers/specs/2026-07-08-env-per-stend-design.md` написана **до** добавления neo4j в стек — поэтому neo4j-ключи (`NEO4J_PASSWORD` — секрет; `NEO4J_VERSION`/`NEO4J_HEAP`/`NEO4J_PAGECACHE` — несекрет) в спеке не перечислены, но **обязаны** попасть в раскладку (иначе `docker compose config` падает на `${NEO4J_PASSWORD:?}`).
- Обязательные (`:?`) переменные базового `docker-compose.yml`: домены `ROOT_DOMAIN`/`FRONT_DOMAIN`/`API_DOMAIN`/`ADMIN_DOMAIN`; секреты `DB_ROOT_PASSWORD`/`AI_BOX_DB_PASSWORD`/`AI_BOX_DR_DB_PASSWORD`/`AI_BOX_MCP_DB_PASSWORD`/`REDIS_PASSWORD`/`BROWSERLESS_TOKEN`/`NEO4J_PASSWORD`. Overlay `docker-compose.testzone.yml` дополнительно требует `TEST_FRONT_DOMAIN`/`TEST_API_DOMAIN`/`TEST_ADMIN_DOMAIN`.
- Секреты в `secrets.env` не должны содержать make-враждебных символов (`#`, `$`) — иначе `-include` мис-парсит значение для make-целей (`mariadb-cli`, `db-import`). Генерить `openssl rand -hex 24`.
- **НЕ коммитить** предсуществующие несвязанные правки дерева (`.claude/wiki/concepts/deployment-topologies.md` gpu-часть, `.claude/wiki/integrations/gpu-services.md`, `docs/runbooks/release-develop-to-master.md`, `.beads/*`). Каждый коммит стейджит **только** файлы своей задачи явным `git add <путь>`.
- Фаза 1 **не пушит в master** и не трогает боевые серверы. Останавливается на локальном коммите.

**Категоризация ключей (зафиксирована):**

| config.env (несекрет, committed) | secrets.env (секрет, gitignored) |
|---|---|
| `APPS_ROOT`, `ROOT_DOMAIN`, `FRONT_DOMAIN`, `API_DOMAIN`, `ADMIN_DOMAIN`, `CERT_NAME`, `ASR_WS_UPSTREAM`, `ECOSYSTEM_SUBNET`, `ECOSYSTEM_GATEWAY`, `QDRANT_VERSION`, `MARIADB_BUFFER_POOL`, `REDIS_MAXMEMORY`, `NEO4J_VERSION`, `NEO4J_HEAP`, `NEO4J_PAGECACHE` | `DB_ROOT_PASSWORD`, `AI_BOX_DB_PASSWORD`, `AI_BOX_DR_DB_PASSWORD`, `AI_BOX_MCP_DB_PASSWORD`, `REDIS_PASSWORD`, `BROWSERLESS_TOKEN`, `NEO4J_PASSWORD` |

---

# ФАЗА 1 — сборка артефактов + миграция локального стенда (безопасно, исполняет plan-executor)

## Task 1: Шаблоны `env/example/` (документация всех ключей)

**Files:**
- Create: `env/example/config.env`
- Create: `env/example/secrets.env`

**Interfaces:**
- Produces: канонический перечень ключей каждого слоя — эталон для config.env/secrets.env всех стендов.

- [ ] **Step 1: Создать `env/example/config.env`**

```bash
mkdir -p env/example
```

Содержимое `env/example/config.env`:

```dotenv
# ШАБЛОН несекретного конфига стенда (committed). Скопировать в
# env/<stend>/config.env и заполнить под стенд. Секреты — в secrets.env.

# Корень, где на хосте лежат git-клоны приложений (ai-box, ai-box-front, …).
APPS_ROOT=/var/www

# Домены копии. Раскладка: корень → редирект на app.; фронт app., API api.,
# админка admin. CERT_NAME — имя lineage сертификата (дефолт = ROOT_DOMAIN).
ROOT_DOMAIN=ai-box.example.ru
FRONT_DOMAIN=app.ai-box.example.ru
API_DOMAIN=api.ai-box.example.ru
ADMIN_DOMAIN=admin.ai-box.example.ru
#CERT_NAME=ai-box.example.ru

# ASR ws-апстрим (per-stend). Не задан → инертный дефолт 127.0.0.1:9.
#ASR_WS_UPSTREAM=192.168.100.29:49153

# Подсеть ecosystem (проверить занятость: ip route).
#ECOSYSTEM_SUBNET=172.30.0.0/24
#ECOSYSTEM_GATEWAY=172.30.0.1

# Версия Qdrant: цель >= источника данных.
#QDRANT_VERSION=v1.17.0

# Тюнинг под RAM хоста.
#MARIADB_BUFFER_POOL=512M
#REDIS_MAXMEMORY=512mb

# Neo4j: версия образа (версия GDS пинится в Makefile).
#NEO4J_VERSION=5.26.28-community
#NEO4J_HEAP=512m
#NEO4J_PAGECACHE=512m
```

- [ ] **Step 2: Создать `env/example/secrets.env`**

Содержимое `env/example/secrets.env`:

```dotenv
# ШАБЛОН секретов стенда. Реальный env/<stend>/secrets.env НЕ коммитится
# (gitignored), лежит на сервере, chmod 600. Генерить: openssl rand -hex 24.
# Без символов # и $ в значениях (ломают make -include).
DB_ROOT_PASSWORD=
AI_BOX_DB_PASSWORD=
AI_BOX_DR_DB_PASSWORD=
AI_BOX_MCP_DB_PASSWORD=
REDIS_PASSWORD=
BROWSERLESS_TOKEN=
NEO4J_PASSWORD=
```

- [ ] **Step 3: Проверка — все обязательные ключи присутствуют**

Run:
```bash
for k in APPS_ROOT ROOT_DOMAIN FRONT_DOMAIN API_DOMAIN ADMIN_DOMAIN; do grep -q "^$k=\|^#$k=" env/example/config.env || echo "MISSING $k"; done
for k in DB_ROOT_PASSWORD AI_BOX_DB_PASSWORD AI_BOX_DR_DB_PASSWORD AI_BOX_MCP_DB_PASSWORD REDIS_PASSWORD BROWSERLESS_TOKEN NEO4J_PASSWORD; do grep -q "^$k=" env/example/secrets.env || echo "MISSING $k"; done
echo OK
```
Expected: печатает только `OK` (никаких `MISSING`).

- [ ] **Step 4: Commit**

```bash
git add env/example/config.env env/example/secrets.env
git commit -m "feat(env): шаблоны env/example — перечень ключей config/secrets"
```

---

## Task 2: Стенд `local` (эта машина, it11) + `.gitignore`

**Files:**
- Create: `env/local/config.env` (committed)
- Create: `env/local/secrets.env` (gitignored — НЕ коммитить)
- Modify: `.gitignore:1`

**Interfaces:**
- Consumes: перечень ключей из Task 1.
- Produces: рабочий env локального стенда — на нём валидируются Makefile (Task 4) и финальная сборка (Task 7).

- [ ] **Step 1: Создать `env/local/config.env`** (реальные несекретные значения этой машины)

```bash
mkdir -p env/local
```

Содержимое `env/local/config.env`:

```dotenv
# Стенд: local (dev, it11). Несекретный конфиг — в git.
APPS_ROOT=/var/www/html
ROOT_DOMAIN=ai-box.local
FRONT_DOMAIN=app.ai-box.local
API_DOMAIN=api.ai-box.local
ADMIN_DOMAIN=admin.ai-box.local
ECOSYSTEM_SUBNET=10.230.0.0/24
ECOSYSTEM_GATEWAY=10.230.0.1
QDRANT_VERSION=v1.17.0
MARIADB_BUFFER_POOL=2G
REDIS_MAXMEMORY=1gb
ASR_WS_UPSTREAM=192.168.100.29:49153
```

- [ ] **Step 2: Создать `env/local/secrets.env`** (dev-dummy; НЕ коммитится)

Значения — из текущего `/var/www/html/ai-box-infra/.env` (dev-dummy `secret` + реальный BROWSERLESS_TOKEN). `NEO4J_PASSWORD` в старом `.env` отсутствовал — задать dev-значение (локальный neo4j не поднят, но нужно для интерполяции `${NEO4J_PASSWORD:?}`):

```dotenv
DB_ROOT_PASSWORD=secret
AI_BOX_DB_PASSWORD=secret
AI_BOX_DR_DB_PASSWORD=secret
AI_BOX_MCP_DB_PASSWORD=secret
REDIS_PASSWORD=secret
BROWSERLESS_TOKEN=649ed05994127e9efff22bdd302ac6b9
NEO4J_PASSWORD=localdevneo4j
```

```bash
chmod 600 env/local/secrets.env
```

- [ ] **Step 3: Обновить `.gitignore`** — заменить строку 1 (`.env`) блоком:

```gitignore
# Плоский .env выпилен (env-per-stend, decisions/env-per-stend.md).
# Секреты стендов — env/*/secrets.env (на серверах, не в git). Транзитивно
# .env всё ещё игнорируем (мог остаться на старых серверах).
.env
env/*/secrets.env
!env/example/secrets.env
```

- [ ] **Step 4: Проверка игнора**

Run:
```bash
git check-ignore env/local/secrets.env && echo "local/secrets: ИГНОР ок"
git check-ignore env/example/secrets.env && echo "ОШИБКА: example/secrets не должен игнориться" || echo "example/secrets: реинклюд ок"
```
Expected:
```
env/local/secrets.env
local/secrets: ИГНОР ок
example/secrets: реинклюд ок
```

- [ ] **Step 5: Проверка — все обязательные переменные заданы (не пусты)**

Run:
```bash
set -a; . env/local/config.env; . env/local/secrets.env; set +a
for k in ROOT_DOMAIN FRONT_DOMAIN API_DOMAIN ADMIN_DOMAIN DB_ROOT_PASSWORD AI_BOX_DB_PASSWORD AI_BOX_DR_DB_PASSWORD AI_BOX_MCP_DB_PASSWORD REDIS_PASSWORD BROWSERLESS_TOKEN NEO4J_PASSWORD; do [ -n "${!k}" ] || echo "EMPTY $k"; done; echo OK
```
Expected: только `OK`.

- [ ] **Step 6: Commit** (только config.env и .gitignore; secrets.env НЕ добавлять)

```bash
git add env/local/config.env .gitignore
git status --short   # убедиться, что env/local/secrets.env НЕ в staged
git commit -m "feat(env): стенд local (config) + gitignore env/*/secrets.env"
```

---

## Task 3: Стенды `doitai` и `amulex` (config, committed; secrets — на серверах в Фазе 2)

**Files:**
- Create: `env/doitai/config.env` (committed)
- Create: `env/doitai/testzone.env` (committed)
- Create: `env/amulex/config.env` (committed)

**Interfaces:**
- Consumes: перечень ключей из Task 1.
- Produces: стартовые значения боевых стендов; финализируются сверкой с сервером в Фазе 2 (§5 спеки) **до** пуша.

> **Важно:** значения доменов/APPS_ROOT/CERT_NAME известны; `ECOSYSTEM_SUBNET/GATEWAY`, тюнинг и `QDRANT_VERSION` боевых стендов **сверяются с текущим `.env` сервера в Фазе 2** — там, где не уверены, ключ помечен `# СВЕРИТЬ`. Оставить закомментированным = compose возьмёт дефолт; менять сеть/тюнинг вслепую нельзя (пересоздание сети — простой).

- [ ] **Step 1: Создать `env/doitai/config.env`**

```bash
mkdir -p env/doitai
```

```dotenv
# Стенд: doitai (боевая копия doitai.ru, сплит). Несекретный конфиг — в git.
APPS_ROOT=/var/www
ROOT_DOMAIN=doitai.ru
FRONT_DOMAIN=app.doitai.ru
API_DOMAIN=api.doitai.ru
ADMIN_DOMAIN=admin.doitai.ru
CERT_NAME=doitai.ru
# СВЕРИТЬ с /var/www/ai-box-infra/.env на doitai (Фаза 2, до пуша):
#ECOSYSTEM_SUBNET=172.30.0.0/24
#ECOSYSTEM_GATEWAY=172.30.0.1
#QDRANT_VERSION=v1.17.0
# doitai 16G RAM → буфер ~4G:
MARIADB_BUFFER_POOL=4G
#REDIS_MAXMEMORY=1gb
#NEO4J_VERSION=5.26.28-community
```

- [ ] **Step 2: Создать `env/doitai/testzone.env`** (условный overlay-слой тест-зоны)

```dotenv
# Overlay-слой тест-зоны doitai (test.doitai.ru). Подключается Makefile'ом только
# на стенде doitai (наличие файла = активный testzone-override). Читается
# docker-compose.testzone.yml (обязательные :? переменные).
TEST_FRONT_DOMAIN=app.test.doitai.ru
TEST_API_DOMAIN=api.test.doitai.ru
TEST_ADMIN_DOMAIN=admin.test.doitai.ru
```

- [ ] **Step 3: Создать `env/amulex/config.env`**

```bash
mkdir -p env/amulex
```

```dotenv
# Стенд: amulex (боевой addons.amulex.ru, сплит, transition). Несекрет — в git.
APPS_ROOT=/var/www
ROOT_DOMAIN=ai-box.amulex.ru
FRONT_DOMAIN=app.ai-box.amulex.ru
API_DOMAIN=api.ai-box.amulex.ru
ADMIN_DOMAIN=admin.ai-box.amulex.ru
CERT_NAME=ai-box.amulex.ru
# СВЕРИТЬ с текущим .env на amulex (Фаза 2, до перехода):
#ECOSYSTEM_SUBNET=172.30.0.0/24
#ECOSYSTEM_GATEWAY=172.30.0.1
#QDRANT_VERSION=v1.12.4
#MARIADB_BUFFER_POOL=512M
#REDIS_MAXMEMORY=512mb
```

- [ ] **Step 4: Проверка — файлы парсятся как env (нет синтаксических ошибок)**

Run:
```bash
for f in env/doitai/config.env env/doitai/testzone.env env/amulex/config.env; do ( set -a; . "$f"; set +a ) && echo "$f: parse ок" || echo "$f: ОШИБКА"; done
```
Expected: три строки `… parse ок`.

- [ ] **Step 5: Commit**

```bash
git add env/doitai/config.env env/doitai/testzone.env env/amulex/config.env
git commit -m "feat(env): стенды doitai/amulex (config) + testzone-слой doitai"
```

---

## Task 4: Makefile — выбор стенда, слои, COMPOSE, цель `config`

**Files:**
- Modify: `Makefile:4-8` (блок `COMPOSE`/`-include .env`/`export`)
- Modify: `Makefile:23-25` (`.PHONY`)

**Interfaces:**
- Consumes: `env/<stend>/{config,secrets}.env` (Tasks 2-3), `env/local/secrets.env` присутствует на этой машине.
- Produces: `STAND`/`ENVDIR`/`TESTZONE` переменные, `COMPOSE` с `--env-file`, цель `config`. Используется Task 5 (`eco-deploy`) и Task 7 (валидация).

- [ ] **Step 1: Проверка «до» — старый механизм ещё читает плоский .env**

Run: `grep -n "include .env" Makefile`
Expected: строка `7:-include .env` присутствует (её и заменяем).

- [ ] **Step 2: Заменить блок `Makefile:4-8`**

Было (строки 4-8):
```make
COMPOSE = docker compose

# Домены и пароли — из .env этой копии
-include .env
export
```

Стало:
```make
# Стенд этой копии infra: local (дефолт) | doitai | amulex. Env-переменная STAND
# перекрывает дефолт (?=). Несекретный конфиг + секреты — из env/$(STAND)/.
# Плоский .env выпилен — см. .claude/wiki/decisions/env-per-stend.md.
STAND    ?= local
ENVDIR   := env/$(STAND)
# testzone.env — условный overlay-слой: подключается, только если есть в каталоге
# стенда (=doitai). Тот же признак, что и активный testzone-override.
TESTZONE := $(wildcard $(ENVDIR)/testzone.env)

# Значения — и для make-целей (db-import/mariadb-cli/certs-*), и для интерполяции
# ${VAR} в compose. Порядок: config → (testzone) → secrets (секреты поверх).
-include $(ENVDIR)/config.env
-include $(TESTZONE)
-include $(ENVDIR)/secrets.env
export

# docker compose --env-file можно указать несколько раз: файлы мержатся,
# последний перекрывает. testzone-слой подключается только когда файл есть.
COMPOSE = docker compose --env-file $(ENVDIR)/config.env \
          $(if $(TESTZONE),--env-file $(TESTZONE),) \
          --env-file $(ENVDIR)/secrets.env
```

- [ ] **Step 3: Добавить цель `config`** — вставить после цели `ps` (после строки `$(COMPOSE) ps`):

```make

# Валидация интерполяции env текущего стенда: рендерит и молча проверяет.
# Ненулевой код = незаполненная/потерянная переменная. Использует STAND.
config:
	$(COMPOSE) config --quiet
```

- [ ] **Step 4: Добавить `config` и `eco-deploy` в `.PHONY`** (Task 5 добавит цель `eco-deploy`; объявим сразу оба)

`Makefile:23` — в список `.PHONY` дописать `config eco-deploy`:
```make
.PHONY: up down restart ps logs build-base build-base-dev testzone-enable testzone-sync mariadb-cli redis-cli \
        certs-init certs-renew certs-selfsigned nginx-reload nginx-render nginx-test db-import \
        neo4j-plugins neo4j-cli neo4j-smoke neo4j-dump neo4j-restore config eco-deploy
```

- [ ] **Step 5: Проверка — COMPOSE собирается с нужными --env-file для local**

Run: `STAND=local make -n config`
Expected: печатает команду вида
```
docker compose --env-file env/local/config.env  --env-file env/local/secrets.env config --quiet
```
(без `testzone` — у local его нет.)

- [ ] **Step 6: Проверка — для doitai появляется testzone-слой**

Run: `STAND=doitai make -n config`
Expected: в команде присутствует `--env-file env/doitai/testzone.env`.

- [ ] **Step 7: Проверка — реальная валидация интерполяции local (главный тест задачи)**

Run: `STAND=local make config`
Expected: exit 0, без вывода (все `:?`-переменные заполнены из env/local/*). Проверить код: `echo $?` → `0`.

- [ ] **Step 8: Commit**

```bash
git add Makefile
git commit -m "feat(make): выбор стенда STAND, слои env/<stend>, COMPOSE --env-file, цель config"
```

---

## Task 5: `deploy/post-deploy.sh` + цель `eco-deploy`

**Files:**
- Create: `deploy/post-deploy.sh` (committed, +x)
- Modify: `Makefile` (добавить цель `eco-deploy` рядом с `up`)

**Interfaces:**
- Consumes: `STAND` (экспортируется Makefile'ом), цель `nginx-reload` (уже есть).
- Produces: цель `eco-deploy` — точка входа боевого доплоя; hook-шаблон, который наследуют app-репо.

- [ ] **Step 1: Создать `deploy/post-deploy.sh`**

```bash
mkdir -p deploy
```

Содержимое `deploy/post-deploy.sh`:

```bash
#!/usr/bin/env bash
# Идемпотентный пост-деплой infra-стека (вызывается make eco-deploy после up).
# Повтор безопасен. STAND экспортирован Makefile'ом. Для infra шаг тонкий —
# перечитка nginx с рендером шаблонов: штатный envsubst образа nginx отрабатывает
# только в entrypoint при старте, поэтому после git pull шаблонов нужен явный
# render+test+reload (см. цель nginx-reload и грабку ai-box-back-99co).
#
# ВНИМАНИЕ: certs-init сюда НЕ входит — он занимает :80 в standalone-режиме и
# конфликтует с уже работающим nginx. Первичный сертификат — ручной шаг ДО
# первого up (см. Makefile: certs-init).
#
# App-репо наследуют этот файл как ШАБЛОН и дописывают свои идемпотентные шаги:
# php artisan migrate --force; php artisan queue:restart;
# php artisan mcp:register-config-builtin — каждый повтор безопасен.
set -euo pipefail

STAND="${STAND:-local}"
echo "[post-deploy] stand=${STAND}"

make nginx-reload

echo "[post-deploy] done"
```

```bash
chmod +x deploy/post-deploy.sh
```

- [ ] **Step 2: Добавить цель `eco-deploy` в Makefile** — вставить сразу после блока цели `up` (после строки `$(COMPOSE) up -d`):

```make

# Экосистемный деплой: собрать базовый образ, поднять стек, прогнать идемпотентный
# пост-деплой hook. STAND экспортируется выше — post-deploy.sh его видит.
# Заменяет ручную связку build-base + up + nginx-reload в CI.
eco-deploy: build-base up
	./deploy/post-deploy.sh
```

- [ ] **Step 3: Проверка синтаксиса скрипта**

Run: `bash -n deploy/post-deploy.sh && test -x deploy/post-deploy.sh && echo "syntax+exec ок"`
Expected: `syntax+exec ок`

- [ ] **Step 4: Проверка порядка eco-deploy**

Run: `make -n eco-deploy`
Expected: сначала `docker build -t aibox/php-base:8.3 php-base` (build-base), затем `docker compose … up -d`, в конце `./deploy/post-deploy.sh`.

- [ ] **Step 5: Commit**

```bash
git add deploy/post-deploy.sh Makefile
git commit -m "feat(deploy): идемпотентный post-deploy.sh + цель eco-deploy"
```

---

## Task 6: Workflow `deploy-doitai.yml` → `STAND=doitai make eco-deploy`

**Files:**
- Modify: `.github/workflows/deploy-doitai.yml:27`

**Interfaces:**
- Consumes: цель `eco-deploy` (Task 5), стенд `doitai` (Task 3).
- Produces: боевую команду доплоя. **Эффект — только при push в master (Фаза 2).** Коммит здесь безопасен (не пушим).

- [ ] **Step 1: Заменить строку 27**

Было:
```yaml
          ssh guha@doitai.ru 'cd /var/www/ai-box-infra && git pull origin master && make build-base && make up && make nginx-reload'
```

Стало:
```yaml
          ssh guha@doitai.ru 'cd /var/www/ai-box-infra && git pull origin master && export STAND=doitai && make eco-deploy'
```

- [ ] **Step 2: Проверка YAML валиден и содержит нужное**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy-doitai.yml')); print('yaml ок')"
grep -q "export STAND=doitai && make eco-deploy" .github/workflows/deploy-doitai.yml && echo "команда ок"
```
Expected:
```
yaml ок
команда ок
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-doitai.yml
git commit -m "ci(doitai): деплой через STAND=doitai make eco-deploy"
```

---

## Task 7: Выпил плоского `.env` + финальная валидация чистого перехода

**Files:**
- Delete: `/var/www/html/ai-box-infra/.env`

**Interfaces:**
- Consumes: рабочий Makefile (Task 4) + env/local/* (Task 2).
- Produces: доказательство, что стек больше не зависит от плоского `.env`.

- [ ] **Step 1: Бэкап на всякий случай (вне git, во временную папку)**

```bash
cp .env /tmp/ai-box-infra-env.bak && echo "бэкап в /tmp/ai-box-infra-env.bak"
```

- [ ] **Step 2: Удалить плоский `.env`**

```bash
rm .env
```

- [ ] **Step 3: Проверка — сборка стенда local по-прежнему валидна БЕЗ плоского .env (главный тест чистого перехода)**

Run: `STAND=local make config; echo "exit=$?"`
Expected: `exit=0` (интерполяция целиком из env/local/*, плоский .env не нужен).

- [ ] **Step 4: Проверка — docker compose не подтягивает старый .env неявно**

Run: `STAND=local make -n up | head -1`
Expected: команда `docker compose --env-file env/local/config.env … up -d` (нет ссылок на `.env`).

> Плоский `.env` не под git (ignored) — отдельного коммита удаление не требует. Достаточно того, что он физически убран с машины; фиксация факта — в Task 8 (вика) и в описании bead.

---

## Task 8: Вика — decision-страница + обновления

**Files:**
- Create: `.claude/wiki/decisions/env-per-stend.md`
- Modify: `.claude/wiki/concepts/deployment-topologies.md` (добавить секцию про env-per-stend + ссылку)
- Modify: `.claude/wiki/index.md` (зарегистрировать новую страницу)
- Modify: `.claude/wiki/log.md` (append-запись)

**Interfaces:**
- Consumes: всё сделанное в Tasks 1-7.
- Produces: «почему и какой ценой» для задачи `ai-box-infra-11l`.

> Перед правкой прочитать `.claude/wiki/index.md` и `.claude/wiki/log.md` (актуальная структура/формат). **Не трогать** предсуществующую незакоммиченную gpu-правку в `deployment-topologies.md` — только добавить свою секцию, свой diff.

- [ ] **Step 1: Создать `.claude/wiki/decisions/env-per-stend.md`**

Frontmatter + содержание (заполнить по спеке и этому плану):

```markdown
---
title: env по стендам + пост-деплой hook
type: decision
tags: [deployment, env, infrastructure, make]
sources: [docs/superpowers/specs/2026-07-08-env-per-stend-design.md, Makefile, deploy/post-deploy.sh, env/]
updated: 2026-07-27
---

# env по стендам (эталон на infra)

## Проблема
Конфиг стендов жил в раннбуках и на серверах вне git: разбежка значений,
ручное копирование, дрейф сервер ≠ репозиторий. Плоский `.env` не объявлял,
на какой стенд он рассчитан → «прила локально теряет / ходит не тот контур».

## Решение
- Несекретный конфиг стенда — в git (`env/<stend>/config.env`), секреты —
  некоммитный `env/<stend>/secrets.env` на сервере (gitignored, реинклюд
  `env/example/secrets.env`).
- Стенд — переменная `STAND ?= local` (env перекрывает дефолт). Слои:
  `config.env` → (условно) `testzone.env` → `secrets.env`, мерж через
  многократный `docker compose --env-file` (секреты поверх).
- Пост-деплой — идемпотентный `deploy/post-deploy.sh`, дёргается `make eco-deploy`.
- Чистый переход: плоский `.env` выпилен, без fallback.

## Альтернативы
- Плоские `.env.<stend>` — отвергнуто (грязный gitignore, не масштабируется).
- Шифрованный env в git (SOPS/git-crypt) — отвергнуто в пользу split-секретов.
- Секрет-стор (Vault) — избыточно для масштаба.

## Trade-off'ы и риски
- Правки Makefile+workflow **сцеплены**: push в master триггерит доплой doitai;
  до пуша на сервере обязан лежать `env/<stend>/secrets.env`, иначе `:?`-секреты
  валят весь `compose up` (класс грабки NEO4J_PASSWORD). → боевая миграция серверов
  вынесена в отдельную гейтованную фазу (runbook + разрешение).
- Спека предшествовала neo4j — neo4j-ключи добавлены в раскладку по факту кода.
- Секреты не должны содержать `#`/`$` (ломают make `-include`).

## Связи
- [[concept:deployment-topologies]]
- [[entity:shared-stack]]
- [[decision:neo4j-graph-store]]

## Связанные Beads
- [[bead:ai-box-infra-11l]]
```

- [ ] **Step 2: Дополнить `deployment-topologies.md`** — добавить в конец (перед `## Связи`) секцию:

```markdown
## Выбор стенда — env-per-stend
Стенд копии infra выбирается переменной `STAND` (local | doitai | amulex);
конфиг стенда версионируется в `env/<stend>/config.env`, секреты — в некоммитном
`env/<stend>/secrets.env` на сервере. Подробности и trade-off'ы —
[[decision:env-per-stend]].
```
И в секции `## Связи` добавить строку `- [[decision:env-per-stend]]`.

- [ ] **Step 3: Зарегистрировать страницу в `index.md`** — в раздел decisions добавить строку-ссылку на `decisions/env-per-stend.md` (формат — как у соседних записей раздела).

- [ ] **Step 4: Append в `log.md`** (формат из `.claude/rules/wiki.md`):

```markdown
## [2026-07-27] ingest | env-per-stend: STAND-слои env/<stend>, выпил плоского .env, eco-deploy hook
```

- [ ] **Step 5: Проверка ссылок**

Run:
```bash
test -f .claude/wiki/decisions/env-per-stend.md && echo "страница ок"
grep -q "env-per-stend" .claude/wiki/index.md && echo "index ок"
grep -q "2026-07-27.*env-per-stend" .claude/wiki/log.md && echo "log ок"
```
Expected: три строки `… ок`.

- [ ] **Step 6: Commit**

```bash
git add .claude/wiki/decisions/env-per-stend.md .claude/wiki/index.md .claude/wiki/log.md
git add -p .claude/wiki/concepts/deployment-topologies.md   # только своя секция + ссылка, НЕ gpu-часть
git commit -m "docs(wiki): decision env-per-stend + топологии/индекс/лог"
```

> `git add -p` — интерактивно выбрать ТОЛЬКО добавленную секцию env-per-stend, не трогая предсуществующую незакоммиченную gpu-правку. Если plan-executor не может в интерактив — вынести gpu-правку через `git stash push .claude/wiki/concepts/deployment-topologies.md` до Task 8 и вернуть после, либо отдельно скопировать свою секцию.

---

## Task 9: Закрыть Фазу 1 в трекере (без пуша)

- [ ] **Step 1: Отметить прогресс в bead**

Run:
```bash
bd update ai-box-infra-11l --notes="Фаза 1 (сборка + миграция local) готова, в master НЕ запушено. Осталась Фаза 2 (боевая миграция doitai/amulex + пуш) по runbook docs/runbooks/env-per-stend-migration.md с разрешения."
```

- [ ] **Step 2: Показать лог коммитов Фазы 1 главной сессии на верификацию**

Run: `git log --oneline -8`
Expected: коммиты Task 1,2,3,4,5,6,8 (env-шаблоны, local, doitai/amulex, make, deploy, ci, wiki).

> **СТОП. Фаза 1 закончена. НЕ пушить в master. Передать управление главной сессии для верификации и решения по Фазе 2.**

---

# ФАЗА 2 — боевая миграция серверов + пуш (НЕ plan-executor; runbook + явное разрешение)

> Эту фазу plan-executor **не исполняет**. Она — операция на боевых серверах,
> идёт по раннбуку `docs/runbooks/env-per-stend-migration.md` (создаётся ниже)
> и только с явного «go» человека. Порядок (спека §5): сначала doitai.

**Гейт перед пушем в master (иначе доплой doitai красный):**
1. На doitai: `git fetch` (без слияния деплойной ветки) → сверить `env/doitai/config.env` с текущим `/var/www/ai-box-infra/.env` (несекретные ключи, особ. `ECOSYSTEM_SUBNET/GATEWAY`, `QDRANT_VERSION`, тюнинг); поправить закоммиченный `config.env` под факт сервера, добить `# СВЕРИТЬ`-ключи; коммит.
2. На doitai: создать `env/doitai/secrets.env` (chmod 600) из секретов текущего `.env` + `NEO4J_PASSWORD` (тот же, что в реестре — см. bead `ai-box-infra-80w`).
3. Проверка на doitai: `STAND=doitai make config` → exit 0.
4. Только теперь push в master → workflow гонит `STAND=doitai make eco-deploy`.
5. Постпроверка: `STAND=doitai make ps`, домены отвечают, `make neo4j-smoke` (если neo4j поднят).
6. Удалить плоский `.env` на doitai.
7. amulex — аналогично, но стенд объявляется `export STAND=amulex` в его деплой-таргете (не через master-push); мигрируется в своё окно.

- [ ] **(Фаза 2) Создать runbook `docs/runbooks/env-per-stend-migration.md`** с шагами выше (делает главная сессия перед боевым окном).

---

## Самопроверка плана (выполнена автором)

- **Покрытие спеки:** §1 модель файлов → Tasks 1-3; §2 STAND → Task 4; §3 post-deploy+eco-deploy → Task 5; §4 workflow → Task 6; §5 миграция (чистый переход) → Task 7 (local) + Фаза 2 (боевые); §6 сплит — вне скоупа infra (эпик `ai-box-infra-93h`); deliverables (env/, Makefile, deploy, gitignore, workflow, decision-страница) → Tasks 1-8.
- **Отклонения от спеки (истина в коде):** (1) neo4j-ключи добавлены в раскладку — спека их не знала; (2) `certs-init` в post-deploy НЕ включён (конфликт :80 с работающим nginx) — оставлен ручным первичным шагом; (3) workflow — `eco-deploy` без хвостового `nginx-reload` (reload уже внутри post-deploy).
- **Плейсхолдеры:** значения боевых стендов помечены `# СВЕРИТЬ` и финализируются в Фазе 2 по §5 — это не заглушка, а сверка с сервером.
- **Согласованность имён:** `STAND`/`ENVDIR`/`TESTZONE`/`COMPOSE`, цели `config`/`eco-deploy` — единообразны в Tasks 4-6.
