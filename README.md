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
| nginx | nginx:1.27-alpine | 80/443 наружу; внутренние vhost'ы 8083 (DR), 8084 (MCP) — только сеть `ecosystem`, alias `gateway` |
| mariadb | mariadb:11.8 (LTS) | сеть `ecosystem`; 127.0.0.1:3306 хоста для администрирования |
| redis | redis:7.4-alpine | только сеть `ecosystem` |
| qdrant | qdrant/qdrant:v1.12.4 | сеть `ecosystem`; 127.0.0.1:6333 для диагностики |
| browserless | browserless/chrome | только сеть `ecosystem` |
| certbot | certbot/certbot | одноразовые запуски из Makefile (profile `certs`) |

## Контракты для приложений

**Имена php-fpm контейнеров на сети `ecosystem`** (их ждёт nginx):

- `ai-box-php:9000`
- `ai-box-dr-php:9000`
- `ai-box-mcp-php:9000`

**ai-box-pdn-cleaner** (Python/FastAPI, репозиторий ai-box-bert-ner-train) —
не php и не ходит через nginx: контейнер `ai-box-pdn-cleaner:8000` на сети
`ecosystem`, потребители обращаются по `http://ai-box-pdn-cleaner:8000` с
Bearer-токеном. Требует GPU: на хосте нужен NVIDIA Container Toolkit.
Вместо собственного `pii-redis` использует общий Redis (DB 6).

**ollama-router** (Go-прокси + пул Ollama-инстансов, один на GPU) — тоже
переезжает на этот сервер. Целевой вариант — докеризация: контейнер
`ollama-router:11434` на сети `ecosystem` + ollama-контейнеры с привязкой
к GPU по UUID (см. открытый вопрос в дизайн-спеке). Потребители в любом
случае ходят через env `OLLAMA_URL` и от варианта размещения не зависят;
при systemd-варианте адрес хоста из контейнеров — gateway сети `ecosystem`
(фиксированный `172.30.0.1`).

**Пути кода**: и в php-контейнере приложения, и в nginx код смонтирован по
одному пути `/var/www/<имя-репозитория>` (иначе разъедется `SCRIPT_FILENAME`).
На хосте приложения лежат в `${APPS_ROOT}` (по умолчанию `/var/www`).

**Хосты зависимостей в `.env` приложений**:

```
DB_HOST=mariadb
REDIS_HOST=redis
QDRANT_URL=http://qdrant:6333          # только data-registry
BROWSERLESS_WS=ws://browserless:3000   # ai-box (demo)
DATA_REGISTRY_URL=http://gateway:8083  # потребители DR
MCP_URL=http://gateway:8084            # потребители MCP
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
инициализации volume (`mariadb/initdb/01-apps.sh`), пароли из `.env` стека.

## Развёртывание пустого сервера

```bash
# 0. Docker + git (+ NVIDIA Container Toolkit — нужен pdn-cleaner'у);
#    клонировать репозитории приложений в ${APPS_ROOT}
# 1. Настроить стек
cp .env.example .env && $EDITOR .env
# 2. Собрать базовый PHP-образ (нужен приложениям до их старта)
make build-base
# 3. Получить сертификат (до первого запуска nginx, порт 80 свободен)
make certs-init
# 4. Поднять shared-стек (создаст сеть ecosystem)
make up
# 5. Поднять стеки приложений в их репозиториях
# 6. Продление сертификатов — в cron хоста:
#    0 4 * * 1  cd /opt/ai-box-infra && make certs-renew
```

Порядок важен: сначала shared-стек (сеть, БД), затем приложения. nginx
переживает отсутствие/рестарт приложений — upstream'ы резолвятся на лету.
