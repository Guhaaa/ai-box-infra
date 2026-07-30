---
title: env по стендам + пост-деплой hook
type: decision
tags: [deployment, env, infrastructure, make]
sources: [docs/superpowers/specs/2026-07-08-env-per-stend-design.md, Makefile, deploy/post-deploy.sh, env/]
updated: 2026-07-30
---

# env по стендам (эталон на infra)

## Проблема

Конфиг стендов жил в раннбуках и на серверах вне git: разбежка значений,
ручное копирование при новом стенде/переезде, дрейф сервер ≠ репозиторий.
Плоский `.env` не объявлял, на какой стенд он рассчитан — отсюда «прила
локально теряет / ходит не тот контур» (тот же `.env` с голыми именами
`mariadb`/`redis`/`neo4j` резолвится в разный физический контур).

## Решение

- **Split-секреты**: несекретный конфиг стенда — в git (`env/<stend>/config.env`),
  секреты — некоммитный `env/<stend>/secrets.env` на сервере (gitignore
  `env/*/secrets.env` + реинклюд `!env/example/secrets.env`).
- **Выбор стенда** — переменная `STAND ?= local` (env перекрывает дефолт).
  Слои: `config.env` → (условно) `testzone.env` → `secrets.env`, мерж через
  многократный `docker compose --env-file` (секреты поверх). Те же значения
  подхватывает `-include` для make-целей (`db-import`/`mariadb-cli`/`certs-*`).
- **testzone.env** — условный overlay-слой, подключается только когда файл есть
  в каталоге стенда (=doitai); тот же признак, что и активный testzone-override.
- **Пост-деплой** — идемпотентный `deploy/post-deploy.sh`, дёргается
  `make eco-deploy` (= build-base + up + hook). Шаблон для app-репо.
- **Чистый переход**: плоский `.env` выпилен, без fallback.

## Альтернативы

- Плоские `.env.<stend>` — отвергнуто (грязный gitignore, не масштабируется на app-репо).
- Шифрованный env в git (SOPS/git-crypt) — отвергнуто в пользу split-секретов.
- Секрет-стор (Vault) — избыточно для текущего масштаба.

## Trade-off'ы и риски

- Правки `Makefile`+workflow **сцеплены**: push в master триггерит доплой doitai;
  до пуша на сервере обязан лежать `env/<stend>/secrets.env`, иначе `:?`-секреты
  валят весь `compose up` (класс грабки NEO4J_PASSWORD). → боевая миграция серверов
  вынесена в отдельную гейтованную фазу (runbook + разрешение), эталон обкатан
  на стенде `local` (it11).
- Спека (2026-07-08) предшествовала neo4j — neo4j-ключи (`NEO4J_PASSWORD` секрет,
  `NEO4J_VERSION`/`NEO4J_HEAP`/`NEO4J_PAGECACHE` несекрет) добавлены в раскладку
  по факту кода.
- `certs-init` в post-deploy НЕ входит (занимает :80, конфликт с живым nginx) —
  остаётся ручным первичным шагом.
- Секреты в `secrets.env` не должны содержать `#`/`$` (ломают make `-include`) —
  генерить `openssl rand -hex 24`.

## Статус миграции

Фаза 1 (артефакты + стенд `local`) готова на ветке `feat/env-per-stend`,
в master **не пушена**; `STAND=local make config` зелёный без плоского `.env`.
Боевая миграция — `docs/runbooks/env-per-stend-migration.md`: гейт перед мержем
(сверка ключей, `secrets.env` на сервере, `make config` во временном worktree),
затем doitai (мерж = автодеплой), затем amulex своим окном.

Два пробела, известных на 2026-07-30:

- **маркера стенда на сервере нет** — спека предполагала файл `.stand`,
  реализация ограничилась `STAND ?= local`. Вызов `make` без `STAND` на боевом
  хосте берёт конфиг dev-машины; защита пока дисциплинарная (раннбук,
  инвентарь cron/Jenkins). Кандидат на фикс —
  `STAND ?= $(shell cat .stand 2>/dev/null || echo local)`.
- **`.env.example` ещё существует** рядом с `env/example/` (мёртвый дубль);
  выпил сцеплен с мержем ветки `feat/polygon-runner-ingress`, которая этот файл
  правит и добавляет обязательный `TEST_MCP_DOMAIN` в testzone-compose.

## Скоуп

Эта итерация — только `ai-box-infra` как эталон. Перенос паттерна в пять app-репо
(где, в частности, живёт управление сплитом `OLLAMA_BASE_URL`/`PDN_CLEANER_URL`) —
следующими итерациями, этот файл как шаблон.

## Связи

- [[concept:deployment-topologies]]
- [[entity:shared-stack]]
- [[decision:neo4j-graph-store]]

## Связанные Beads

- [[bead:ai-box-infra-11l]]
