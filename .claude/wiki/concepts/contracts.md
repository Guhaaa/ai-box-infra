---
title: Контракты для приложений экосистемы
type: concept
tags: [contracts, network, redis]
sources: [README.md, docker-compose.yml, nginx/conf.d]
updated: 2026-07-04
---

# Контракты

Всё, на что завязаны app-репозитории. Менять — только синхронно с ними.

## Имена на сети ecosystem

- php-fpm приложений (их ждёт nginx): `ai-box-php:9000`,
  `ai-box-dr-php:9000`, `ai-box-mcp-php:9000`;
- инфра-сервисы: `mariadb`, `redis`, `qdrant`, `browserless`,
  `gateway` (alias nginx; внутренние vhost'ы 8083/8084/8085);
- GPU-сервисы в режиме «всё внутри»: `ollama-router:11434`,
  `ai-box-pdn-cleaner:8000`.

## Пути кода

`/var/www/<канон-имя>` одинаково в php-fpm и nginx. Канон: `ai-box`,
`ai-box-data-registry` (опечатка «regestry» старого прода исправлена),
`ai-box-mcp`. На бою MCP временно смонтирован из `/var/www/ai-box-mcp-eco`
(общий каталог со старым стеком имел config-кэш) — после фазы 3 каталоги
переименуются и некоммитный overlay уйдёт.

## Redis DB-индексы (один инстанс, requirepass)

Прод-исторические (НЕ из ранней таблицы 0/1|2/3|4/5):

| Приложение | queue/default | cache |
|---|---|---|
| ai-box | 0 | 1 |
| data-registry | 6 | 7 |
| MCP | 8 | 9 |

Резерв pdn-cleaner (этап «всё внутри») — выбрать свободный (например 10).

## Env-хосты в .env приложений

`DB_HOST=mariadb`, `REDIS_HOST=redis` (+ пароль — настоящий, не `null`),
`QDRANT_BASE_URL=http://qdrant:6333` (DR), `DEMO_BROWSERLESS_URL=http://browserless:3000`,
`DATA_REGISTRY_URL=http://gateway:8083`, `AIBOX_MCP_URL=http://gateway:8084`,
`AIBOX_BASE_URL=http://gateway:8085` (или публичный URL), `OLLAMA_BASE_URL`/
`PDN_CLEANER_URL` — адреса GPU-хоста (сплит) или docker-имена («всё внутри»).

## Базы MariaDB

`ai_box`, `ai_box_dr`, `ai_box_mcp` + одноимённые пользователи — создаются
init-скриптом при первой инициализации volume, пароли из `.env` стека
(= паролям в `.env` приложений).

## Связи

- [[entity:shared-stack]]
- [[entity:nginx-edge]]
- [[integration:app-stacks]]
- [[integration:gpu-services]]
