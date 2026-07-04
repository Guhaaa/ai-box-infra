---
title: Модели размещения и параллельные копии
type: concept
tags: [deployment, topology]
sources: [docs/superpowers/specs/2026-07-03-ecosystem-infra-design.md, docs/runbooks/split-cutover-ai-box.md]
updated: 2026-07-04
---

# Модели размещения

Две топологии; разница — **только env-URL потребителей**, составы compose
не меняются:

1. **«Всё внутри»** — один GPU-сервер: все стеки вместе, потребители ходят
   по docker-именам сети `ecosystem`.
2. **«Сплит»** — app-сервер без GPU; ollama-router и pdn-cleaner на другой
   машине, канал только закрытый (WireGuard/allowlist: у роутера нет auth,
   через pdn ходят ПДн). **Текущий прод — сплит** (GPU на LAN
   192.168.101.114, работают в старом виде — systemd/standalone).

Параллельные копии приложения (переходный период) — независимые инстансы
стека: свои volumes, пароли, домены (envsubst-шаблоны nginx), данные не
шарятся.

## Окружения

- **Прод** (addons.amulex.ru): transition-overlay (хостовые 80/443 ещё у
  старого nginx-прокси) + prod-local overlay (mcp-eco mount). Фаза 3 —
  захват 80/443.
- **Dev**: local-overlay, self-signed серты, домены `*.ai-box.local`
  через /etc/hosts, dev-образ с xdebug (`PHP_BASE_IMAGE`/`PHP_INI`/`PHP_UID`
  в `.env` приложений).
- **doitai.ru** (развёрнут 2026-07-04): вторая копия, **сплит** — Ollama и
  pdn-cleaner внешние (`192.168.101.114`, приватная связность с VM есть,
  проверена): в облаке тикет на добавление GPU; при появлении железа —
  драйвер+toolkit и переключение на локальные GPU-стеки (CPU/GPU-заготовки
  в репозиториях готовы, cpu-режим обкатан и свёрнут 2026-07-04). Базовый
  compose без overlay'ев (80/443 свободны), LE-сертификат через
  `certs-init`, домены doitai.ru, бренд фронта `VITE_BRAND=doitai`,
  PHP_UID=1000 (guha на doitai). Деплой — GitHub Actions по push в master
  (`.github/workflows/deploy-doitai.yml` в пяти репо, секрет
  DOITAI_SSH_KEY). Гочи: bind-mount несуществующего каталога (dist)
  докер создаёт под root; compose с файлами в docker/ требует явный
  `--env-file .env`.

## Проверки перед разворотом на новом хосте (боевые уроки)

- занятость портов overlay'ев (`ss -tlnp`) и подсети (`ip route`);
- `docker compose version` ≥ 2.24 (`!override`);
- версия Qdrant цели ≥ источника данных;
- владелец `storage/`/`bootstrap/cache` = uid php-контейнеров;
- образы с Docker Hub могут не тянуться — сетевые проверки через
  `docker exec` в контейнер приложения (curl в базовом образе есть).

## Связи

- [[entity:shared-stack]]
- [[concept:contracts]]
- [[integration:gpu-services]]
