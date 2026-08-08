---
title: Graphiti-сайдкар — shared-сервис, собираемый инфрой из репозитория DR
type: decision
tags: [docker, compose, graphiti, neo4j, llm, data-registry, wiki-global]
sources: [docker-compose.yml, Makefile, env/example/config.env, docs/superpowers/specs/2026-08-08-graphiti-sidecar-shared-design.md]
updated: 2026-08-08
---

# Graphiti-сайдкар в общем стеке

Сайдкар Graphiti (FastAPI, графовый инжест/поиск поверх [[decision:neo4j-graph-store]])
переехал из eco-compose реестра в этот стек: у него два потребителя (реестр и
корпоративная вики ai-box-template-wiki-global, эпик `ai-box-dr-v18`), и релизы
DR не должны давать окон недоступности инжеста вики. Имя сервиса
`graphiti-sidecar` — DNS-контракт (`http://graphiti-sidecar:8000`), контейнер —
`infra_graphiti`.

## Сборка: инфра, из чужого репозитория

Registry в экосистеме нет — образ `aibox/graphiti-sidecar` собирает этот стек
из `${APPS_ROOT}/ai-box-data-registry/sidecar/graphiti` (`build:` + `image:` в
compose, `--build` в цели `up`; `--build` пересобирает только сервисы с ключом
`build:` — это ровно сайдкар). Прецедент доступа к чужому checkout'у — nginx
уже монтирует код приложений из `APPS_ROOT`. Trade-off: обновление кода
сайдкара = `git pull` DR + `make up` инфры — осознанно, релизный цикл отвязан
от релизов DR. Отклонённая альтернатива (DR публикует тег, инфра только
`image:`): деплой DR получил бы право трогать чужой стек, а окно рестарта
осталось бы привязанным к релизам DR.

## LLM-путь и ключи

Канонический путь — внутренний OpenAI-совместимый прокси ai-box
(`http://gateway:8085/api/internal/llm/v1`, спека `ai-box-back-pssf`): чат —
по каталогу `llm_models` с тарификацией, эмбеддинги — Ollama, бесплатно.
Прокси игнорирует `Authorization`, поэтому дефолт ключей в compose —
заглушка `internal`. Пустым ключ быть не может: graphiti-core создаёт
эмбеддер на старте процесса, и пустой ключ роняет контейнер в краш-луп —
именно так сайдкар тест-контура DR умирал на doitai с момента запуска.
Дефолты кодов моделей пустые (не OpenAI'шные): незаполненный стенд падает
громко на первом вызове (422 от прокси), а не молча ходит мимо каталога.

## Порядок ввода и риски

1. Деплой инфры → сайдкар поднят, `/healthz` зелёный (LLM зовётся только на
   инжесте). 2. Посадка `ai-box-back-pssf` → вписать коды моделей в
   `env/doitai/config.env`, `make up`. 3. Выпил сайдкара из eco-compose DR —
   отдельный bead в трекере DR (до него на doitai временно сосуществует
   крашлупящийся `ai-box-dr-test-graphiti`; в DNS он почти не светится).

**Открытый риск (вне этой задачи):** прокси требует обязательный
`X-Client-Id` (ULID тенанта, иначе 400), сайдкар шлёт `X-Consumer: dr|wiki`
(`ai-box-dr-cb3`) — нестыковку обязаны примирить pssf/cb3, до этого инжест
через прокси будет получать 400.

## Связи

- [[decision:neo4j-graph-store]]
- [[entity:shared-stack]]
- [[concept:contracts]]
- [[decision:env-per-stend]]

## Связанные Beads

- [[bead:ai-box-infra-vl8]] — перенос деплоя (этот репозиторий)
