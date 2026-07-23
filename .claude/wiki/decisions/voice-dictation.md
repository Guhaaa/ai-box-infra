---
title: Проксирование потока голосовой диктовки (ASR ws-stream + auth_request)
type: decision
tags: [nginx, asr, websocket, auth, voice]
sources: [nginx/templates/api.conf.template, nginx/templates-test/api.conf.template, docker-compose.yml, .env.example]
updated: 2026-07-23
---

# Проксирование потока голосовой диктовки

Голосовой ввод в чате ai-box: браузер открывает WebSocket-поток PCM-аудио,
наш nginx авторизует его подзапросом к Laravel (`auth_request`) и проксирует
на **внешний ASR-сервис** (FastAPI, эндпоинт `/api/v1/asr/ws-stream`). Laravel
в потоке аудио не участвует — только отвечает 2xx/403 на короткий подзапрос до
апгрейда. Контракт (URL, коды, поведение) — на стороне ai-box; бриф-источник —
`docs/briefs/2026-07-23-voice-dictation-infra-brief.md` (в репозитории ai-box).

## Что добавлено в vhost API

Две локации в шаблоне API-домена (`nginx/templates/api.conf.template` — local и
оба прода; `nginx/templates-test/api.conf.template` — тест-зона):

- **ws-локация** `~ "^/api/(?:assistant|i/[^/]+)/session/<ULID>/asr/stream$"` —
  `auth_request` → `rewrite ^ /api/v1/asr/ws-stream break` → `proxy_pass` на ASR
  с апгрейдом (`Upgrade`/`Connection`), `proxy_buffering off`, таймауты 600с;
- **внутренний подзапрос** `= /internal/asr-authorize` (`internal;`) — fastcgi в
  тот же Laravel (`$ai_box_upstream` / `$ai_box_test_upstream`), с
  переопределённым `SCRIPT_FILENAME=$document_root/index.php`,
  `REQUEST_URI=/api/internal/asr/authorize` и заголовком
  `HTTP_X_ORIGINAL_URI $request_uri` (подзапрос не наследует исходный URI).

## Почему так — нетривиальные решения

- **`location /api` без `^~`.** Префиксная локация с `^~` при матче **отменяет
  разбор regex-локаций** — ws-локация ниже никогда бы не получила управление.
  Сняли `^~`. Побочный нюанс: `/api/*.php`-пути теперь попадают в
  `location ~ \.php$` (было — в try_files→index.php); в Laravel таких легитимных
  путей нет, обе ветки дают 404, поведение приемлемо.
- **Регэксп в кавычках.** Без кавычек nginx принимает `{26}` (квантор ULID) за
  открытие блока и падает на старте.
- **`rewrite … break` вместо пути в `proxy_pass`.** В regex-локации
  `proxy_pass` не принимает URI-часть («cannot have URI part») — целевой путь
  задаём отдельным `rewrite ^ /api/v1/asr/ws-stream break`.
- **Явное переопределение `SCRIPT_FILENAME`/`SCRIPT_NAME` после include.**
  `snippets/php-fastcgi.conf` ставит `SCRIPT_FILENAME=$document_root$fastcgi_script_name`,
  но в подзапросе `auth_request` `$fastcgi_script_name` пуст → без переопределения
  php-fpm получил бы каталог вместо `index.php`. Это осознанно, не дубль.
- **Адрес ASR — переменная `ASR_WS_UPSTREAM`, не хардкод.** Для разных стендов
  адрес свой. Литерал подставляется envsubst'ом на старте контейнера, поэтому в
  `proxy_pass` `resolver` не нужен (в отличие от `fastcgi_pass`-переменной).

## `ASR_WS_UPSTREAM` — почему инертный дефолт, а не `:?`

В `docker-compose.yml` (`nginx.environment`): `ASR_WS_UPSTREAM: ${ASR_WS_UPSTREAM:-127.0.0.1:9}`.
Официальный образ nginx подставляет через envsubst только переменные, **объявленные
в окружении контейнера** — без строки в `environment` `${ASR_WS_UPSTREAM}` в
шаблоне отрендерился бы пусто (`proxy_pass http://;`) и `nginx -t` упал бы.
Дефолт **инертный** (127.0.0.1:9), а не обязательный `:?`, сознательно: шаблон
`api.conf.template` рендерится на **всех** стендах (local/amulex/doitai), и
обязательная переменная сделала бы новую голосовую фичу поводом падать nginx на
стендах, где голос не используется. Локация реально активна лишь после успешного
`auth_request` (т.е. когда `asr.enabled` в самом ai-box), поэтому инертный
адрес безвреден. Стенд с голосом задаёт реальный адрес в `.env`
(doitai — выделенный GPU-бокс в LAN).

## Наш репозиторий: два исходника, не три

Бриф ai-box описывает «три извода» и в т.ч. `nginx/conf.d/api.conf` как
статический локальный конфиг. У нас `conf.d/{api,front,admin,root}.conf` —
**рендер-артефакты envsubst** (в `.gitignore`), а не исходники. Источников два:
`templates/api.conf.template` (local + оба прода, различие — только `.env`) и
`templates-test/api.conf.template` (тест-зона, `testzone-enable` копирует его в
`templates/test-api.conf.template`). Править `conf.d/*.conf` бессмысленно —
перезатрётся на старте. Отдельного статического локального конфига нет.

## Firewall на ASR-хосте — понижен до необязательного

Эндпоинт ASR не имеет своей авторизации — наш `auth_request` единственный гейт,
и в общем случае ASR-порт следовало бы закрыть ото всех, кроме IP nginx-хостов
(иначе кто угодно на LAN грузит GPU в обход тарифа). Но на doitai это
**выделенный GPU-бокс на полностью доверенной односегментной LAN** без чужих
арендаторов — тарифный обход доступен лишь тому, у кого уже есть доступ к самому
боксу. Поэтому для нашей топологии пункт firewall — «желательно, не блокер»
(в приёмке брифа — п.6). При появлении в подсети недоверенных хостов вернуть в
критичные.

## Раскатано на doitai (2026-07-23)

- `ASR_WS_UPSTREAM=192.168.100.29:49153` дописан в серверный `.env` doitai;
- инфра-коммит доставлен CI (`deploy-doitai.yml`): прод-vhost `conf.d/api.conf`
  отрендерил ASR-локацию с реальным адресом (инертна — прод-ai-box `asr.enabled=false`);
- дев-контур (`test.doitai.ru`): `make testzone-enable` пере-копировал тест-шаблон
  (гоча: `templates/test-*.conf.template` — копии, CI-`up` их не обновляет) и
  пересоздал nginx;
- **достижимость подтверждена**: `nc -vz 192.168.100.29 49153` из nginx-контейнера
  → `open` (снимает вопрос №1 брифа);
- закрытый гейт → **403** на обеих поверхностях тест-домена `api.test.doitai.ru`.

## Осталось

- **Открытый гейт** (полный поток → `last_message`) — зависит от app-стороны:
  `asr.enabled=true` + ассистент с `voice_input_enabled` + сессия в тест-ai-box
  (питон-зонд из брифа). Вне инфры — задача ai-box (`ai-box-back-y1dn`).
- **amulex** — второй прод, инфра-коммит в origin/master есть, но amulex деплоится
  отдельно (не `deploy-doitai.yml`); раскатка голоса там — отдельным шагом по
  runbook (прод чувствительнее doitai).
- (опц.) firewall на ASR-хосте — понижен (см. выше).

## Проверено (локально + на doitai)

`nginx -t` чист на обоих шаблонах (локально: прод — полным рендером, тест —
изолированным; на doitai — оба отрендерены и загружены). Закрытый гейт → **403**
на обеих поверхностях
(`/api/assistant/...` и `/api/i/{integration}/...`) с валидным 26-символьным
ULID; 403 (а не 500) подтверждает, что роут `/api/internal/asr/authorize` в
ai-box существует и активно отказывает. Env-per-stend (спека
`docs/superpowers/specs/2026-07-08-env-per-stend-design.md`, bead
`ai-box-infra-11l` — ещё не построен): пока `ASR_WS_UPSTREAM` живёт в плоском
`.env`; когда доедет — переедет в `env/<stend>/config.env`.

## Связи

- [[entity:nginx-edge]]
- [[concept:contracts]]
- [[integration:app-stacks]]

## Связанные Beads

- [[bead:ai-box-infra-0fq]] — эта задача (перенос nginx-локаций из брифа ai-box).
- [[bead:ai-box-infra-11l]] — env-per-stend; будущий дом для `ASR_WS_UPSTREAM`.

## Источники

- бриф — `docs/briefs/2026-07-23-voice-dictation-infra-brief.md` (репозиторий ai-box).
