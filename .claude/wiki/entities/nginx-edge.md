---
title: Nginx-вход — шаблоны, TLS, внутренние vhost'ы
type: entity
tags: [nginx, tls, routing]
sources: [nginx/templates, nginx/templates-test, nginx/conf.d, nginx/snippets, Makefile]
updated: 2026-07-30
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
(межсервисные вызовы, например MCP→ai-box). В тест-зоне то же самое —
`test-internal.conf` на портах 8183/8184/8185.

## Внешний контур раннеров полигона (тест-зона) — `mcp.test.doitai.ru`

`nginx/templates-test/mcp.conf.template` — единственный публичный вход в
ai-box-mcp тест-копии. Он НЕ дублирует раскладку `api.conf` (весь `/api/*` на
try_files + php-локация): здесь наружу светят ровно три ручки раннера,
`/api/v1` того же приложения — control plane без авторизации совсем
(доверенная сеть, `concepts/trusted-network` в репозитории ai-box-mcp).

- `location ^~ /api/external/` — прямой `fastcgi_pass`, БЕЗ прохода через
  `try_files`; `SCRIPT_FILENAME`/`SCRIPT_NAME` переопределены явно (вне
  `.php`-локации `$fastcgi_script_name` = `$uri`, иначе php-fpm ответит
  «File not found» — тот же приём, что в `api.conf` для `/internal/asr-authorize`).
- В шаблоне сознательно НЕТ `location ~ \.php$`: такая regex-локация имеет
  приоритет над `location /` и открыла бы путь `/что-угодно.php` в php-fpm
  в обход `return 404`, включая теоретический доступ к `/api/v1/*.php`-подобным
  путям. Раз php вызывается только из `^~ /api/external/`, отдельная
  `location ~ /\.(ht|env|git)` тоже не нужна — всё остальное закрывает
  `location /` → 404.
- Доставка шаблона в nginx — той же цепочкой, что у прочих тест-vhost'ов:
  `make testzone-sync` копирует `templates-test/mcp.conf.template` →
  `templates/test-mcp.conf.template` (иначе правка не доезжает до
  `envsubst`, см. [[decision:nginx-template-rendering]]).
- `TEST_MCP_DOMAIN` — обязательная переменная nginx (`:?` в
  `docker-compose.testzone.yml`); без неё `server_name` рендерится пустым и
  `nginx -t` роняет весь деплой тест-зоны.
- Риск на будущее: имя `mcp.*` читается как «весь MCP», что может однажды
  спровоцировать дописать туда `location /api/v1` — единственная страховка
  сейчас — предупреждающий комментарий в самом шаблоне.

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
- [[concept:deployment-topologies]]
- [[decision:voice-dictation]]
- [[decision:nginx-template-rendering]]

## Связанные Beads

- [[bead:ai-box-infra-3q9]] — публичный вхост `mcp.test.doitai.ru`.
