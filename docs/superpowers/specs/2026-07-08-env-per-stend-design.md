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

Три слоя, объединяются при деплое (последний слой перекрывает предыдущий):

| Файл | Содержит | В git? |
|---|---|---|
| `.env.example` | документация всех ключей (как сейчас) | да |
| `.env.doitai` / `.env.amulex` / `.env.local` | **несекретный** конфиг стенда: `ROOT/FRONT/API/ADMIN_DOMAIN`, `CERT_NAME`, `APPS_ROOT`, `ECOSYSTEM_SUBNET/GATEWAY`, `QDRANT_VERSION`, `MARIADB_BUFFER_POOL`, `REDIS_MAXMEMORY` | **да** |
| `.env.secrets` | только секреты: `DB_ROOT_PASSWORD`, `AI_BOX_DB_PASSWORD`, `AI_BOX_DR_DB_PASSWORD`, `AI_BOX_MCP_DB_PASSWORD`, `REDIS_PASSWORD`, `BROWSERLESS_TOKEN` | **нет** (на сервере) |

На уровне infra стендов **три**: `doitai`, `amulex`, `local`. Тест-зона
(`test.doitai.ru`) — overlay на том же doitai-хосте (общий infra-стек), а не
отдельный infra-стенд, поэтому своего `.env.<stend>` не требует.

`.gitignore`: добавить `.env.secrets`; старый `.env` в игноре уже есть и остаётся
(переходно), но на серверах файл удаляется (см. §5). Коммитим `.env.doitai`,
`.env.amulex`, `.env.local`, `.env.secrets.example`, `.stand.example`.

## 2. Выбор стенда — маркер `.stand`

Файл **`.stand`** на сервере (non-committed, одна строка, напр. `doitai`).
Сервер сам объявляет, кто он — снимает неоднозначность «оба прода тянут master».
Коммитим `.stand.example` с пояснением.

Правки `Makefile`:

```make
STAND := $(shell cat .stand 2>/dev/null || echo local)
-include .env.$(STAND)
-include .env.secrets
export
COMPOSE = docker compose --env-file .env.$(STAND) --env-file .env.secrets
```

`docker compose --env-file` можно указывать несколько раз — файлы мержатся,
последний перекрывает (секреты поверх конфига). Так и Makefile-переменные
(`-include`, для целей `db-import`/`mariadb-cli`/`certs-*`), и интерполяция
`${VAR}` в compose-файле берут значения из той же пары файлов.

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

Заменить строку деплоя на вызов новой цели:

```
ssh guha@doitai.ru 'cd /var/www/ai-box-infra && git pull origin master && make eco-deploy && make nginx-reload'
```

(`eco-deploy` уже включает `build-base` и `up`; `.stand` на doitai = `doitai`.)

## 5. Миграция (чистый переход)

Порядок на каждом сервере (сначала doitai — боевой, по runbook и с разрешения):

1. Из текущего `.env` выделить несекретные ключи → сверить с committed
   `.env.<stend>` (значения уже должны совпасть — это и есть фиксация факта).
2. Секретные ключи → создать `.env.secrets` (chmod 600).
3. Создать `.stand` с именем стенда.
4. Проверка: `make ps`, `docker compose config --quiet` — интерполяция не
   потеряла переменных.
5. Удалить старый `.env`.

Боевой doitai мигрируется отдельным шагом по runbook, не в общем окне.

## Что чинит

- **Разбежка** → значения стендов в git, видны рядом в diff.
- **Копирование** → на сервере руками только `.env.secrets` (6 ключей) + `.stand`.
- **Дрейф** → несекретный конфиг под версионным контролем, `git diff` ловит расхождение.

## Deliverables (эта итерация, только infra)

- `.env.doitai`, `.env.amulex`, `.env.local` (несекретные, committed).
- `.env.secrets.example`, `.stand.example` (committed шаблоны).
- Правки `Makefile` (STAND, layering, `COMPOSE`, цель `eco-deploy`).
- `deploy/post-deploy.sh` (committed, идемпотентный).
- Правка `.github/workflows/deploy-doitai.yml`.
- Правка `.gitignore` (`.env.secrets`).
- Decision-страница в вике (`.claude/wiki/decisions/env-per-stend.md`) +
  обновление `deployment-topologies.md`, `log.md`, `index.md`.
- Обновление runbook'а `release-develop-to-master.md` (пост-деплой шаг → hook).

## Не в скоупе (следующие итерации)

- Перенос паттерна в пять app-репо (через develop) — этот файл как шаблон.
- Шифрованный env в git (SOPS/git-crypt) — сознательно отвергнут в пользу split.
- Секрет-стор (Vault) — избыточно для текущего масштаба.
