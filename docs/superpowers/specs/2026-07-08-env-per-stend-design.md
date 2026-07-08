# Дизайн: env по стендам + пост-деплой hook (эталон на ai-box-infra)

> Статус: спек к реализации. Скоуп первой итерации — **только `ai-box-infra`**
> как эталон; для пяти app-репо этот файл служит переносимым шаблоном.

## Проблема

Конфиг стендов (redis-индексы, домены, VITE-ULID, GPU-UUID, tuning) сейчас
живёт **в раннбуках и в голове**, а не версионируется по стендам. Отсюда три
боли (подтверждены заказчиком):

1. **Разбежка значений по стендам** — при каждом деплое надо вспоминать/сверять
   по раннбукам, какое значение на каком стенде.
2. **Ручное копирование на сервер** — env лежит только на сервере вне git;
   при новом стенде/переезде копируется и правится руками, легко забыть ключ.
3. **Дрейф сервер ≠ репозиторий** — что реально стоит на проде, не видно из git;
   правки на сервере теряются, аудит невозможен.

Плюс смежная задача: **пост-деплой команды** (`migrate --force`,
`mcp:register-config-builtin`) сейчас гоняются руками из раннбука.

## Ограничение

В боевом `.env` лежат **реальные секреты** (`*_DB_PASSWORD`, `REDIS_PASSWORD`,
`BROWSERLESS_TOKEN`). Версионировать env целиком в открытом виде нельзя.

## Решение — обзор

Три принятых решения:

- **Split-секреты**: несекретный конфиг стенда — в git, секреты — отдельным
  некоммитным файлом на сервере, деплой их мержит.
- **Версионируемый идемпотентный hook-скрипт** для пост-деплоя (не Deployer/Envoy
  — стек уже docker-compose + make + CI, новые инструменты не тянем).
- **Чистый переход**: старый `.env` разбиваем и убираем, без fallback-костыля.

## 1. Модель файлов env (layering)

Каталог на стенд — файлы стенда лежат вместе, паттерн масштабируется на app-репо,
gitignore чище плоских `.env.<stend>`:

```
env/
  doitai/config.env      committed  — несекретный конфиг стенда
  doitai/testzone.env    committed  — TEST_*-домены, условный overlay-слой (см. ниже)
  doitai/secrets.env     gitignored — секреты, на сервере
  amulex/config.env
  amulex/secrets.env
  local/config.env
  local/secrets.env
  example/config.env     committed  — документация всех ключей (бывший .env.example)
  example/secrets.env    committed  — шаблон секретных ключей
```

Два слоя на стенд, объединяются при деплое (secrets поверх config):

| Файл | Содержит | В git? |
|---|---|---|
| `env/<stend>/config.env` | **несекретный** конфиг: `ROOT/FRONT/API/ADMIN_DOMAIN`, `CERT_NAME`, `APPS_ROOT`, `ECOSYSTEM_SUBNET/GATEWAY`, `QDRANT_VERSION`, `MARIADB_BUFFER_POOL`, `REDIS_MAXMEMORY` | **да** |
| `env/<stend>/secrets.env` | только секреты: `DB_ROOT_PASSWORD`, `AI_BOX_DB_PASSWORD`, `AI_BOX_DR_DB_PASSWORD`, `AI_BOX_MCP_DB_PASSWORD`, `REDIS_PASSWORD`, `BROWSERLESS_TOKEN` | **нет** (на сервере) |
| `env/example/config.env` + `env/example/secrets.env` | документация/шаблоны всех ключей | да |

На уровне infra стендов **три**: `doitai`, `amulex`, `local`. `STAND` = личность
infra-копии (хоста), а не приложения.

**Тест-зона на doitai — не отдельный `STAND`.** `STAND` выбирает деплой-таргет =
отдельный `make up` со своим набором контейнеров. На doitai-хосте **физически один
infra-стек**; тест-зона (`test.doitai.ru`) — overlay на нём (симлинк
`docker-compose.override.yml` → `docker-compose.testzone.yml`), добавляющий vhost'ы
в **тот же** nginx, а не поднимающий второй стек. Поэтому `STAND=doitai-test` на
infra невозможен: он пересоздал бы единственный стек тест-значениями (те же имена
контейнеров/проект) либо, при другом имени проекта, дал бы **второй nginx на
:80/:443 → конфликт портов**. Отдельного infra-таргета «doitai-test» не существует.

Overlay читает от infra-стека три обязательных (`:?`) переменных nginx:
`TEST_FRONT_DOMAIN`, `TEST_API_DOMAIN`, `TEST_ADMIN_DOMAIN` (плюс общие
`APPS_ROOT`, `CERT_NAME`, уже в `config.env`). Чтобы держать их **отдельно от
prod-конфига без фикции второго стека**, они лежат в **`env/doitai/testzone.env`** —
условном overlay-слое, который подключается ровно тогда, когда активен
testzone-override (см. §2). Семантика честная: `doitai` — стенд (стек),
`testzone.env` — доп. слой, а не отдельный `STAND`.

App-стеки тест-копии (ai-box-test и т.д.) — отдельные клоны со своим env в
`${APPS_ROOT}/test/*`, деплоятся `deploy-doitai-test.yml`. **На app-слое
`doitai-test` — полноценный отдельный стенд** (`env/doitai-test/config.env`, все
значения свои: `ai_box_test`, redis 2/3, VITE-ULID, домены приложения) — это
раскатка паттерна в app-репо, вне скоупа infra.

`.gitignore`: `env/*/secrets.env` + реинклюд `!env/example/secrets.env`; старый
`.env` в игноре уже есть и остаётся (переходно), но на серверах файл удаляется
(см. §5). Коммитим `env/{doitai,amulex,local}/config.env` и `env/example/*`.

## 2. Выбор стенда — переменная окружения `STAND`

Источник стенда — **только переменная окружения `STAND`**, дефолт `local`
(отдельного файла-маркера нет). Так снимается неоднозначность «оба прода тянут
master», и каждый стенд объявляет себя удобным ему способом:

- **doitai**: GitHub-workflow подставляет `STAND=doitai` в env SSH-команды деплоя.
- **amulex**: `export STAND=amulex` в окружении деплой-таргета (shell/Jenkins).
- **ручной/локальный запуск**: дефолт `local` (или `STAND=… make …` разово).

Правки `Makefile` (`?=` — env-переменная перекрывает дефолт):

```make
STAND  ?= local
ENVDIR := env/$(STAND)
# testzone.env подключается только если он есть в каталоге стенда (=doitai) —
# тот же признак, что и активный testzone-override
TESTZONE := $(wildcard $(ENVDIR)/testzone.env)
-include $(ENVDIR)/config.env
-include $(TESTZONE)
-include $(ENVDIR)/secrets.env
export
COMPOSE = docker compose --env-file $(ENVDIR)/config.env \
          $(if $(TESTZONE),--env-file $(TESTZONE),) \
          --env-file $(ENVDIR)/secrets.env
```

`docker compose --env-file` можно указывать несколько раз — файлы мержатся,
последний перекрывает (секреты поверх конфига). Так и Makefile-переменные
(`-include`, для целей `db-import`/`mariadb-cli`/`certs-*`), и интерполяция
`${VAR}` в compose-файле берут значения из тех же файлов. Условие `testzone.env`
привязано к наличию файла в каталоге стенда: на doitai он есть (тест-зона активна),
на amulex/local — нет, и слой не подключается (compose не ругнётся на
отсутствующий `--env-file`).

## 3. Post-deploy hook

`deploy/post-deploy.sh` — committed, идемпотентный, знает `$STAND`
(экспортируется Makefile'ом). Для infra шаги тонкие: `nginx -t && nginx -s reload`,
условный `certs-init` при первом старте. Файл задаёт **паттерн-шаблон**, который
app-репо наследуют: туда лягут `php artisan migrate --force`,
`restart php horizon`, `php artisan mcp:register-config-builtin` — каждый шаг
идемпотентный, повтор безопасен.

Новая цель Makefile `eco-deploy` дёргает hook в конце, после `up`:

```make
eco-deploy: build-base up
	./deploy/post-deploy.sh
```

Это убирает «ручной пост-деплой шаг» из runbook `release-develop-to-master.md`.

## 4. Правка CI (`deploy-doitai.yml`)

Заменить строку деплоя, подставив `STAND=doitai` в env SSH-команды:

```
ssh guha@doitai.ru 'cd /var/www/ai-box-infra && git pull origin master && export STAND=doitai && make eco-deploy nginx-reload'
```

(`eco-deploy` уже включает `build-base` и `up`; `export` действует на оба
make-вызова в этой шелл-сессии.)

## 5. Миграция (чистый переход)

Порядок на каждом сервере (сначала doitai — боевой, по runbook и с разрешения):

1. Из текущего `.env` выделить несекретные ключи → сверить с committed
   `env/<stend>/config.env` (значения уже должны совпасть — фиксация факта).
2. Секретные ключи → создать `env/<stend>/secrets.env` (chmod 600).
3. Прописать `STAND` в окружение деплоя (doitai — в workflow; amulex — `export`).
4. Проверка: `STAND=<stend> make ps`, `docker compose config --quiet` —
   интерполяция не потеряла переменных.
5. Удалить старый `.env`.

Боевой doitai мигрируется отдельным шагом по runbook, не в общем окне.

## 6. Сплит (ollama/pdn) — тем же механизмом в app-репо

Топология «сплит ↔ всё внутри» выражается **двумя env-ключами**:
`OLLAMA_BASE_URL` и `PDN_CLEANER_URL` (сплит → LAN-хост `192.168.101.114`;
всё внутри → docker-имена `ollama-router:11434` / `ai-box-pdn-cleaner:8000`).
Их читают **app-контейнеры** (ai-box back и др.), а infra-стек
(nginx/db/redis/qdrant/browserless) — нет. Поэтому в **infra-репо этих ключей
нет**.

Управление сплитом — тем же паттерном `STAND` + `env/<stend>/config.env`, но
**в самих app-репо** (где ключи потребляются): после обкатки эталона на infra
паттерн реплицируется в потребителей, и тогда `env/doitai/config.env` несёт
docker-имена (всё внутри), `env/amulex/config.env` — LAN-URL (сплит). Флип
топологии становится версионируемой правкой строки, а не ручной операцией на
сервере. Для infra это — часть раскатки паттерна в app-репо (см. «Не в скоупе»),
здесь фиксируем принцип: **сплит = per-stend env-атрибут потребителя, а не
инфраструктурный overlay.**

## Что чинит

- **Разбежка** → значения стендов в git, видны рядом в diff.
- **Копирование** → на сервере руками только `env/<stend>/secrets.env` (6 ключей).
- **Дрейф** → несекретный конфиг под версионным контролем, `git diff` ловит расхождение.

## Deliverables (эта итерация, только infra)

- `env/{doitai,amulex,local}/config.env` (несекретные, committed).
- `env/doitai/testzone.env` (TEST_*-домены, committed, условный overlay-слой).
- `env/example/config.env`, `env/example/secrets.env` (committed шаблоны).
- Правки `Makefile` (`STAND ?= local`, ENVDIR, layering, `COMPOSE`, цель `eco-deploy`).
- `deploy/post-deploy.sh` (committed, идемпотентный).
- Правка `.github/workflows/deploy-doitai.yml`.
- Правка `.gitignore` (`env/*/secrets.env` + реинклюд `!env/example/secrets.env`).
- Decision-страница в вике (`.claude/wiki/decisions/env-per-stend.md`) +
  обновление `deployment-topologies.md`, `log.md`, `index.md`.
- Обновление runbook'а `release-develop-to-master.md` (пост-деплой шаг → hook).

## Не в скоупе (следующие итерации)

- Перенос паттерна в пять app-репо (через develop) — этот файл как шаблон.
  **Именно там управляется сплит** (`OLLAMA_BASE_URL`/`PDN_CLEANER_URL`, см. §6):
  `env/doitai/config.env` = всё внутри, `env/amulex/config.env` = сплит.
- Шифрованный env в git (SOPS/git-crypt) — сознательно отвергнут в пользу split.
- Секрет-стор (Vault) — избыточно для текущего масштаба.
