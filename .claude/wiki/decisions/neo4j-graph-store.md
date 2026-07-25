---
title: Neo4j + GDS в общем стеке
type: decision
tags: [docker, compose, neo4j, gds, infrastructure, data-registry]
sources: [docker-compose.yml, Makefile, neo4j/plugins, docs/superpowers/specs/2026-07-25-neo4j-graph-store-design.md]
updated: 2026-07-25
---

# Neo4j Community + GDS в общем стеке

Реестр (`ai-box-data-registry`) вводит графовый слой для knowledge-датасетов на
Neo4j + GDS. На eco-контуре БД/Qdrant/Redis живут в общей инфре — Neo4j встаёт
туда же, сервисом `neo4j` на сети `ecosystem` (`bolt://neo4j:7687`). Владелец —
ai-box-infra; схему графа накатывает реестр (`neo4j:schema-sync`), от нас — живой
сервис.

## Почему в общей инфре, а не в eco-стеке реестра

По Makefile реестра дефолтный STACK=eco берёт mariadb/redis/qdrant из
ai-box-infra. Свой Neo4j реестр поднимает только в legacy-стеке (локальная
разработка/интеграционные тесты). Дублировать сервис в eco его compose = второй
источник инфры. Поэтому Neo4j — здесь, рядом с qdrant.

## GDS ставим сами, идемпотентно (не NEO4J_PLUGINS)

`NEO4J_PLUGINS=["graph-data-science"]` тянет GDS при старте контейнера — egress
на каждый первый `up` и неявная версия. Вместо этого: стоковый образ
`neo4j:5.26.28-community` + `make neo4j-plugins` кладёт пиненный jar
(`neo4j-graph-data-science-2.13.4.jar`, sha256-сверка) в `neo4j/plugins/`,
bind-mount `:/plugins:ro`. Trade-off: сняли egress со старта контейнера ценой
ручного ведения пары версия+sha256 и предшага fetch перед `up`. `make
neo4j-smoke` (`RETURN gds.version()`) ловит рассинхрон сразу.

## Пин версий Neo4j↔GDS

Neo4j 5.26 — последний 5.x (LTS). GDS-линия под 5.26.x — только 2.13.x (2.14+
уже под календарные Neo4j 2025.xx); берём последний патч 2.13.4. Патч Neo4j —
5.26.28 (на 5.26.0 известен баг установки GDS в докере, neo4j/neo4j#13563). При
смене минора Neo4j пару пересматривать по матрице совместимости GDS.

## Бэкапы

Ручной `make neo4j-dump`/`neo4j-restore` (офлайн-дамп community) — паритет с
текущей инфрой (у mariadb/qdrant авто-бэкапов в репо тоже нет). Единая крон-схема
бэкапов — [[bead:ai-box-infra-4tb]], Neo4j доносится туда.

## Риск для air-gapped прод

GDS-jar тянется на `make neo4j-plugins` (не на старте контейнера). На addons с
закрытым egress jar приносится в `neo4j/plugins/` руками — sha256 всё равно
проверится.

## Связи

- [[entity:shared-stack]]
- [[concept:deployment-topologies]]

## Связанные Beads

- [[bead:ai-box-infra-f15]] — реализация (этот репозиторий)
- [[bead:ai-box-infra-4tb]] — крон-бэкапы (Neo4j доносится)
