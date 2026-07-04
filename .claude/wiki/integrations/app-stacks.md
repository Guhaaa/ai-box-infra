---
title: Eco-стеки приложений — потребители инфры
type: integration
tags: [apps, compose, ecosystem]
sources: [apps/ai-box, README.md]
updated: 2026-07-04
---

# Eco-стеки приложений

Каждое приложение несёт в своём репозитории
`.docker/docker-compose.ecosystem.yml` — тонкий стек (только php-fpm ±
worker) от [[entity:php-base-image]], сеть `ecosystem` (external),
без `network_mode: host`. Окружение через `.env`: `PHP_BASE_IMAGE`
(prod-дефолт / `:8.3-dev`), `PHP_INI` (prod.ini / local.ini),
`PHP_UID`/`PHP_GID` (дефолт 1001 = guha на бою; dev 1000).

- **ai-box** — `ai-box-php` + `ai-box-queue` (queue:work redis);
  Makefile: `eco-*` таргеты, `eco-deploy` без build-стадии.
- **ai-box-data-registry** — `ai-box-dr-php` + `ai-box-dr-worker`;
  канонический путь исправляет опечатку старого прода.
- **ai-box-mcp** — только `ai-box-mcp-php`; `eco-deploy` включает
  `aibox:sync-types`. На бою работает из клона `ai-box-mcp-eco`.
- **ai-box-front** — не контейнер: статика `dist/`, раздаёт nginx инфры.
  Сниппеты виджетов origin-based; локальная сборка — только с env-override
  `VITE_API_BASE_URL` (vite build читает `.env.production`).

Старые прод/дев compose-файлы в app-репозиториях сохранены до конца
переезда; их удаление — отдельная задача beads.

## Связи

- [[entity:php-base-image]]
- [[concept:contracts]]
- [[entity:nginx-edge]]
