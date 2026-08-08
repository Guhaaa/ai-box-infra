# Дизайн: graphiti-sidecar → shared-сервис в стеке ai-box-infra

Дата: 2026-08-08
Статус: утверждён к планированию
Задача (наш трекер): `ai-box-infra-vl8`
Эпик-источник (трекер реестра): `ai-box-dr-v18`
Смежные задачи: `ai-box-back-pssf` (LLM-прокси, ai-box),
`ai-box-dr-b84`/`ai-box-dr-cb3`/`ai-box-dr-emj` (shared-контракт сайдкара, DR)

## 1. Контекст и границы

Сайдкар Graphiti (`ai-box-data-registry/sidecar/graphiti`) — FastAPI-сервис
графового инжеста/поиска поверх Neo4j. До сих пор он деплоился eco-compose'ом
реестра (`.docker/docker-compose.ecosystem.yml`, строка
`up -d --build graphiti-sidecar` в `eco-deploy`). По эпику `ai-box-dr-v18` у
сайдкара появляется второй потребитель — корпоративная вики
(`ai-box-template-wiki-global`), и релизы DR не должны давать окон
недоступности инжеста вики. Сайдкар становится shared-сервисом и переезжает в
общий стек — рядом с Neo4j, которым он пользуется.

Фактическое состояние на doitai: сайдкар поднят только тест-контуром DR
(`ai-box-dr-test-graphiti`) и **крашлупится с момента запуска** — переменные
`GRAPHITI_LLM_*`/`EMBEDDER_*` не заданы, а graphiti-core требует непустой
API-ключ эмбеддера при старте. Прод-контур DR сайдкар не поднимает вовсе.
То есть переносим не живой сервис, а впервые разворачиваем его рабочую
конфигурацию.

**Что делаем:** сервис `graphiti-sidecar` в `docker-compose.yml` инфры
(build из checkout'а DR, image `aibox/graphiti-sidecar`); `--build` в цели
`up`; env-per-stend (`env/example`, `env/doitai`); README-контракты; вика
(decision-страница + shared-stack + index/log).

**Что НЕ делаем:** выпил сайдкара из eco-контура DR (compose + Makefile) —
отдельный bead в трекере DR под эпиком `ai-box-dr-v18`; legacy-стек DR
(локальная разработка, свой Neo4j + свой сайдкар) не трогаем вообще; код
сайдкара (X-Consumer, group_id-префиксы) — дочерние задачи эпика в DR; сам
LLM-прокси — `ai-box-back-pssf` (ai-box).

## 2. Решения и trade-off'ы

| Решение | Выбор | Почему |
|---|---|---|
| Кто собирает образ | Инфра: `build:` из `${APPS_ROOT}/ai-box-data-registry/sidecar/graphiti` + `image: aibox/graphiti-sidecar` | Registry в экосистеме нет, всё собирается на сервере. Прецедент — nginx уже монтирует код приложений из `APPS_ROOT`. Trade-off: обновление кода сайдкара требует `git pull` DR + деплой инфры — осознанно, релизный цикл сайдкара отвязан от релизов DR (мотивация эпика) |
| Альтернатива: DR публикует тег, инфра только `image:` | Отклонена | Деплой DR получил бы право трогать чужой стек, а окно рестарта осталось бы привязанным к релизам DR — противоречит мотивации |
| Имя сервиса | `graphiti-sidecar` | DNS-контракт: реестр уже ходит на `http://graphiti-sidecar:8000` (`GRAPHITI_BASE_URL`), вики будет ходить так же. `container_name: infra_graphiti` — по конвенции инфры |
| Сборка на деплое | Цель `up` → `$(COMPOSE) up -d --build` | `--build` пересобирает только сервисы с ключом `build:` — ровно сайдкар (остальные image-only). `eco-deploy` не меняется. Требование «checkout DR существует по `${APPS_ROOT}`» — на всех трёх стендах выполняется, документируем в env/example |
| LLM-путь на doitai | Прокси ai-box: `http://gateway:8085/api/internal/llm/v1` (LLM и эмбеддер) | Спека `ai-box:2026-07-27-openai-compatible-proxy-design.md`: chat — по каталогу `llm_models` с тарификацией, эмбеддинги — Ollama, бесплатно. Внутренний vhost `internal-ai-box.conf` (8085) в инфре уже есть |
| API-ключи при прокси | Дефолт-заглушка `internal` прямо в compose (`${GRAPHITI_LLM_API_KEY:-internal}`) | Прокси игнорирует `Authorization` (доступ закрыт сетью + `EnsureInternalNetwork`), openai-клиент требует лишь непустую строку, а пустой ключ роняет сайдкар в краш-луп на старте (§3). Секретом ключ становится только при прямом внешнем провайдере — тогда в secrets.env (документируем в example) |
| Новые секреты | Нет | `NEO4J_PASSWORD` уже в `env/<стенд>/secrets.env` — переиспользуем |

## 3. Сервис в docker-compose.yml

Рядом с `neo4j`:

```yaml
graphiti-sidecar:
  build: ${APPS_ROOT:-/var/www}/ai-box-data-registry/sidecar/graphiti
  image: aibox/graphiti-sidecar
  container_name: infra_graphiti
  restart: unless-stopped
  depends_on:
    - neo4j
  environment:
    NEO4J_URI: bolt://neo4j:7687
    NEO4J_USER: neo4j
    NEO4J_PASSWORD: ${NEO4J_PASSWORD:?}
    LLM_BASE_URL: ${GRAPHITI_LLM_BASE_URL:-}
    LLM_API_KEY: ${GRAPHITI_LLM_API_KEY:-internal}
    EMBEDDER_BASE_URL: ${GRAPHITI_EMBEDDER_BASE_URL:-}
    EMBEDDER_API_KEY: ${GRAPHITI_EMBEDDER_API_KEY:-internal}
    DEFAULT_MODEL: ${GRAPHITI_DEFAULT_MODEL:-}
    DEFAULT_EMBEDDING_MODEL: ${GRAPHITI_DEFAULT_EMBEDDING_MODEL:-}
    DEFAULT_EMBEDDING_DIM: ${GRAPHITI_DEFAULT_EMBEDDING_DIM:-1536}
    SEMAPHORE_LIMIT: ${GRAPHITI_SEMAPHORE_LIMIT:-10}
    KNOWN_CONSUMERS: ${GRAPHITI_KNOWN_CONSUMERS:-dr,wiki}
  healthcheck:
    test: ["CMD-SHELL", "python -c \"import urllib.request;urllib.request.urlopen('http://localhost:8000/healthz')\" || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 12
  networks:
    - ecosystem
```

Отличия от DR-compose: добавлены `DEFAULT_EMBEDDING_DIM` и `KNOWN_CONSUMERS`
(есть в `config.py` сайдкара, в DR-compose не пробрасывались), `NEO4J_PASSWORD`
обязателен (`:?` — как у сервиса `neo4j`; сайдкар без пароля бесполезен),
`depends_on: neo4j`. Порт наружу/на loopback не публикуем: потребители ходят по
сети `ecosystem`, диагностика — `docker exec`/healthcheck.

Дефолт ключей — `internal`, а не пусто: graphiti-core создаёт `OpenAIEmbedder`
уже на старте (`init_schema`), и пустой ключ роняет процесс в краш-луп — именно
так сайдкар умирал в тест-контуре DR на doitai. С заглушкой сервис стартует на
любом стенде; для канонического пути (прокси) заглушка и есть рабочее значение
(Authorization игнорируется), а стенд с прямым внешним провайдером без
реального ключа получит громкий 401 на первом вызове вместо краш-лупа.

Дефолты `DEFAULT_MODEL`/`DEFAULT_EMBEDDING_MODEL` в compose — пустые, а не
`gpt-4o-mini`/`text-embedding-3-small` как в DR-compose: при работе через
прокси коды моделей — из каталога `llm_models`, и молчаливый OpenAI-дефолт дал
бы 422 `MODEL_NOT_FOUND`; пусть незаполненный стенд падает громко на первом
вызове (сам сайдкар при этом стартует — модель уходит в тело запроса).

## 4. Makefile

Единственная правка — цель `up`:

```make
up: neo4j-plugins
	$(COMPOSE) up -d --build
```

Комментарий к цели дополняется: `--build` пересобирает образ сайдкара из
checkout'а DR (`${APPS_ROOT}/ai-box-data-registry`); слои pip кэшируются,
пересборка без изменений кода — секунды.

## 5. Env-per-stend

`env/example/config.env` — новый закомментированный блок:

```
# Graphiti-сайдкар (образ собирается из ${APPS_ROOT}/ai-box-data-registry/
# sidecar/graphiti — checkout DR обязан существовать на стенде).
# Канонический LLM-путь — внутренний прокси ai-box (тарификация, эмбеддинги
# через Ollama бесплатно); ключи при этом — непустые заглушки (Authorization
# прокси игнорирует). Прямой внешний провайдер тоже возможен: тогда base_url
# провайдера, а РЕАЛЬНЫЕ ключи — в secrets.env, не здесь.
#GRAPHITI_LLM_BASE_URL=http://gateway:8085/api/internal/llm/v1
#GRAPHITI_EMBEDDER_BASE_URL=http://gateway:8085/api/internal/llm/v1
# Ключи: при прокси не нужны (дефолт-заглушка internal уже в compose);
# при прямом провайдере реальные значения — в secrets.env.
# Коды моделей — из каталога llm_models ai-box (kind=chat / kind=embedding)
#GRAPHITI_DEFAULT_MODEL=
#GRAPHITI_DEFAULT_EMBEDDING_MODEL=
#GRAPHITI_DEFAULT_EMBEDDING_DIM=1536
#GRAPHITI_SEMAPHORE_LIMIT=10
#GRAPHITI_KNOWN_CONSUMERS=dr,wiki
```

`env/doitai/config.env` — рабочие значения: оба base_url на прокси, коды
моделей — **после посадки `ai-box-back-pssf`** (каталожный код чат-модели и
одной из Ollama-эмбеддинг-моделей + её размерность; сеются миграцией pssf).
До уточнения — переменные вписаны с пустыми значениями и
комментарием-указателем на pssf: сервис стартует, инжест заработает после
заполнения (см. §3 про громкое падение вызова).

`env/local/config.env` — тот же блок с base_url на прокси (eco-стек it11 несёт
`internal-ai-box.conf`, `gateway:8085` резолвится): сайдкар на local-стенде
стартует и проходит healthcheck; ключи не нужны (дефолт compose).

`env/example/secrets.env` — только комментарий в существующем духе: реальные
LLM-ключи (если стенд ходит к провайдеру напрямую) живут здесь.

## 6. Порядок ввода и переходный период

1. Мёрж и деплой инфры (`STAND=doitai make eco-deploy`) — сайдкар поднимается,
   `/healthz` зелёный независимо от готовности прокси (LLM зовётся только на
   инжесте).
2. Деплой `ai-box-back-pssf` (сегодня) → вписать коды моделей в
   `env/doitai/config.env` → `make up` (пересоздаст контейнер с новым env).
3. Bead в DR: выпил сайдкара из eco-compose и `eco-deploy` (вне vl8).

Переходный период: на doitai может сосуществовать `ai-box-dr-test-graphiti` —
он в крашлупе и в DNS сети практически не светится (нерабочий контейнер не
резолвится), поэтому неоднозначность имени `graphiti-sidecar` маловероятна и
временна — до выпила на стороне DR.

**Внешняя зависимость / риск:** прокси требует обязательный `X-Client-Id`
(ULID тенанта, иначе 400 `CLIENT_ID_MISSING`), а сайдкар шлёт только
`X-Consumer: dr|wiki` (`ai-box-dr-cb3`). Нестыковку обязаны примирить pssf/cb3
— вне vl8, но пока она не решена, инжест через прокси будет получать 400.
Зафиксировано на decision-странице; на функциональность этого переноса
(живой сервис + правильный env) не влияет.

## 7. Контракты (README) и вика

README: строка в таблицу сервисов (`graphiti-sidecar` / `aibox/graphiti-sidecar`
(build из DR) / сеть `ecosystem`, без публикации портов, healthcheck
`/healthz`); в раздел env — блок `GRAPHITI_*`; в контрактах — DNS-имя
`http://graphiti-sidecar:8000`, потребители: ai-box-data-registry и
ai-box-template-wiki-global.

Вика: новая `decisions/graphiti-sidecar-shared.md` (почему shared, сборка
инфрой из чужого репо, отклонённая альтернатива, риск X-Client-Id/X-Consumer,
`[[bead:ai-box-infra-vl8]]` + связи с neo4j-страницей и shared-stack);
обновить `entities/shared-stack.md`, `index.md`, `log.md`; в метаданные vl8 —
`wiki_refs`.

## 8. Валидация

- `make config` (STAND=local) и рендер compose с env doitai — интерполяция чистая;
- локальная сборка образа (`docker compose ... build graphiti-sidecar`);
- подъём на local-стенде (infra_neo4j на it11 живой): контейнер `healthy`,
  `curl http://localhost:8000/healthz` изнутри контейнера — 200;
- деплой doitai — по шагам §6, вне этой задачи кода.
