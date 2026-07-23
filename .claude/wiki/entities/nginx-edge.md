---
title: Nginx-вход — шаблоны, TLS, внутренние vhost'ы
type: entity
tags: [nginx, tls, routing]
sources: [nginx/templates, nginx/conf.d, nginx/snippets, Makefile]
updated: 2026-07-23
---

# Nginx-вход

## Публичные vhost'ы — envsubst-шаблоны

`nginx/templates/*.conf.template` рендерятся entrypoint'ом официального
образа при старте (переменные `ROOT_DOMAIN`/`FRONT_DOMAIN`/`API_DOMAIN`/
`ADMIN_DOMAIN`/`CERT_NAME` из `.env`; отрендеренные файлы в `conf.d/`
гитигнорятся). Раскладка доменов:

- `root.conf` — корневой домен → 301 на `app.` (задел под лендинг);
- `front.conf` — `app.` — SPA-статика `ai-box-front/dist` + `/widget/*`;
- `api.conf` — `api.` — только `/api/*` и `/up`, остальное 404;
- `admin.conf` — `admin.` — Filament на корне.

TLS: один SAN-сертификат на 4 домена, lineage = `CERT_NAME`
(дефолт ROOT_DOMAIN). Выпуск `make certs-init`, продление
`make certs-renew`, dev — `make certs-selfsigned`.

## Внутренние vhost'ы (не публикуются на хост)

`nginx/conf.d/internal-*.conf`, доступны только с сети `ecosystem` по
alias `gateway`: 8083 → data-registry, 8084 → MCP, 8085 → ai-box
(межсервисные вызовы, например MCP→ai-box).

## Ключевые решения

- **Runtime-резолв upstream'ов** (`resolver 127.0.0.11` + переменная в
  `fastcgi_pass`): nginx живёт независимо от контейнеров приложений.
- **Поток голосовой диктовки** (`api.conf`): ws-локация `…/asr/stream` с
  `auth_request` в Laravel и `proxy_pass` на внешний ASR (`${ASR_WS_UPSTREAM}`) —
  см. [[decision:voice-dictation]].
- Код приложений смонтирован в nginx по тем же путям, что и в php-fpm
  (`SCRIPT_FILENAME`); `fastcgi_read_timeout` задаётся в vhost'е (у DR 300с).
- **Фронт монтируется РОДИТЕЛЕМ** (`ai-box-front:/var/www/ai-box-front:ro`), не
  `.../dist`. Причина (боевой урок amulex): при release-схеме деплоя фронта
  (`dist` → symlink на `releases/<ts>`) bind-mount самого `dist` разрезолвил бы
  symlink на старте контейнера и застрял на старом релизе — новый релиз не виден
  без рестарта nginx. Монтируя родителя, nginx резолвит `dist` пер-запрос; свопы
  долетают без рестарта. Для rsync-in-place (doitai) тоже работает.

## Связи

- [[entity:shared-stack]]
- [[concept:contracts]]
- [[decision:voice-dictation]]
