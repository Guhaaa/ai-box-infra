---
title: Рендер nginx-шаблонов при деплое, а не только на старте контейнера
type: decision
tags: [nginx, deploy, ci, templates, testzone]
sources: [Makefile, .github/workflows/deploy-doitai.yml, nginx/templates, nginx/templates-test]
updated: 2026-07-24
---

# Рендер nginx-шаблонов при деплое

- **Дата решения:** 2026-07-24 ([[bead:ai-box-back-99co]]).
- **Статус:** реализовано в `Makefile` (`nginx-render`, `testzone-sync`).

## Проблема

Конфиги `nginx/conf.d/*.conf` на хосте — не исходники, а **рендер** `envsubst` из
`nginx/templates/*.template`. Рендер выполняет штатный entrypoint образа nginx
(`/docker-entrypoint.d/20-envsubst-on-templates.sh`) — то есть **только при старте
контейнера**.

CI-деплой (`deploy-doitai.yml`) делал `git pull && make build-base && make up &&
make nginx-reload`, где `nginx-reload` — это `nginx -s reload`. Reload перечитывает
`conf.d`, но не перерендеривает шаблоны, а `make up` не пересоздаёт контейнер, если
compose-описание не изменилось. Итог: **правка шаблона доезжает до хоста, деплой
отчитывается успехом, а nginx работает по старому конфигу — молча.**

Поймано на выкатке deny-блока `/api/internal/` ([[bead:ai-box-back-qhdg]]): шаблоны
обновились, `conf.d` — нет; проверка `grep` в отрендеренном конфиге показала отсутствие
блока, применять пришлось руками.

Вторая половина той же проблемы: тестовые vhost'ы рендерятся из
`nginx/templates/test-*.conf.template`, которые являются **копиями**
`nginx/templates-test/*` — их делает `testzone-enable`. Правка `templates-test/` без
повторного копирования не применяется тем же образом.

## Решение

1. **`nginx-render`** — прогоняет штатный envsubst-скрипт **внутри работающего
   контейнера**. Даёт актуальный `conf.d` без пересоздания контейнера и без даунтайма.
2. **`testzone-sync`** — копирование `templates-test/* → templates/test-*.template`,
   вынесенное из `testzone-enable`. Гард по симлинку `docker-compose.override.yml`:
   на хостах без тест-зоны — no-op. Вызывается из `nginx-render`.
3. **`nginx-reload` = рендер → `nginx -t` → reload.** Порядок обязателен: проверять
   надо уже отрендеренный конфиг, иначе reload подхватит непроверенное.
4. `testzone-enable` переиспользует `testzone-sync` (сначала симлинк, потом копии),
   дублирование `cp`-строк снято.

CI трогать не потребовалось — он и так зовёт `make nginx-reload`.

## Trade-off'ы и риски

- Рендер зависит от пути скрипта в образе (`/docker-entrypoint.d/20-envsubst-on-templates.sh`).
  Смена образа nginx на несовместимый по layout уронит деплой — заметно и сразу, что
  лучше прежнего молчаливого no-op.
- Битый шаблон теперь роняет `nginx -t` на деплое и останавливает `make` до reload:
  работающий nginx продолжает жить на старом конфиге в памяти, но `conf.d` на диске
  остаётся битым — следующий рестарт контейнера не поднимется. Проверять шаблоны до
  пуша: рендер `envsubst` + `nginx -t` в одноразовом `nginx:1.27` (так проверялся
  deny-блок в [[bead:ai-box-back-qhdg]]).
- `docker compose exec` требует поднятого nginx: на пустом хосте `nginx-reload` не
  сработает — там сценарий `make up`, который рендерит через entrypoint сам.

## Уроки

- Артефакт-в-репозитории (`conf.d` рядом с `templates`) провоцирует ровно эту ошибку:
  «поправил файл, который никто не читает». Истина — шаблон, `conf.d` — производное.
- Зелёный деплой не равен применённой правке. Проверка после выкатки должна смотреть
  на **фактический** конфиг (`grep` в отрендеренном файле, а не в исходнике).

## Связи

- [[concept:deployment-topologies]]
- [[decision:voice-dictation]]

## Связанные Beads

- [[bead:ai-box-back-99co]] — этот баг и починка.
- [[bead:ai-box-back-qhdg]] — выкатка, на которой проблема вскрылась.
