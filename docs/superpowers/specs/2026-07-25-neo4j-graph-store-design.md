# Дизайн: Neo4j Community + GDS в общий стек ai-box-infra

Дата: 2026-07-25
Статус: утверждён к планированию
Задача (наш трекер): `ai-box-infra-<TBD>` (завести при старте работы)
Задача-источник (трекер реестра): `ai-box-dr-drf`
Спека-источник: `ai-box-data-registry:docs/superpowers/specs/2026-07-25-knowledge-graph-storage-design.md` §9

## 1. Контекст и границы

Реестр (`ai-box-data-registry`) вводит графовый слой для knowledge-датасетов на
Neo4j + GDS (алгоритмы Leiden, проекции). На eco-контуре (боевой трафик через
`gateway:8083`) MariaDB/Redis/Qdrant живут в общей инфре `ai-box-infra` — Neo4j
должен появиться там же, рядом с ними. Свой Neo4j реестр поднимает только в
legacy-стеке (`.docker/docker-compose.yml`) для локальной разработки; дублировать
сервис в eco своим compose реестр сознательно не хочет.

Задачу владеет команда `ai-box-infra` (этот репозиторий). Чужой код (реестр) не
трогаем — от нас нужен только живой сервис `neo4j` на сети `ecosystem` и
инфраструктурная обвязка вокруг него.

**Что делаем:** сервис `neo4j` в `docker-compose.yml`; идемпотентная установка
плагина GDS пиненной версии; `.env`/`.env.example`; overlay-ремапы портов;
Makefile-таргеты (fetch плагина, cli, smoke, dump/restore); README; вика +
decision-страница; bead в нашем трекере; валидация.

**Что НЕ делаем:** схему графа (индексы/констрейнты) накатывает реестр своей
идемпотентной командой `neo4j:schema-sync` — не наша часть. Автоматические
бэкапы по крону — отдельный bead `ai-box-infra-4tb` (MariaDB/Qdrant/… по крону);
Neo4j туда доносится в рамках той задачи, здесь — только ручной dump/restore
паритетно текущей инфре.

## 2. Сервис в `docker-compose.yml`

Сервис по шаблону `qdrant` (loopback-публикация, именованный том, сеть
`ecosystem`). Образ — стоковый, без `NEO4J_PLUGINS`: GDS ставим сами (см. §3).

```yaml
  neo4j:
    image: neo4j:${NEO4J_VERSION:-5.26.28-community}
    container_name: infra_neo4j
    restart: unless-stopped
    # Наружу не светим; loopback — ручная диагностика (Bolt + Neo4j Browser).
    # Приложения ходят по сети ecosystem на neo4j:7687 напрямую.
    ports:
      - "127.0.0.1:7687:7687"   # Bolt (клиенты, cypher-shell)
      - "127.0.0.1:7474:7474"   # HTTP Neo4j Browser (диагностика)
    environment:
      NEO4J_AUTH: neo4j/${NEO4J_PASSWORD:?NEO4J_PASSWORD обязателен}
      # Слушать интерфейс контейнера, чтобы app-контейнеры на ecosystem
      # достучались (наружу закрыто loopback-публикацией, как mariadb/qdrant).
      NEO4J_server_default__listen__address: 0.0.0.0
      # GDS требует unrestricted для доступа к внутренним API — иначе процедуры
      # gds.* не грузятся.
      NEO4J_dbms_security_procedures_unrestricted: gds.*
      # Память под RAM хоста (.env, дефолты малы и безопасны для любого сервера —
      # как MARIADB_BUFFER_POOL/REDIS_MAXMEMORY).
      NEO4J_server_memory_heap_initial__size: ${NEO4J_HEAP:-512m}
      NEO4J_server_memory_heap_max__size: ${NEO4J_HEAP:-512m}
      NEO4J_server_memory_pagecache_size: ${NEO4J_PAGECACHE:-512m}
    volumes:
      - neo4j_data:/data
      - ./neo4j/plugins:/plugins:ro    # jar кладём мы (§3); ro — Neo4j только читает
    networks:
      - ecosystem
```

- Имя сервиса `neo4j` = контракт реестра (`bolt://neo4j:7687`).
- Том `neo4j_data` — в блок `volumes:` рядом с `qdrant_data`.
- Bolt 7687 наружу не публикуется (только 127.0.0.1) — контракт §9.
- Env-переменные Neo4j: точки → `_`, `_` в имени сеттинга → `__` (docker-конвенция
  образа neo4j). Ключи выверены под Neo4j 5.x (`server.memory.*`,
  `server.default_listen_address`, `dbms.security.procedures.unrestricted`).

## 3. Установка GDS — идемпотентный fetch (не рантайм-резолвер)

Плагин GDS **не** тянем механизмом `NEO4J_PLUGINS` (он качает при старте
контейнера — egress-зависимость на каждый первый `up`). Вместо этого кладём
пиненный jar сами, заранее, идемпотентно.

- Каталог `neo4j/plugins/` в репозитории: файл-маркер `neo4j/plugins/.gitkeep`,
  в `.gitignore` — строка `neo4j/plugins/*.jar` (бинарь не коммитим).
- Bind-mount `./neo4j/plugins:/plugins:ro` (см. §2). Neo4j при старте сканирует
  `/plugins` и грузит найденные jar'ы.
- **Версия и sha256 GDS пинятся в Makefile** (repo-константы, согласованы с
  `NEO4J_VERSION`), не в `.env` — это не per-host тюнинг.
- Источник jar — **GitHub-релиз** (официальный дистрибутив `graphdatascience.ninja`
  отдаёт 403 без спец-заголовков; GitHub-релиз стабилен и пиннуем).

Пины (проверены фактически 2026-07-25):

| Что | Значение |
|---|---|
| Neo4j образ | `neo4j:5.26.28-community` (последний 5.x, LTS; тег есть на Docker Hub) |
| GDS версия | `2.13.4` (последний патч линии 2.13.x — единственной, совместимой с Neo4j 5.26.x; 2.14+ уже под календарные Neo4j 2025.xx) |
| GDS URL | `https://github.com/neo4j/graph-data-science/releases/download/2.13.4/neo4j-graph-data-science-2.13.4.jar` |
| GDS размер | 64 058 557 Б |
| GDS sha256 | `10e072f73992224f1159f246c9d6a89da5f3b3434aeffa5be42647edda13a8d8` |

Причина, почему пин 5.26.28, а не 5.26.0: на `5.26.0` в докере известен баг
установки GDS (neo4j/neo4j#13563); берём свежий патч.

### Логика `make neo4j-plugins` (идемпотентно)

```
NEO4J_GDS_VERSION ?= 2.13.4
NEO4J_GDS_SHA256  ?= 10e072f73992224f1159f246c9d6a89da5f3b3434aeffa5be42647edda13a8d8
NEO4J_GDS_URL     ?= https://github.com/neo4j/graph-data-science/releases/download/$(NEO4J_GDS_VERSION)/neo4j-graph-data-science-$(NEO4J_GDS_VERSION).jar
NEO4J_PLUGINS_DIR := neo4j/plugins
NEO4J_GDS_JAR     := $(NEO4J_PLUGINS_DIR)/neo4j-graph-data-science-$(NEO4J_GDS_VERSION).jar
```

Алгоритм таргета:
1. Если `$(NEO4J_GDS_JAR)` существует и его sha256 == `$(NEO4J_GDS_SHA256)` →
   печатаем «уже на месте, skip», выходим 0 (идемпотентность).
2. Иначе: удалить любые прочие `neo4j-graph-data-science-*.jar` в каталоге
   (чтобы после смены версии в `/plugins` остался ровно один GDS-jar — два разных
   Neo4j грузить не должен); скачать во временный файл; **жёстко** сверить sha256
   (mismatch → удалить временный, `exit 1`, НЕ запускаться); атомарный `mv` на
   целевое имя; `chmod 644`.

`.tmp` + атомарный `mv` — чтобы прерванная загрузка не оставила «валидный по имени,
битый по содержимому» jar.

## 4. Конфигурация — `.env` / `.env.example`

Добавить в `.env.example`:

```
# Neo4j (граф-хранилище knowledge реестра). Пароль — секрет, точка стыковки с
# реестром: реестр в СВОЁМ .env ставит NEO4J_BOLT_URL=bolt://neo4j:7687,
# NEO4J_USER=neo4j, NEO4J_PASSWORD=<то же значение>.
NEO4J_PASSWORD=
# Версия образа Neo4j (см. docker-compose.yml; версия GDS пинится в Makefile).
#NEO4J_VERSION=5.26.28-community
# Память под RAM хоста (дефолты 512m безопасны; на doitai/прод задать больше).
#NEO4J_HEAP=512m
#NEO4J_PAGECACHE=512m
```

`NEO4J_PASSWORD` — обязательный (по образцу DB-паролей: пустой в примере,
заполняется на хосте). `bolt_url`/`user`/`timeout`/`database` — переменные
**реестра**, в наш `.env` не идут (наш compose их не читает). Значение
`NEO4J_PASSWORD` обязано совпадать в `.env` инфры и в `.env` реестра.

## 5. Overlay-файлы

Bind-mount `/plugins` и том `neo4j_data` — в базовом compose; overlay'и меняют
только публикацию портов (тот же приём, что у `qdrant`):

- `docker-compose.transition.yml` — рядом с работающей старой инфрой:
  ```yaml
    neo4j:
      ports: !override
        - "127.0.0.1:7688:7687"
        - "127.0.0.1:7475:7474"
  ```
- `docker-compose.local.yml` — dev-машина, не публикуем (диагностика через
  `docker exec`):
  ```yaml
    neo4j:
      ports: !override []
  ```

## 6. Makefile-таргеты

По образцу `mariadb-cli`/`redis-cli`/`db-import`:

- `neo4j-plugins` — идемпотентный fetch GDS (§3). Предшаг перед `up`.
- `neo4j-cli` — `docker compose exec neo4j cypher-shell -u neo4j -p "$$NEO4J_PASSWORD"`.
- `neo4j-smoke` — `... cypher-shell ... "RETURN gds.version() AS gds"`; ожидаемый
  вывод — `2.13.4`. Ловит рассинхрон Neo4j↔GDS: несовместимый jar Neo4j не
  загрузит → процедура `gds.version()` не найдётся → smoke красный.
- `neo4j-dump` / `neo4j-restore` — ручной офлайн-дамп community-издания:
  остановить сервис → одноразовым контейнером на том же томе `neo4j_data`
  выполнить `neo4j-admin database dump neo4j --to-path=/backups` (bind
  `./backups`) → поднять сервис. Точная форма команды (`docker compose run --rm`
  vs `stop`+`exec`) финализируется в плане; принцип — БД остановлена на время
  дампа, том сохраняется.

`up` дополнить зависимостью/подсказкой на `neo4j-plugins` (host-дир должна быть
пополнена до старта — иначе GDS не загрузится, smoke это поймает).

Makefile уже читает `.env` (домены, пароли) — `NEO4J_PASSWORD` доступен таргетам.

## 7. Смоук и проверка совместимости

После `up`: `make neo4j-smoke` обязан вернуть `2.13.4`. Это подтверждает: (а) jar
на месте и загрузился; (б) GDS совместим с версией Neo4j (иначе Neo4j отклонил бы
загрузку плагина). Дополнительно — Bolt-connect тем же cypher-shell (`RETURN 1`).

## 8. Документация и вика

- **README** — строка в таблицу инфра-сервисов (`neo4j`, `neo4j:5.26.28-community`,
  сеть `ecosystem`; `127.0.0.1:7687/7474` для диагностики) и `NEO4J_PASSWORD` в
  раздел env/распределения.
- **`.claude/wiki/entities/shared-stack.md`** — строка таблицы сервисов;
  в prod-тюнинг — заметка про `NEO4J_HEAP`/`NEO4J_PAGECACHE`; обновить `updated`.
- **`.claude/wiki/decisions/neo4j-graph-store.md`** (новая) — почему Neo4j в общей
  инфре (а не в eco-compose реестра); почему GDS идемпотентным fetch'ем, а не
  `NEO4J_PLUGINS` (trade-off: сняли egress-зависимость на старт контейнера ценой
  ручного ведения версии+sha256 и предшага fetch перед `up`); пин 5.26.28↔2.13.4
  и обход бага 5.26.0; паритет бэкапов (ручной dump сейчас, крон — в
  `ai-box-infra-4tb`); рассмотренные альтернативы (§ ниже). Секции `## Связи`,
  `## Связанные Beads` (`[[bead:ai-box-infra-<TBD>]]`).
- **`.claude/wiki/index.md`** — добавить строку decision-страницы.
- **`.claude/wiki/log.md`** — запись `ingest`.
- Мелочь для соседей: `wiki_refs: ["integrations/llm-proxy.md"]` в `ai-box-dr-drf`
  к Neo4j отношения не имеет — сообщить команде реестра (сами их метаданные не
  правим).

## 9. Beads (наш трекер)

Завести bead `ai-box-infra`: `--type=task --priority=1`, заголовок «Neo4j
Community + GDS в общий стек (для knowledge-графа реестра)», `--metadata` с
`wiki_refs` на `decisions/neo4j-graph-store.md` и `entities/shared-stack.md`, в
описании — ссылка на источник `ai-box-dr-drf` и на эту спеку. Зависимость-заметка:
автобэкап Neo4j — в рамках `ai-box-infra-4tb`.

## 10. Порядок деплоя (eco)

1. `make neo4j-plugins` (пополнить `neo4j/plugins/` — идемпотентно).
2. Заполнить `NEO4J_PASSWORD` в `.env` (и то же значение в `.env` реестра).
3. `docker compose ... up -d neo4j`.
4. `make neo4j-smoke` → `2.13.4`.
5. На стороне реестра включается `neo4j:schema-sync` (их часть; до появления
   сервиса их шаг штатно no-op по пустому `bolt_url`).

## 11. Валидация (acceptance)

- `docker compose config --quiet` на base и на каждом overlay
  (`-f docker-compose.yml -f docker-compose.transition.yml` и `... local ...`) с
  заполненным окружением — без ошибок.
- `make neo4j-plugins` дважды подряд: первый — скачивает+проверяет, второй —
  «skip» (идемпотентность).
- `up neo4j` → контейнер `healthy`/`running`, в логах нет ошибок загрузки плагина.
- `make neo4j-smoke` → `2.13.4`.
- Bolt-доступ по имени сети: из временного контейнера на `ecosystem`
  `cypher-shell -a bolt://neo4j:7687 ... "RETURN 1"` — успешно.
- 7687 наружу не слушается: `ss -tlnp` на хосте показывает только
  `127.0.0.1:7687` (и `:7474`).

## 12. Риски и trade-off'ы

- **Egress на первый старт контейнера — снят** (в пользу идемпотентного fetch).
  Остаётся egress на `make neo4j-plugins` — контролируемо, до `up`; на air-gapped
  addons jar можно принести руками в `neo4j/plugins/` (sha256 всё равно
  проверится). **Флажок для боевого addons — при раскатке убедиться, что jar на
  месте.**
- **Ведём версию+sha256 GDS руками.** При смене минора Neo4j обязателен пересмотр
  пары Neo4j↔GDS по матрице совместимости и обновление sha256; `neo4j-smoke`
  ловит рассинхрон сразу.
- **Neo4j — новая инфра в эксплуатации.** heap+pagecache едят RAM (дефолт по 512m
  ≈ 1–1.3 ГБ с оверхедом); на слабых хостах ужать, на doitai/прод задать через
  `.env`. Мониторинг/бэкапы — зона `ai-box-infra`.
- **Bind-mount `/plugins:ro`.** Если каталог пуст на момент `up` — GDS не
  загрузится; поймает `neo4j-smoke`, деплой-порядок (§10) ставит fetch первым.

## 13. Рассмотренные альтернативы

- **`NEO4J_PLUGINS=["graph-data-science"]` (рантайм-резолвер).** Отклонено по
  просьбе владельца: egress-зависимость на каждый первый старт контейнера; версия
  GDS неявная (резолвится под патч Neo4j). Идемпотентный fetch даёт явный пин и
  снимает egress со старта.
- **Свой образ (Dockerfile FROM neo4j + jar в build).** Отклонено: самодостаточно,
  но добавляет build-pipeline, которого у остальной инфры (готовые образы) нет;
  на каждый хост — `build`. Fetch в plugins-том проще и не строит образ.
- **Neo4j в eco-стеке реестра.** Отклонено на стороне реестра: eco делит общую
  инфру `ai-box-infra`, дублировать сервис — второй источник инфры.
- **Автобэкап по крону сейчас.** Отложено: такой механики нет и у mariadb/qdrant;
  единая крон-схема бэкапов — bead `ai-box-infra-4tb`, Neo4j доносится туда.

## 14. Затронутые файлы (сводка для плана)

- `docker-compose.yml` — сервис `neo4j`, том `neo4j_data`.
- `docker-compose.transition.yml`, `docker-compose.local.yml` — ремап портов.
- `.env.example` — блок Neo4j.
- `Makefile` — `neo4j-plugins`, `neo4j-cli`, `neo4j-smoke`, `neo4j-dump`,
  `neo4j-restore`; зависимость `up` → `neo4j-plugins`.
- `neo4j/plugins/.gitkeep` (новый), `.gitignore` — `neo4j/plugins/*.jar`.
- `README.md` — таблица сервисов + env.
- `.claude/wiki/entities/shared-stack.md`, `.claude/wiki/decisions/neo4j-graph-store.md`
  (новая), `.claude/wiki/index.md`, `.claude/wiki/log.md`.
