# ai-box-infra

Shared-инфраструктура экосистемы AiBox для прод-сервера: вход (nginx + TLS),
MariaDB, Redis, Qdrant, browserless и общий базовый PHP-образ. Приложения
(ai-box, ai-box-data-registry, ai-box-mcp, ai-box-front, ai-box-pdn-cleaner,
ollama-router с пулом Ollama) живут в своих репозиториях со своими тонкими
compose-стеками и подключаются к общей docker-сети `ecosystem`.

Дизайн и принятые решения: [docs/superpowers/specs/2026-07-03-ecosystem-infra-design.md](docs/superpowers/specs/2026-07-03-ecosystem-infra-design.md).

## Состав стека

| Сервис | Образ | Доступ |
|---|---|---|
| nginx | nginx:1.27-alpine | 80/443 наружу; внутренние vhost'ы 8083 (DR), 8084 (MCP), 8085 (ai-box), 8086 (wiki) — только сеть `ecosystem`, alias `gateway` |
| mariadb | mariadb:11.8 (LTS) | сеть `ecosystem`; 127.0.0.1:3306 хоста для администрирования |
| redis | redis:7.4-alpine | только сеть `ecosystem` |
| qdrant | qdrant/qdrant:v1.12.4 | сеть `ecosystem`; 127.0.0.1:6333 для диагностики |
| neo4j | neo4j:5.26.28-community | сеть `ecosystem`; 127.0.0.1:7687 (Bolt) / 7474 (Browser) для диагностики; GDS 2.13.4 через `make neo4j-plugins` |
| browserless | browserless/chrome | только сеть `ecosystem` |
| certbot | certbot/certbot | одноразовые запуски из Makefile (profile `certs`) |

## Контракты для приложений

**Имена php-fpm контейнеров на сети `ecosystem`** (их ждёт nginx):

- `ai-box-php:9000`
- `ai-box-dr-php:9000`
- `ai-box-mcp-php:9000`

**ai-box-template-wiki-global** (корпоративная wiki, Python) — не php: контейнер
`ai-box-wiki-web:8080` на сети `ecosystem` отдаёт только API (intake, read,
bootstrap, статус). Публичный вход — раздел api-домена:
`https://api.<ROOT_DOMAIN>/wiki/*` (префикс снимает rewrite в
`nginx/templates/api.conf.template`), внутренний — vhost 8086
(`nginx/conf.d/internal-wiki.conf`), потребители ходят на
`http://gateway:8086`. Рядом в том же стеке живёт `ai-box-wiki-pipeline`
(агентский ingest, git push в GitLab) — он наружу не смотрит и через nginx не
ходит. На стендах без вики upstream не резолвится: путь `/wiki/` отдаёт 502,
как и любой другой незапущенный апстрим.

**ai-box-pdn-cleaner** (Python/FastAPI, репозиторий ai-box-bert-ner-train) —
не php и не ходит через nginx: контейнер `ai-box-pdn-cleaner:8000` на сети
`ecosystem`, потребители обращаются по `http://ai-box-pdn-cleaner:8000` с
Bearer-токеном. Требует GPU: на хосте нужен NVIDIA Container Toolkit.
Вместо собственного `pii-redis` использует общий Redis (DB 6).

**ollama-router** (Go-прокси + пул Ollama-инстансов, один на GPU) — тоже
переезжает на этот сервер, **докеризуется** (решено): контейнер
`ollama-router:11434` на сети `ecosystem` + ollama-контейнеры с привязкой
к GPU по UUID, метрики 9090 на loopback хоста для Zabbix. Потребители ходят
через env `OLLAMA_URL`. Gateway сети фиксированный (`172.30.0.1`) — путь к
хостовым сервисам, если такие останутся.

**Пути кода**: и в php-контейнере приложения, и в nginx код смонтирован по
одному пути `/var/www/<имя-репозитория>` (иначе разъедется `SCRIPT_FILENAME`).
На хосте приложения лежат в `${APPS_ROOT}` (по умолчанию `/var/www`).

**Хосты зависимостей в `.env` приложений**:

```
DB_HOST=mariadb
REDIS_HOST=redis
QDRANT_URL=http://qdrant:6333          # только data-registry
NEO4J_BOLT_URL=bolt://neo4j:7687       # только data-registry (+ NEO4J_USER=neo4j, NEO4J_PASSWORD=<секрет стека>)
BROWSERLESS_WS=ws://browserless:3000   # ai-box (demo)
DATA_REGISTRY_URL=http://gateway:8083  # потребители DR
MCP_URL=http://gateway:8084            # потребители MCP (в ai-box: AIBOX_MCP_URL)
AIBOX_BASE_URL=http://gateway:8085     # межсервисные вызовы ai-box (например, из MCP)
WIKI_URL=http://gateway:8086           # потребители корпоративной wiki (MCP-обёртка, бек)
PDN_CLEANER_URL=http://ai-box-pdn-cleaner:8000  # потребители маскирования ПДн
OLLAMA_URL=http://ollama-router:11434           # (или http://172.30.0.1:11434 при systemd-варианте)
```

**Распределение Redis DB-индексов** (один инстанс на всех):

| Приложение | default/queue | cache |
|---|---|---|
| ai-box | 0 | 1 |
| ai-box-data-registry | 2 | 3 |
| ai-box-mcp | 4 | 5 |
| ai-box-pdn-cleaner (сессии масок) | 6 | — |
| резерв | 7 | — |

**Базы MariaDB**: `ai_box`, `ai_box_dr`, `ai_box_mcp` — создаются при первой
инициализации volume (`mariadb/initdb/01-apps.sh`), пароли из
`env/<stend>/secrets.env`.

## Конфигурация: стенды (env-per-stend)

Плоского `.env` больше нет. Конфиг каждой копии стека — каталог стенда:

| Файл | Что | В git |
|---|---|---|
| `env/<stend>/config.env` | несекретное: домены, `APPS_ROOT`, подсеть, версии, тюнинг | да |
| `env/<stend>/testzone.env` | overlay тест-зоны (только стенд с тест-зоной) | да |
| `env/<stend>/secrets.env` | пароли БД/Redis/Neo4j, токен browserless | **нет**, chmod 600 на хосте |
| `env/example/*` | шаблоны с перечнем и описанием всех ключей | да |

Стенд выбирается по приоритету: переменная `STAND` → некоммитный маркер
`./.stand` (одна строка с именем стенда) → `local`. Маркер объявляет стенд на
хосте раз и навсегда — иначе вызов без `STAND=` (cron, CI, руки в ssh) взял бы
конфиг dev-машины. Незнакомый стенд валит `make` сразу. Проверка стенда и
интерполяции: `make config` — печатает `[stand] …` и молча валидирует рендер
(ненулевой код = потерянный ключ). Trade-off'ы —
[decisions/env-per-stend.md](.claude/wiki/decisions/env-per-stend.md), боевая
миграция стендов — [runbook](docs/runbooks/env-per-stend-migration.md).

## Развёртывание пустого сервера

```bash
# 0. Docker + git (+ NVIDIA Container Toolkit — нужен pdn-cleaner'у);
#    клонировать репозитории приложений в ${APPS_ROOT}
# 1. Объявить стенд и настроить слои env
echo <stend> > .stand                          # local | doitai | amulex | новый
$EDITOR env/<stend>/config.env                 # новый стенд — с env/example/config.env
cp env/example/secrets.env env/<stend>/secrets.env
chmod 600 env/<stend>/secrets.env && $EDITOR env/<stend>/secrets.env
make config                                    # exit 0 = все ключи на месте
# 2. Собрать базовый PHP-образ (нужен приложениям до их старта)
make build-base
# 3. Получить сертификат (до первого запуска nginx, порт 80 свободен)
make certs-init
# 4. Поднять shared-стек (создаст сеть ecosystem)
make up
# 5. Поднять стеки приложений в их репозиториях
# 6. Продление сертификатов — в cron хоста (стенд возьмётся из маркера):
#    0 4 * * 1  cd /var/www/ai-box-infra && make certs-renew
```

Штатный деплой на стенде — `make eco-deploy` (build-base + up + идемпотентный
`deploy/post-deploy.sh`, который перерендеривает шаблоны nginx и перечитывает
конфиг). Секреты генерить `openssl rand -hex 24`; символы `#` и `$` в значениях
недопустимы — ломают `-include` в make.

Миграция данных со старого прода (MariaDB-дампы → `make db-import`, volume
Qdrant, storage/ приложений, ollama-модели; Redis не переносится) — по
шагам в секции «Миграция данных» дизайн-спеки. Бесшовный перевод боевого
`ai-box.amulex.ru` на сплит-схему —
[runbook](docs/runbooks/split-cutover-ai-box.md).

## Модели размещения

Стек поддерживает две топологии (в переходный период живут две копии
приложения одновременно, каждая — независимый инстанс этого стека со своими
данными и доменами):

1. **«Всё внутри»** — один GPU-сервер, все стеки вместе, потребители ходят
   по именам сети `ecosystem`.
2. **«Сплит»** — app-сервер без GPU + отдельный GPU-хост с ollama-router и
   pdn-cleaner. Отличие — только env потребителей: `OLLAMA_URL` и
   `PDN_CLEANER_URL` указывают на GPU-хост. Канал между серверами — только
   закрытый (WireGuard; минимум — firewall-allowlist): у ollama-router нет
   авторизации, через pdn-cleaner ходят тексты с ПДн.

## Домены

Раскладка: `app.` — фронт SPA, `api.` — API, `admin.` — админка Filament.
Корневой домен стенда — либо лендинг (репозиторий `ai-box-site`, статика,
`templates/root-landing.conf.template`, переменная `LANDING_DOMAIN`), либо 301
на `app.` (`templates/root-redirect.conf.template`, переменная
`ROOT_REDIRECT_DOMAIN`) — стенд выбирает поведение тем, какую из двух переменных
задаёт в `env/<stend>/config.env`; оба шаблона рендерятся на всех стендах, но
дефолты обеих переменных (`landing.invalid`/`root-redirect.invalid`, заданы в
`docker-compose.yml`) инертны — невыбранный vhost не матчится ничем. Домены
копии задаются в `env/<stend>/config.env`
(`ROOT_DOMAIN`/`FRONT_DOMAIN`/`API_DOMAIN`/`ADMIN_DOMAIN`, опционально
`CERT_NAME`, по умолчанию = ROOT_DOMAIN) — публичные vhost'ы рендерятся из
`nginx/templates/*.template` при старте контейнера nginx, сертификат один с SAN
на все домены стенда (`DOMAINS` в Makefile: четыре публичных + домены тест-зоны,
если её слой подключён).

Порядок важен: сначала shared-стек (сеть, БД), затем приложения. nginx
переживает отсутствие/рестарт приложений — upstream'ы резолвятся на лету.

## Локальная разработка (dev-машина)

Dev-окружение живёт на этой же схеме (переведено 2026-07-03):

```bash
make build-base-dev            # база + вариант с xdebug (aibox/php-base:8.3-dev)
echo local > .stand            # стенд dev-машины (env/local/config.env — в git:
                               # домены *.ai-box.local, свободная подсеть, версии)
cp env/example/secrets.env env/local/secrets.env   # dev-dummy пароли
chmod 600 env/local/secrets.env && $EDITOR env/local/secrets.env
# dev-оверлей (ремап портов: nginx 8090, mariadb 3310, neo4j на loopback) —
# симлинком, чтобы его подхватывали ВСЕ make-цели, а не только ручной вызов:
ln -sf docker-compose.local.yml docker-compose.override.yml
make config                    # exit 0 + [stand] local
make certs-selfsigned          # self-signed SAN-серт в volume letsencrypt
make up
# /etc/hosts: 127.0.0.1 ai-box.local app.ai-box.local api.… admin.…
```

Без симлинка `docker-compose.override.yml` цели `make` работают с боевыми
портами (80/443, 3306) — оверлей нужно было бы передавать руками каждый раз:
`docker compose --env-file env/local/config.env --env-file env/local/secrets.env
-f docker-compose.yml -f docker-compose.local.yml up -d`.

В `.env` каждого приложения — dev-переопределения eco-стека:
`PHP_BASE_IMAGE=aibox/php-base:8.3-dev`, `PHP_INI=./php/local.ini`,
`PHP_UID/PHP_GID=1000` + обязательные `REDIS_DB`/`REDIS_CACHE_DB` и
межсервисные URL через `gateway` (см. контракты выше). Стек приложения:
`docker compose --env-file .env -f .docker/docker-compose.ecosystem.yml up -d`.
