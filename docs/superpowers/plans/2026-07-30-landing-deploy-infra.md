# Раздача лендинга doitai (инфра-часть) — Implementation Plan

> **For agentic workers:** этот план исполняется одним dispatch'ем агента
> **plan-executor** (правило проекта: спеку/план пишет главная сессия, исполняет
> младшая модель). Шаги — чекбоксы `- [ ]`. Боевые шаги на doitai (Task 5) агент
> **НЕ выполняет** — их делает главная сессия.

**Goal:** корень `doitai.ru` начинает отдавать статический лендинг из репозитория
`ai-box-site`, `test.doitai.ru` — его develop-копию с `noindex`, при этом стенды
без лендинга (`amulex`, `local`) сохраняют текущий 301 корня на `app.`.

**Architecture:** шаблон `root.conf.template` разделяется на два —
`root-landing.conf.template` (раздача статики, `server_name ${LANDING_DOMAIN}`) и
`root-redirect.conf.template` (текущий 301, `server_name ${ROOT_REDIRECT_DOMAIN}`).
Оба рендерятся на всех стендах; поведение выбирается тем, какая переменная задана
в `env/<stend>/config.env`. Дефолты обеих — несуществующие домены
(`landing.invalid` / `root-redirect.invalid`), заданные в `docker-compose.yml`,
поэтому невыбранный vhost рендерится, но не матчится ни одним запросом.

**Tech Stack:** nginx 1.27-alpine (envsubst из штатного entrypoint), docker
compose (слои env-per-stend), Makefile, GitHub Actions (rsync без сборки).

## Global Constraints

- **envsubst образа nginx НЕ понимает `${VAR:-default}`** — в шаблонах только
  голый `${VAR}`, дефолты живут в `docker-compose.yml` (приём уже применён для
  `ASR_WS_UPSTREAM`).
- Язык комментариев и коммитов — русский, Conventional Commits, **без**
  `Co-Authored-By`.
- Вика (`.claude/wiki/`) обновляется в том же объёме работы (`.claude/rules/wiki.md`).
  Коммиты с кодом без правок вики получают предупреждение хука — либо вика, либо
  трейлер `Wiki: skip` для тривиальных правок.
- Стенды и их файлы: `env/local/config.env` (APPS_ROOT=/var/www/html),
  `env/doitai/{config,testzone}.env`, `env/amulex/config.env`. Секреты
  (`env/*/secrets.env`) в git не лежат; для локальной валидации стендов
  `doitai`/`amulex` создаётся временный файл с фиктивными значениями и удаляется
  в том же шаге.
- Ничего не пушить: план заканчивается локальными коммитами. Пуш в master =
  автодеплой doitai, его делает главная сессия после верификации.
- Существующие vhost'ы (`app.`/`api.`/`admin.` и их тест-копии) не трогаем —
  любой их диff в этом плане является ошибкой.

## Карта файлов

| Файл | Ответственность |
|---|---|
| `nginx/templates/root-landing.conf.template` | **создать** — vhost лендинга, `server_name ${LANDING_DOMAIN}` |
| `nginx/templates/root-redirect.conf.template` | **создать** — прежнее поведение корня, `server_name ${ROOT_REDIRECT_DOMAIN}` |
| `nginx/templates/root.conf.template` | **удалить** — заменён двумя выше |
| `nginx/templates-test/root.conf.template` | **создать** — лендинг тест-зоны, `${TEST_ROOT_DOMAIN}` + `X-Robots-Tag` |
| `docker-compose.yml` | дефолты `LANDING_DOMAIN`/`ROOT_REDIRECT_DOMAIN` + маунт `ai-box-site` |
| `docker-compose.testzone.yml` | обязательный `TEST_ROOT_DOMAIN` + маунт `test/ai-box-site` |
| `Makefile` (цель `testzone-sync`) | доставка тест-шаблона в `nginx/templates/test-root.conf.template` |
| `.gitignore` | рендеры `conf.d`: вместо `root.conf` — два новых + `test-*.conf` |
| `env/doitai/config.env`, `env/doitai/testzone.env`, `env/amulex/config.env`, `env/local/config.env` | значения развилки по стендам |
| `.claude/wiki/entities/nginx-edge.md`, `.claude/wiki/log.md`, `README.md` | документация развилки |

## Инструмент проверки (использовать в каждой задаче)

Изолированный рендер + `nginx -t` в одноразовом контейнере: шаблоны монтируются
ro, сертификаты берутся из тома локального стека, ничего работающего не трогается.
**Рецепт проверен на текущих шаблонах — работает как есть.**

```bash
# ВАРИАНТ А: только прод-шаблоны стенда local (лендинг НЕ выбран)
docker run --rm \
  -e ROOT_DOMAIN=ai-box.local -e FRONT_DOMAIN=app.ai-box.local \
  -e API_DOMAIN=api.ai-box.local -e ADMIN_DOMAIN=admin.ai-box.local \
  -e CERT_NAME=ai-box.local -e ASR_WS_UPSTREAM=127.0.0.1:9 \
  -e LANDING_DOMAIN=landing.invalid -e ROOT_REDIRECT_DOMAIN=ai-box.local \
  -v "$PWD/nginx/templates":/etc/nginx/templates:ro \
  -v "$PWD/nginx/snippets":/etc/nginx/snippets:ro \
  -v ai_box_infra_letsencrypt:/etc/letsencrypt:ro \
  nginx:1.27-alpine nginx -t
```

Ожидание: `syntax is ok` + `test is successful`.

```bash
# ВАРИАНТ Б: как на doitai — прод + тест-зона (тест-шаблоны копируются как
# test-*.conf.template, ровно как это делает make testzone-sync)
T=$(mktemp -d); cp nginx/templates/*.template "$T/"
for f in front api admin internal-test mcp root; do
  [ -f "nginx/templates-test/$f.conf.template" ] && \
    cp "nginx/templates-test/$f.conf.template" "$T/test-$f.conf.template"
done
docker run --rm \
  -e ROOT_DOMAIN=doitai.ru -e FRONT_DOMAIN=app.doitai.ru \
  -e API_DOMAIN=api.doitai.ru -e ADMIN_DOMAIN=admin.doitai.ru \
  -e CERT_NAME=ai-box.local -e ASR_WS_UPSTREAM=127.0.0.1:9 \
  -e LANDING_DOMAIN=doitai.ru -e ROOT_REDIRECT_DOMAIN=root-redirect.invalid \
  -e TEST_FRONT_DOMAIN=app.test.doitai.ru -e TEST_API_DOMAIN=api.test.doitai.ru \
  -e TEST_ADMIN_DOMAIN=admin.test.doitai.ru -e TEST_MCP_DOMAIN=mcp.test.doitai.ru \
  -e TEST_ROOT_DOMAIN=test.doitai.ru \
  -v "$T":/etc/nginx/templates:ro \
  -v "$PWD/nginx/snippets":/etc/nginx/snippets:ro \
  -v ai_box_infra_letsencrypt:/etc/letsencrypt:ro \
  nginx:1.27-alpine nginx -t
rm -rf "$T"
```

`CERT_NAME=ai-box.local` в варианте Б — намеренно: в локальном томе есть только
этот lineage, а `nginx -t` обязан открыть файл сертификата. Проверяется синтаксис
шаблонов, а не боевые пути сертификата.

---

## Task 1: Развилка корневого vhost'а (два шаблона + дефолты + gitignore)

**Files:**
- Create: `nginx/templates/root-landing.conf.template`
- Create: `nginx/templates/root-redirect.conf.template`
- Delete: `nginx/templates/root.conf.template`
- Modify: `docker-compose.yml` (блок `nginx`: `environment`, `volumes`)
- Modify: `.gitignore` (секция рендеров `nginx/conf.d/`)

**Interfaces:**
- Produces: переменные `LANDING_DOMAIN` и `ROOT_REDIRECT_DOMAIN` (дефолты
  `landing.invalid` / `root-redirect.invalid`), путь внутри nginx
  `/var/www/ai-box-site`. Ими пользуются Task 2 (тест-копия по тому же образцу) и
  Task 3 (значения стендов).

- [ ] **Step 1: Создать `nginx/templates/root-landing.conf.template`**

```nginx
# ${LANDING_DOMAIN} — раздача лендинга (репозиторий ai-box-site: статика из
# Webflow, кладётся rsync'ом из CI в ${APPS_ROOT}/ai-box-site).
#
# Развилка корневого домена: этот шаблон рендерится на ВСЕХ стендах, но
# server_name берётся из LANDING_DOMAIN, чей дефолт (landing.invalid, задан в
# docker-compose.yml) не совпадает ни с одним реальным запросом. Стенд с
# лендингом задаёт настоящий домен в env/<stend>/config.env; стенд без лендинга
# оставляет дефолт и пользуется парным root-redirect.conf.template.
# ВАЖНО: envsubst образа nginx не понимает ${VAR:-default} — дефолт только в compose.

server {
    listen 80;
    server_name ${LANDING_DOMAIN};
    include snippets/acme.conf;
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${LANDING_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CERT_NAME}/privkey.pem;
    include snippets/ssl.conf;

    access_log /var/log/nginx/landing.access.log;
    error_log  /var/log/nginx/landing.error.log;

    root /var/www/ai-box-site;
    index index.html;

    # Webflow-экспорт: страницы лежат файлами <slug>.html, а ссылки внутри —
    # без расширения (/pricing-models). Отдаём оба варианта URL.
    location / {
        try_files $uri $uri.html $uri/ =404;
    }

    # Имена ассетов Webflow содержат хеш контента, поэтому immutable безопасен.
    # HTML под это правило не попадает и длинного кеша не получает — страницы
    # обновляются сразу после деплоя.
    location ~* \.(css|js|ico|png|jpg|jpeg|gif|svg|woff|woff2|ttf|eot|pdf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    # Второй рубеж: служебное репозитория на сервер не едет (исключения rsync
    # в workflow ai-box-site), но если появится — наружу не отдаём.
    location ~ /\.(ht|env|git|github|claude|idea) { deny all; }
    location ~* \.md$                             { deny all; }
    location ^~ /docs/                            { deny all; }
}
```

- [ ] **Step 2: Создать `nginx/templates/root-redirect.conf.template`**

Это прежний `root.conf.template` целиком, с одной заменой: `${ROOT_DOMAIN}` →
`${ROOT_REDIRECT_DOMAIN}` в обоих `server_name`.

```nginx
# ${ROOT_REDIRECT_DOMAIN} — корневой домен стенда БЕЗ лендинга: 301 на
# ${FRONT_DOMAIN}. Прежний root.conf.template, переехавший на свою переменную.
#
# Парный шаблон — root-landing.conf.template. Стенд выбирает поведение тем,
# какую из двух переменных он задаёт в env/<stend>/config.env; дефолт этой —
# root-redirect.invalid (docker-compose.yml), т.е. на стенде с лендингом
# vhost рендерится, но не матчится.

server {
    listen 80;
    server_name ${ROOT_REDIRECT_DOMAIN};
    include snippets/acme.conf;
    location / {
        return 301 https://${FRONT_DOMAIN}$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${ROOT_REDIRECT_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CERT_NAME}/privkey.pem;
    include snippets/ssl.conf;

    access_log /var/log/nginx/root.access.log;
    error_log  /var/log/nginx/root.error.log;

    return 301 https://${FRONT_DOMAIN}$request_uri;
}
```

- [ ] **Step 3: Удалить старый шаблон**

```bash
git rm nginx/templates/root.conf.template
```

- [ ] **Step 4: Дефолты переменных в `docker-compose.yml`**

В блоке `services.nginx.environment`, сразу после строки `ASR_WS_UPSTREAM: …`,
добавить:

```yaml
      # Развилка корневого домена: лендинг (root-landing.conf.template) против
      # 301 на app (root-redirect.conf.template). Дефолты — заведомо
      # несуществующие домены: невыбранный vhost рендерится, но не матчится
      # ничем. Дефолты обязаны быть здесь — envsubst в шаблоне синтаксис
      # ${VAR:-default} не понимает (тот же приём, что у ASR_WS_UPSTREAM).
      LANDING_DOMAIN: ${LANDING_DOMAIN:-landing.invalid}
      ROOT_REDIRECT_DOMAIN: ${ROOT_REDIRECT_DOMAIN:-root-redirect.invalid}
```

- [ ] **Step 5: Маунт лендинга в `docker-compose.yml`**

В блоке `services.nginx.volumes`, после строки с `ai-box-front`, добавить:

```yaml
      # Лендинг (репозиторий ai-box-site, rsync из CI, сборки нет). На стендах
      # без лендинга docker создаст пустой каталог — безвредно, vhost там всё
      # равно не матчится.
      - ${APPS_ROOT:-/var/www}/ai-box-site:/var/www/ai-box-site:ro
```

- [ ] **Step 6: `.gitignore` — рендеры conf.d**

Заменить строку `nginx/conf.d/root.conf` (строка 16) на две новых и добавить
рендеры тест-зоны, которых там не было:

```gitignore
# Рендер nginx-шаблонов (envsubst из nginx/templates/ при старте контейнера)
nginx/conf.d/root-landing.conf
nginx/conf.d/root-redirect.conf
nginx/conf.d/front.conf
nginx/conf.d/api.conf
nginx/conf.d/admin.conf
# Рендеры тест-зоны (на хостах с активным testzone-override)
nginx/conf.d/test-*.conf
```

- [ ] **Step 7: Проверка — синтаксис шаблонов на стенде без лендинга**

Запустить **ВАРИАНТ А** из секции «Инструмент проверки».
Ожидание: `syntax is ok`, `test is successful`.

- [ ] **Step 8: Проверка — на стенде с лендингом матчится ровно один корневой vhost**

```bash
docker run --rm \
  -e ROOT_DOMAIN=doitai.ru -e FRONT_DOMAIN=app.doitai.ru \
  -e API_DOMAIN=api.doitai.ru -e ADMIN_DOMAIN=admin.doitai.ru \
  -e CERT_NAME=ai-box.local -e ASR_WS_UPSTREAM=127.0.0.1:9 \
  -e LANDING_DOMAIN=doitai.ru -e ROOT_REDIRECT_DOMAIN=root-redirect.invalid \
  -v "$PWD/nginx/templates":/etc/nginx/templates:ro \
  -v "$PWD/nginx/snippets":/etc/nginx/snippets:ro \
  -v ai_box_infra_letsencrypt:/etc/letsencrypt:ro \
  nginx:1.27-alpine sh -c 'nginx -t 2>&1 | tail -2; grep -h server_name /etc/nginx/conf.d/root-*.conf'
```

Ожидание: тест успешен; в выводе `server_name doitai.ru;` (дважды — :80 и :443)
и `server_name root-redirect.invalid;` (дважды). Ни одного `${`.

- [ ] **Step 9: Проверка — интерполяция стенда local не сломана**

Run: `make config; echo "exit=$?"`
Expected: `[stand] local (env/local)` и `exit=0`.

- [ ] **Step 10: Проверка — существующие vhost'ы не тронуты**

Run: `git diff --stat HEAD -- nginx/templates/front.conf.template nginx/templates/api.conf.template nginx/templates/admin.conf.template nginx/templates-test/`
Expected: пустой вывод (файлы не менялись).

- [ ] **Step 11: Commit**

```bash
git add nginx/templates/root-landing.conf.template nginx/templates/root-redirect.conf.template \
        docker-compose.yml .gitignore
git commit -m "feat(nginx): развилка корневого домена — лендинг или 301 на app

root.conf.template разделён на root-landing (раздача статики ai-box-site,
server_name \${LANDING_DOMAIN}) и root-redirect (прежний 301 на фронт,
server_name \${ROOT_REDIRECT_DOMAIN}). Оба рендерятся на всех стендах, выбор —
какая переменная задана в env/<stend>/config.env; дефолты в docker-compose.yml
(landing.invalid / root-redirect.invalid) не матчатся ничем, поэтому стенды без
лендинга сохраняют текущее поведение корня. envsubst не понимает \${VAR:-default},
отсюда дефолты в compose. Добавлен ro-маунт \${APPS_ROOT}/ai-box-site.

Wiki: skip"
```

Вика для этой задачи обновляется единой правкой в Task 4 — здесь трейлер
`Wiki: skip` осознан.

---

## Task 2: Лендинг тест-зоны (шаблон, переменная, маунт, testzone-sync)

**Files:**
- Create: `nginx/templates-test/root.conf.template`
- Modify: `docker-compose.testzone.yml` (`environment`, `volumes`)
- Modify: `Makefile` (цель `testzone-sync`)

**Interfaces:**
- Consumes: структуру vhost'а лендинга из Task 1.
- Produces: обязательную переменную `TEST_ROOT_DOMAIN` (её значение задаётся в
  Task 3) и путь `/var/www/test/ai-box-site`.

- [ ] **Step 1: Создать `nginx/templates-test/root.conf.template`**

Отличия от прод-версии: `server_name ${TEST_ROOT_DOMAIN}`, другой `root`, и
`X-Robots-Tag` в **обоих** location'ах.

```nginx
# ${TEST_ROOT_DOMAIN} — тест-копия лендинга (ветка develop репозитория
# ai-box-site, rsync из CI в ${APPS_ROOT}/test/ai-box-site).
#
# Прод-аналог — nginx/templates/root-landing.conf.template. Здесь переменная
# ОБЯЗАТЕЛЬНАЯ (docker-compose.testzone.yml, :?): тест-зона включается
# симлинком override целиком, гейтить внутри неё нечего.

server {
    listen 80;
    server_name ${TEST_ROOT_DOMAIN};
    include snippets/acme.conf;
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${TEST_ROOT_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CERT_NAME}/privkey.pem;
    include snippets/ssl.conf;

    access_log /var/log/nginx/landing-test.access.log;
    error_log  /var/log/nginx/landing-test.error.log;

    root /var/www/test/ai-box-site;
    index index.html;

    # Тест-копия публична — не должна индексироваться как дубль боевой.
    # add_header НЕ наследуется в location, где есть свой add_header, поэтому
    # заголовок продублирован в блоке ассетов (иначе они остались бы без него).
    add_header X-Robots-Tag "noindex, nofollow" always;

    location / {
        add_header X-Robots-Tag "noindex, nofollow" always;
        try_files $uri $uri.html $uri/ =404;
    }

    location ~* \.(css|js|ico|png|jpg|jpeg|gif|svg|woff|woff2|ttf|eot|pdf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        add_header X-Robots-Tag "noindex, nofollow" always;
        try_files $uri =404;
    }

    location ~ /\.(ht|env|git|github|claude|idea) { deny all; }
    location ~* \.md$                             { deny all; }
    location ^~ /docs/                            { deny all; }
}
```

- [ ] **Step 2: `docker-compose.testzone.yml` — переменная и маунт**

В `services.nginx.environment` после `TEST_MCP_DOMAIN` добавить:

```yaml
      TEST_ROOT_DOMAIN: ${TEST_ROOT_DOMAIN:?TEST_ROOT_DOMAIN обязателен (лендинг тест-зоны)}
```

В `services.nginx.volumes` добавить последней строкой:

```yaml
      - ${APPS_ROOT:-/var/www}/test/ai-box-site:/var/www/test/ai-box-site:ro
```

- [ ] **Step 3: `Makefile` — доставка тест-шаблона**

В цель `testzone-sync`, после строки с `mcp.conf.template`, добавить:

```makefile
		cp nginx/templates-test/root.conf.template nginx/templates/test-root.conf.template; \
```

- [ ] **Step 4: Проверка — синтаксис с тест-зоной**

Запустить **ВАРИАНТ Б** из секции «Инструмент проверки» (он уже включает
`root` в списке копируемых тест-шаблонов и `TEST_ROOT_DOMAIN` в env).
Ожидание: `syntax is ok`, `test is successful`.

- [ ] **Step 5: Проверка — X-Robots-Tag есть в обоих location'ах рендера**

```bash
T=$(mktemp -d); cp nginx/templates/*.template "$T/"
cp nginx/templates-test/root.conf.template "$T/test-root.conf.template"
docker run --rm \
  -e ROOT_DOMAIN=doitai.ru -e FRONT_DOMAIN=app.doitai.ru -e API_DOMAIN=api.doitai.ru \
  -e ADMIN_DOMAIN=admin.doitai.ru -e CERT_NAME=ai-box.local -e ASR_WS_UPSTREAM=127.0.0.1:9 \
  -e LANDING_DOMAIN=doitai.ru -e ROOT_REDIRECT_DOMAIN=root-redirect.invalid \
  -e TEST_ROOT_DOMAIN=test.doitai.ru \
  -v "$T":/etc/nginx/templates:ro -v "$PWD/nginx/snippets":/etc/nginx/snippets:ro \
  -v ai_box_infra_letsencrypt:/etc/letsencrypt:ro \
  nginx:1.27-alpine sh -c 'grep -c X-Robots-Tag /etc/nginx/conf.d/test-root.conf; grep server_name /etc/nginx/conf.d/test-root.conf'
rm -rf "$T"
```
Ожидание: `3` (server-уровень + два location'а) и `server_name test.doitai.ru;` дважды.

- [ ] **Step 6: Проверка — цель testzone-sync знает про новый шаблон**

Run: `grep -c "templates-test/.*\.conf\.template" Makefile`
Expected: `6` (front, api, admin, internal-test, mcp, root).

- [ ] **Step 7: Commit**

```bash
git add nginx/templates-test/root.conf.template docker-compose.testzone.yml Makefile
git commit -m "feat(nginx): лендинг тест-зоны на \${TEST_ROOT_DOMAIN}

Тест-копия лендинга (ветка develop, \${APPS_ROOT}/test/ai-box-site) с
X-Robots-Tag noindex — продублирован в location ассетов, потому что add_header
не наследуется там, где есть собственный add_header. Переменная обязательная
(:?): тест-зона включается симлинком override целиком. Шаблон доставляется
make testzone-sync, ro-маунт добавлен в testzone-оверлей.

Wiki: skip"
```

---

## Task 3: Значения развилки по стендам

**Files:**
- Modify: `env/doitai/config.env`
- Modify: `env/doitai/testzone.env`
- Modify: `env/amulex/config.env`
- Modify: `env/local/config.env`

**Interfaces:**
- Consumes: `LANDING_DOMAIN`/`ROOT_REDIRECT_DOMAIN` (Task 1), `TEST_ROOT_DOMAIN` (Task 2).

- [ ] **Step 1: `env/doitai/config.env`** — добавить в конец файла:

```bash
# Корень отдаёт лендинг (репозиторий ai-box-site). Парная переменная
# ROOT_REDIRECT_DOMAIN намеренно НЕ задана — её vhost остаётся на инертном
# дефолте root-redirect.invalid.
LANDING_DOMAIN=doitai.ru
```

- [ ] **Step 2: `env/doitai/testzone.env`** — добавить в конец файла:

```bash
# Корень тест-зоны отдаёт develop-копию лендинга (с X-Robots-Tag noindex).
# Домен уже есть в DNS (A на тот же IP), но НЕ был в SAN сертификата — SAN
# расширяется боевым шагом (make certs-expand).
TEST_ROOT_DOMAIN=test.doitai.ru
```

- [ ] **Step 3: `env/amulex/config.env`** — добавить в конец файла:

```bash
# Лендинга на этом стенде нет: корень по-прежнему 301 на app.
# (Без этой строки корневой vhost остался бы на дефолте root-redirect.invalid
# и amulex молча потерял бы редирект корня.)
ROOT_REDIRECT_DOMAIN=ai-box.amulex.ru
```

- [ ] **Step 4: `env/local/config.env`** — добавить в конец файла:

```bash
# Лендинга на dev-стенде нет: корень 301 на app.
ROOT_REDIRECT_DOMAIN=ai-box.local
```

- [ ] **Step 5: Проверка — стенд local**

Run: `make config; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 6: Проверка — стенды doitai и amulex (с фиктивными секретами)**

```bash
for k in DB_ROOT_PASSWORD AI_BOX_DB_PASSWORD AI_BOX_DR_DB_PASSWORD \
         AI_BOX_MCP_DB_PASSWORD REDIS_PASSWORD BROWSERLESS_TOKEN NEO4J_PASSWORD; do
  echo "$k=dummy"
done | tee env/doitai/secrets.env > env/amulex/secrets.env
STAND=doitai make config; echo "doitai exit=$?"
STAND=amulex make config; echo "amulex exit=$?"
rm -f env/doitai/secrets.env env/amulex/secrets.env
```
Expected: оба `exit=0`; строка стенда doitai — `[stand] doitai (env/doitai + testzone)`.

- [ ] **Step 7: Проверка — что реально доедет до nginx на каждом стенде**

```bash
for k in DB_ROOT_PASSWORD AI_BOX_DB_PASSWORD AI_BOX_DR_DB_PASSWORD \
         AI_BOX_MCP_DB_PASSWORD REDIS_PASSWORD BROWSERLESS_TOKEN NEO4J_PASSWORD; do
  echo "$k=dummy"
done | tee env/doitai/secrets.env > env/amulex/secrets.env
echo "--- doitai ---"
docker compose --env-file env/doitai/config.env --env-file env/doitai/testzone.env \
  --env-file env/doitai/secrets.env -f docker-compose.yml -f docker-compose.testzone.yml config \
  | grep -E "LANDING_DOMAIN|ROOT_REDIRECT_DOMAIN|TEST_ROOT_DOMAIN|ai-box-site"
echo "--- amulex ---"
docker compose --env-file env/amulex/config.env --env-file env/amulex/secrets.env \
  -f docker-compose.yml config | grep -E "LANDING_DOMAIN|ROOT_REDIRECT_DOMAIN|ai-box-site"
rm -f env/doitai/secrets.env env/amulex/secrets.env
```
Expected:
- doitai — `LANDING_DOMAIN: doitai.ru`, `ROOT_REDIRECT_DOMAIN: root-redirect.invalid`,
  `TEST_ROOT_DOMAIN: test.doitai.ru`, два маунта `ai-box-site` (прод и test);
- amulex — `LANDING_DOMAIN: landing.invalid`, `ROOT_REDIRECT_DOMAIN: ai-box.amulex.ru`,
  один маунт `ai-box-site`.

- [ ] **Step 8: Проверка — секреты не остались в рабочей копии**

Run: `ls env/doitai env/amulex; git status --short`
Expected: никаких `secrets.env`; в `git status` только изменённые файлы стендов.

- [ ] **Step 9: Commit**

```bash
git add env/doitai/config.env env/doitai/testzone.env env/amulex/config.env env/local/config.env
git commit -m "feat(env): развилка корня по стендам — лендинг на doitai, 301 на amulex/local

doitai: LANDING_DOMAIN=doitai.ru + TEST_ROOT_DOMAIN=test.doitai.ru (тест-копия);
amulex и local: ROOT_REDIRECT_DOMAIN — прежнее поведение корня сохранено явным
значением, а не дефолтом.

Wiki: skip"
```

---

## Task 4: Документация — вика и README

**Files:**
- Modify: `.claude/wiki/entities/nginx-edge.md`
- Modify: `.claude/wiki/log.md`
- Modify: `README.md` (секция «Домены»)

**Interfaces:**
- Consumes: всё сделанное в Tasks 1-3.

> Перед правкой прочитать `.claude/wiki/entities/nginx-edge.md` целиком и
> `.claude/wiki/log.md` (формат записей). Не переписывать существующие секции —
> только добавить своё и обновить `updated:` во frontmatter на `2026-07-30`.

- [ ] **Step 1: `nginx-edge.md` — секция про развилку корня**

Добавить секцию (место — после описания прод-vhost'ов, перед `## Связи`),
текст по существу:

```markdown
## Корневой домен: лендинг или редирект

`root.conf.template` разделён на два шаблона, оба рендерятся на всех стендах:

- `templates/root-landing.conf.template` — `server_name ${LANDING_DOMAIN}`,
  раздача статики из `/var/www/ai-box-site` (репозиторий `ai-box-site`, экспорт
  Webflow, деплой rsync'ом без сборки). `try_files $uri $uri.html $uri/` — ссылки
  внутри лендинга без расширения; ассеты с хешем в имени — `expires 30d` +
  `immutable`, HTML под это правило не попадает;
- `templates/root-redirect.conf.template` — `server_name ${ROOT_REDIRECT_DOMAIN}`,
  прежний 301 на `${FRONT_DOMAIN}`;
- `templates-test/root.conf.template` — тест-копия (`${TEST_ROOT_DOMAIN}`,
  `/var/www/test/ai-box-site`) с `X-Robots-Tag: noindex, nofollow`, продублированным
  в location ассетов (`add_header` не наследуется там, где есть свой `add_header`).

Стенд выбирает поведение тем, какую переменную он задаёт в `env/<stend>/config.env`
(doitai — `LANDING_DOMAIN`, amulex/local — `ROOT_REDIRECT_DOMAIN`). Дефолты обеих
переменных — несуществующие домены (`landing.invalid`/`root-redirect.invalid`) и
живут в `docker-compose.yml`, потому что envsubst образа nginx не понимает
`${VAR:-default}`. Невыбранный vhost рендерится, но не матчится ничем — конфликта
`server_name` нет. Deny-правила (`/\.(ht|env|git|…)`, `*.md`, `^~ /docs/`) — второй
рубеж: служебное репозитория и так исключено в rsync.
```

В `## Связи` добавить `- [[decision:env-per-stend]]`, если ссылки ещё нет.

- [ ] **Step 2: `README.md` — секция «Домены»**

В абзац про раскладку доменов добавить, что корень стенда — либо лендинг
(`LANDING_DOMAIN`, статика `ai-box-site`), либо 301 на `app.`
(`ROOT_REDIRECT_DOMAIN`), и что дефолты обеих переменных инертны.

- [ ] **Step 3: Запись в `.claude/wiki/log.md`**

Дописать в конец файла (формат — как у соседних записей):

```markdown
## [2026-07-30] ingest | Развилка корневого домена: лендинг doitai vs 301 на app

`root.conf.template` разделён на `root-landing` (`${LANDING_DOMAIN}`, статика
`/var/www/ai-box-site`) и `root-redirect` (`${ROOT_REDIRECT_DOMAIN}`, прежний 301);
тест-копия — `templates-test/root.conf.template` (`${TEST_ROOT_DOMAIN}`,
`X-Robots-Tag: noindex` в том числе на ассетах). Дефолты переменных
(`landing.invalid`/`root-redirect.invalid`) заданы в `docker-compose.yml` —
envsubst не понимает `${VAR:-default}`; невыбранный vhost не матчится ничем,
поэтому amulex и local сохранили редирект корня. Значения по стендам —
в `env/<stend>/config.env`; маунты `ai-box-site` (прод и test) в compose;
`make testzone-sync` доставляет тест-шаблон. Инфра-часть bead ai-box-infra-5jk;
боевые шаги (каталоги-приёмники, пересоздание nginx, расширение SAN под
test.doitai.ru, включение push-триггеров в ai-box-site) — отдельно.
Подробности — [[entity:nginx-edge]].
```

- [ ] **Step 4: Проверка**

```bash
grep -q "Корневой домен: лендинг или редирект" .claude/wiki/entities/nginx-edge.md && echo "nginx-edge ок"
grep -q "updated: 2026-07-30" .claude/wiki/entities/nginx-edge.md && echo "updated ок"
grep -q "Развилка корневого домена" .claude/wiki/log.md && echo "log ок"
grep -q "LANDING_DOMAIN" README.md && echo "README ок"
```
Expected: четыре строки `… ок`.

- [ ] **Step 5: Commit**

```bash
git add .claude/wiki/entities/nginx-edge.md .claude/wiki/log.md README.md
git commit -m "docs(wiki): развилка корневого домена и раздача лендинга"
```

- [ ] **Step 6: Показать итог главной сессии**

Run: `git log --oneline -4 && git status --short`
Expected: четыре коммита задач 1-4, чистая рабочая копия (кроме файлов beads).

> **СТОП.** Дальше — боевые шаги на doitai (Task 5), их выполняет главная
> сессия. Ничего не пушить.

---

## Task 5: Боевые шаги на doitai — **выполняет главная сессия, не агент**

Порядок обязателен: сертификат расширяется ПОСЛЕ появления vhost'а тест-зоны,
потому что webroot-валидация ходит на `/.well-known/acme-challenge/` внутри этого
же vhost'а; standalone-режим не подходит (занял бы :80 под работающим nginx).

1. Создать каталоги-приёмники, владелец `guha` (в них пишет rsync из CI):
   `mkdir -p /var/www/ai-box-site /var/www/test/ai-box-site`.
2. Смерджить в master и запушить (пуш = автодеплой doitai).
3. **Удалить отрендеренный `nginx/conf.d/root.conf`** на сервере: рендеры не под
   git, `git pull` его не тронет, и он будет спорить за `server_name doitai.ru`
   с новым лендинг-vhost'ом.
4. `docker compose … up -d --force-recreate nginx` (через `make up` c
   `--force-recreate`, либо целью `testzone-enable`, которая это делает) —
   именно пересоздание: добавились маунты и переменные, `nginx -s reload` их
   не подхватывает.
5. `make testzone-sync` — доставить тест-шаблон в `nginx/templates/`.
6. `make certs-expand` — SAN пополняется `test.doitai.ru` (цель уже знает весь
   список из `DOMAINS`; `certbot renew` SAN не расширяет).
7. `make nginx-reload` — подхватить обновлённый сертификат.
8. Выкатить содержимое лендинга: `gh workflow run` в `ai-box-site` для master и
   develop (каталоги уже существуют).
9. Приёмка (критерии bead `ai-box-infra-5jk`): `https://doitai.ru/` → 200 лендинг;
   `https://doitai.ru/pricing-models` → 200 без `.html`; `/README.md`,
   `/.git/config`, `/docs/` → 403; `https://test.doitai.ru/` → 200 с
   `X-Robots-Tag: noindex` и валидным TLS; `app./api./admin.doitai.ru` — без
   изменений; корень `ai-box.amulex.ru` → 301 на app (стенд не задет).
10. Включить `push:`-триггеры в обоих workflow `ai-box-site` — **отдельный
    репозиторий, master: спросить разрешение человека** (правило о master
    app-репозиториев).

---

## Самопроверка плана (выполнена автором)

- **Покрытие задачи:** п.1 дизайна (развилка) → Task 1; п.2 (root-landing) →
  Task 1 Step 1; п.3 (тест-шаблон) → Task 2 Step 1; п.4 (compose/env/Makefile/
  gitignore) → Tasks 1-3; п.5 (боевые шаги) → Task 5; п.6 (откат) — в Task 5
  зафиксирован симметричный путь через переменные; п.7 (возражение про две
  переменные на всех стендах) — принято как есть, альтернатива отвергнута в
  дизайне.
- **Отклонения от дизайна:** (1) `.gitignore` дополнительно получает
  `nginx/conf.d/test-*.conf` — дизайн это предлагал, фиксирую как часть Task 1;
  (2) в Task 5 добавлен шаг «выкатить содержимое лендинга» (`workflow_dispatch`)
  до приёмки — без него `doitai.ru` отдавал бы 404 из пустого каталога;
  (3) `X-Robots-Tag` в тест-шаблоне ставится трижды (server + два location'а):
  дизайн требовал дубля в ассетах, server-уровень оставлен для локаций без
  своего `add_header`.
- **Плейсхолдеров нет:** все шаблоны, yaml-вставки и env-строки приведены
  целиком; проверочные команды прогнаны на текущем дереве до написания плана
  (рецепты А и Б дают `test is successful`).
- **Согласованность имён:** `LANDING_DOMAIN`, `ROOT_REDIRECT_DOMAIN`,
  `TEST_ROOT_DOMAIN`, пути `/var/www/ai-box-site` и `/var/www/test/ai-box-site`,
  файлы `root-landing.conf.template`/`root-redirect.conf.template`/
  `templates-test/root.conf.template` — одинаковы во всех задачах и совпадают с
  дизайном в bead.
