---
title: Обзор ai-box-infra
type: overview
tags: [overview, infrastructure, docker]
sources: [README.md, docker-compose.yml, docs/superpowers/specs/2026-07-03-ecosystem-infra-design.md]
updated: 2026-07-04
---

# ai-box-infra — обзор

Shared-инфраструктура экосистемы AiBox: единый docker-compose стек
«фундамента» (edge-nginx с TLS, MariaDB, Redis, Qdrant, browserless),
общий базовый PHP-образ и runbook'и переездов. Приложения экосистемы
(ai-box, ai-box-data-registry, ai-box-mcp, ai-box-front, pdn-cleaner,
ollama-router) живут в своих репозиториях и подключаются к общей
docker-сети `ecosystem` тонкими eco-стеками.

Выбранная схема — «вариант A»: двухуровневая (shared-стек + тонкие
app-стеки), полный дизайн с альтернативами — в
`docs/superpowers/specs/2026-07-03-ecosystem-infra-design.md`.

**Статус (2026-07-04): прод ai-box.amulex.ru переведён на этот стек**
(in-place, сплит-топология, окно записи 76 сек) — см. runbook
`docs/runbooks/split-cutover-ai-box.md`. Dev-окружение переведено днём
ранее. Остаточные работы фазы 3 — в задачах beads.

## Составные части

- [[entity:shared-stack]] — сервисы compose и overlay-файлы окружений.
- [[entity:php-base-image]] — общий базовый PHP-образ приложений.
- [[entity:nginx-edge]] — вход: шаблоны vhost'ов, TLS, внутренние порты.
- [[concept:contracts]] — контракты для приложений (имена, порты, индексы).
- [[concept:deployment-topologies]] — модели размещения и параллельные копии.
- [[integration:app-stacks]] — eco-стеки приложений-потребителей.
- [[integration:gpu-services]] — ollama-router и pdn-cleaner (сплит).

## Связи

- [[concept:contracts]]
- [[concept:deployment-topologies]]
- [[entity:shared-stack]]
