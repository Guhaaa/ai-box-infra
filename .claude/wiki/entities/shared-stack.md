---
title: Shared-стек — сервисы и overlay-файлы
type: entity
tags: [docker, compose, infrastructure]
sources: [docker-compose.yml, docker-compose.transition.yml, docker-compose.local.yml, Makefile, mariadb/initdb/01-apps.sh]
updated: 2026-07-04
---

# Shared-стек

Базовый файл `docker-compose.yml` (project `ai_box_infra`):

| Сервис | Образ | Заметки |
|---|---|---|
| nginx | nginx:1.27-alpine | 80/443; alias `gateway`; рендер шаблонов envsubst; см. [[entity:nginx-edge]] |
| mariadb | mariadb:11.8 (LTS) | одна на всех; базы/юзеры создаёт `mariadb/initdb/01-apps.sh` при первом старте volume; пароли из `.env` |
| redis | redis:7.4-alpine | requirepass обязателен (строка `null` недопустима — боевой урок); DB-индексы — [[concept:contracts]] |
| qdrant | qdrant/qdrant:${QDRANT_VERSION} | версия цели ≥ версии источника данных; пин по прод-источнику |
| browserless | browserless/chrome | TOKEN обязателен |
| certbot | certbot/certbot | profile `certs`, одноразовые запуски из Makefile |

Сеть `ecosystem`: attachable bridge, создаётся этим стеком (руками
`docker network create` — нельзя, ломает labels), подсеть параметризована
(`ECOSYSTEM_SUBNET`/`ECOSYSTEM_GATEWAY`, дефолт 172.30.0.0/24) — перед
запуском проверять `ip route`.

## Overlay-файлы

- `docker-compose.transition.yml` — прод-переезд рядом с работающей старой
  инфрой: nginx 127.0.0.1:8090/8444, mariadb 3307, qdrant 6334, серты —
  bind хостового /etc/letsencrypt. Требует compose ≥ 2.24 (`!override`).
- `docker-compose.local.yml` — dev-машина: nginx 8090/443, mariadb 3310,
  qdrant без публикации.
- `docker-compose.prod-local.yml` — некоммитный, локальный для конкретного
  хоста (на бою: nginx-mount MCP из `/var/www/ai-box-mcp-eco`).

## Makefile

`up/down/logs`, `build-base`/`build-base-dev`, `certs-init` (standalone до
первого nginx), `certs-renew` (webroot + reload, в cron), `certs-selfsigned`
(dev), `db-import DB=… FILE=…`, `mariadb-cli`/`redis-cli`. Makefile читает
`.env` (домены, пароли).

## Связи

- [[entity:nginx-edge]]
- [[entity:php-base-image]]
- [[concept:contracts]]
- [[concept:deployment-topologies]]
