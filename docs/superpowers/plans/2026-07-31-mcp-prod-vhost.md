# Прод-vhost mcp.doitai.ru (внешний контур раннеров) — implementation-план

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** прод-аналог тест-контура `mcp.test.doitai.ru` — публичный vhost
`mcp.doitai.ru`, который светит наружу ровно `/api/external/*` приложения
ai-box-mcp; переменная `MCP_DOMAIN` со всеми обвязками (nginx-environment,
env-слои, SAN сертификата) и отражение в вике.

**Architecture:** копия проверенного `nginx/templates-test/mcp.conf.template`
с тремя отличиями: `${MCP_DOMAIN}` вместо `${TEST_MCP_DOMAIN}`, прод-пути
(`/var/www/ai-box-mcp/public`, upstream `ai-box-mcp-php:9000`) и инертный
дефолт `mcp.invalid` (приём `LANDING_DOMAIN`): vhost рендерится на каждом
стенде, но матчится только там, где стенд задал `MCP_DOMAIN`. В SAN
сертификата домен попадает условным `$(if …)` в Makefile — как `TEST_*`.

**Tech Stack:** nginx envsubst-шаблоны официального образа, docker compose,
Makefile (certbot webroot), вика `.claude/wiki/`.

**Контекст (прочитать перед стартом):**
- Спека-источник: `/var/www/html/ai-box/docs/superpowers/specs/2026-07-31-runner-token-cabinet-design.md`,
  секция «Вне scope» — наша часть описана там.
- Тест-аналог: `nginx/templates-test/mcp.conf.template` (в этом репо).
- Bead задачи: `ai-box-infra-lhn` (уже создан и заклеймлен, закрывает главная
  сессия — исполнителю с ним делать ничего не нужно).

## Global Constraints

- Язык комментариев, вики и коммитов — русский; Conventional Commits
  `<type>(<scope>): <описание>`, БЕЗ Co-Authored-By.
- НЕ пушить. Коммит один, в конце (Task 7). Push делает главная сессия после
  верификации.
- Никаких операций на удалённых серверах (doitai) — деплойная фаза вне этого
  плана, её выполняет главная сессия.
- Не использовать TodoWrite/TaskCreate; трекинг — чекбоксы этого плана.
- Валидация — на локальном стенде `STAND=local` (маркер `.stand` = local,
  локальный `infra_nginx` работает).

---

### Task 1: Шаблон `nginx/templates/mcp.conf.template`

**Files:**
- Create: `nginx/templates/mcp.conf.template`

**Interfaces:**
- Produces: vhost `${MCP_DOMAIN}`; Task 2 обязан дать переменной инертный
  дефолт `mcp.invalid`, иначе envsubst оставит `${MCP_DOMAIN}` литералом и
  `nginx -t` упадёт на всех стендах без переменной.

- [x] **Step 1: Создать файл ровно с этим содержимым**

```nginx
# ${MCP_DOMAIN} — ВНЕШНИЙ контур раннеров полигона ai-box-mcp (прод).
# Наружу светят ровно ручки /api/external/runner/*. Всё остальное — 404.
#
# ВАЖНО: ai-box-mcp — внутренний control plane, его /api/v1 не имеет
# авторизации вовсе (доверенная сеть, concepts/trusted-network). Поэтому здесь
# НЕТ `location ~ \.php$`: regex-локация перебивает `location /`, и любой
# /что-угодно.php уходил бы в php-fpm мимо 404. Единственный вход в php —
# прямой fastcgi_pass внутри ^~ /api/external/.
#
# Стенд без прод-контура MCP переменную MCP_DOMAIN не задаёт: vhost рендерится
# с инертным дефолтом mcp.invalid и не матчится ничем (приём LANDING_DOMAIN).

server {
    listen 80;
    server_name ${MCP_DOMAIN};
    include snippets/acme.conf;
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${MCP_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${CERT_NAME}/privkey.pem;
    include snippets/ssl.conf;

    root /var/www/ai-box-mcp/public;
    charset utf-8;

    access_log /var/log/nginx/mcp-external.access.log;
    error_log  /var/log/nginx/mcp-external.error.log;

    # Потолок отчёта раннера — 256K (config aibox-mcp.polygon.report_bytes).
    client_max_body_size 1M;

    # Резолвим upstream в момент запроса, а не старта nginx: иначе nginx
    # не поднимется, пока не запущен контейнер приложения.
    resolver 127.0.0.11 valid=10s;
    set $mcp_public_upstream ai-box-mcp-php:9000;

    location ^~ /api/external/ {
        include snippets/php-fastcgi.conf;
        fastcgi_pass $mcp_public_upstream;
        fastcgi_read_timeout 120;
        # snippets/php-fastcgi.conf ставит SCRIPT_FILENAME=$document_root$fastcgi_script_name,
        # но вне .php-локации $fastcgi_script_name равен $uri — переопределяем
        # явно (строки ниже include перебивают его). Осознанно, не дубль.
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_param SCRIPT_NAME /index.php;
    }

    location / {
        return 404;
    }
}
```

Пояснения (в файл не копировать): имена логов `mcp-external.*` сознательно
совпадают с тест-шаблоном — прод- и тест-vhost'ы прочих доменов
(`api.ai-box.*`, `ai-box.*`) точно так же делят имена логов, это конвенция
репозитория. Имя переменной `$mcp_public_upstream` отличается от
`$mcp_upstream` из `nginx/conf.d/internal-mcp.conf` только ради читаемости
grep'а — скоупы у файлов и так разные.

- [x] **Step 2: Проверить, что тест-аналог не отличается ничем, кроме ожидаемого**

Run: `diff nginx/templates-test/mcp.conf.template nginx/templates/mcp.conf.template`
Expected: отличия только в: строках комментариев (прод-приписка + абзац про
инертный дефолт), `TEST_MCP_DOMAIN`→`MCP_DOMAIN`, `root /var/www/test/…`→
`root /var/www/…`, `$mcp_test_upstream`→`$mcp_public_upstream`,
`ai-box-mcp-test-php`→`ai-box-mcp-php`. Любое другое отличие — ошибка.

### Task 2: `MCP_DOMAIN` в environment nginx (docker-compose.yml)

**Files:**
- Modify: `docker-compose.yml:30-31` (environment сервиса `nginx`)

**Interfaces:**
- Consumes: шаблон Task 1 (`${MCP_DOMAIN}`).
- Produces: переменная `MCP_DOMAIN` с дефолтом `mcp.invalid` для envsubst.

- [x] **Step 1: Вставить переменную после `ADMIN_DOMAIN`, перед `CERT_NAME`**

Было:
```yaml
      ADMIN_DOMAIN: ${ADMIN_DOMAIN:?}
      CERT_NAME: ${CERT_NAME:-${ROOT_DOMAIN}}
```

Стало:
```yaml
      ADMIN_DOMAIN: ${ADMIN_DOMAIN:?}
      # Внешний контур раннеров полигона MCP (mcp.<домен>) — есть не на каждом
      # стенде: не задан → инертный дефолт, vhost рендерится, но не матчится
      # ничем (тот же приём, что LANDING_DOMAIN ниже).
      MCP_DOMAIN: ${MCP_DOMAIN:-mcp.invalid}
      CERT_NAME: ${CERT_NAME:-${ROOT_DOMAIN}}
```

- [x] **Step 2: Валидация интерполяции**

Run: `STAND=local make config`
Expected: exit 0, вывод `[stand] local (env/local/)`.

### Task 3: Домен в SAN сертификата (Makefile)

**Files:**
- Modify: `Makefile:41-52` (комментарий и переменная `DOMAINS`)

**Interfaces:**
- Consumes: `MCP_DOMAIN` из `env/<stend>/config.env` (Makefile его видит через
  `-include $(ENVDIR)/config.env`).
- Produces: условный `-d $(MCP_DOMAIN)` для certs-init/certs-expand.

- [x] **Step 1: Добавить условный `-d` первым среди `$(if …)`-строк**

Было:
```make
DOMAINS = -d $(ROOT_DOMAIN) -d $(FRONT_DOMAIN) -d $(API_DOMAIN) -d $(ADMIN_DOMAIN) \
          $(if $(TEST_FRONT_DOMAIN),-d $(TEST_FRONT_DOMAIN),) \
```

Стало:
```make
DOMAINS = -d $(ROOT_DOMAIN) -d $(FRONT_DOMAIN) -d $(API_DOMAIN) -d $(ADMIN_DOMAIN) \
          $(if $(MCP_DOMAIN),-d $(MCP_DOMAIN),) \
          $(if $(TEST_FRONT_DOMAIN),-d $(TEST_FRONT_DOMAIN),) \
```

- [x] **Step 2: Дополнить комментарий над DOMAINS**

В блок комментария над `DOMAINS` (строки ~40-46, начинается с «Тест-домены — опциональные…»)
добавить одну строку перед строкой про `LANDING_DOMAIN`:

```make
# MCP_DOMAIN — тоже опциональный: прод-контур раннеров есть не на каждом стенде.
```

- [x] **Step 3: Проверить рендер DOMAINS**

Run: `STAND=doitai make -n certs-expand 2>/dev/null | grep -o '\-d [a-z.]*' | tr '\n' ' '`
Expected: в списке есть `-d mcp.doitai.ru` (после Task 4; если Task 4 ещё не
сделан — выполнить этот шаг после него). Для `STAND=local` домена `mcp.*` в
выводе быть не должно.
ВНИМАНИЕ: `make -n`, не боевой вызов. Если `make -n` упадёт на отсутствующем
`env/doitai/secrets.env` (compose --env-file), достаточно проверить строку:
`grep -A5 '^DOMAINS' Makefile`.

### Task 4: env-слои стендов

**Files:**
- Modify: `env/doitai/config.env` (после строки `CERT_NAME=doitai.ru`)
- Modify: `env/example/config.env` (после блока доменов, перед комментарием
  про тест-зону)

**Interfaces:**
- Produces: `MCP_DOMAIN=mcp.doitai.ru` для doitai; документация ключа в example.

- [x] **Step 1: env/doitai/config.env — добавить после `CERT_NAME=doitai.ru`**

```bash

# Внешний контур раннеров полигона MCP — прод-аналог mcp.test.doitai.ru
# (тот в testzone-слое). Домен попадает в SAN условным -d в Makefile;
# при первом добавлении на живом стенде нужен make certs-expand.
MCP_DOMAIN=mcp.doitai.ru
```

- [x] **Step 2: env/example/config.env — документировать ключ (закомментированным)**

Вставить после строки `#CERT_NAME=ai-box.example.ru` и перед комментарием
«Домены тест-зоны (TEST_*)…»:

```bash

# Внешний контур раннеров полигона MCP: единственный публичный vhost
# ai-box-mcp, наружу — только /api/external/runner/*. Задавать ТОЛЬКО на
# стенде, где прод-MCP принимает раннеров клиентов; не задан → vhost инертен
# (дефолт mcp.invalid) и в SAN сертификата домен не попадает.
#MCP_DOMAIN=mcp.ai-box.example.ru
```

- [x] **Step 3: Повторить проверку Task 3 Step 3** (теперь mcp.doitai.ru обязан
  появиться для STAND=doitai)

### Task 5: Локальная валидация рендера (пересоздание local nginx)

**Files:** нет правок — только проверка.

- [x] **Step 1: Пересоздать локальный nginx с новой переменной**

Run: `STAND=local make up`
Expected: exit 0; `infra_nginx` пересоздан (env изменился), entrypoint
отрендерил шаблоны, включая новый `conf.d/mcp.conf`. Остальные контейнеры
стека не трогаются (или молча остаются Up).

- [x] **Step 2: Проверить рендер и конфиг**

Run: `docker exec infra_nginx sh -c 'grep server_name /etc/nginx/conf.d/mcp.conf'`
Expected: две строки `server_name mcp.invalid;`

Run: `STAND=local make nginx-test`
Expected: `nginx: configuration file /etc/nginx/nginx.conf test is successful`

Run: `docker exec infra_nginx sh -c 'curl -s -o /dev/null -w "%{http_code}" -H "Host: mcp.invalid" http://127.0.0.1/api/external/runner/poll'`
Expected: `301` (http-сервер vhost'а жив и редиректит на https). Этого
достаточно: 443-путь локально упирается в self-signed и приложение
ai-box-mcp, которое может быть не поднято — не проверяем.

### Task 6: Вика

**Files:**
- Modify: `.claude/wiki/entities/nginx-edge.md`
- Modify: `.claude/wiki/concepts/deployment-topologies.md`
- Modify: `.claude/wiki/log.md` (append)

- [x] **Step 1: nginx-edge.md — расширить секцию контура раннеров**

Заголовок секции `## Внешний контур раннеров полигона (тест-зона) —
mcp.test.doitai.ru` заменить на:

```markdown
## Внешний контур раннеров полигона — `mcp.doitai.ru` / `mcp.test.doitai.ru`
```

В начало секции (перед абзацем «`nginx/templates-test/mcp.conf.template` — …»)
добавить:

```markdown
Два одинаковых по раскладке шаблона: прод `nginx/templates/mcp.conf.template`
(`${MCP_DOMAIN}`, upstream `ai-box-mcp-php:9000`, код `/var/www/ai-box-mcp`) и
тест `nginx/templates-test/mcp.conf.template` (`${TEST_MCP_DOMAIN}`, upstream
`ai-box-mcp-test-php:9000`, `/var/www/test/ai-box-mcp`). Смысл контура: кабинет
отдаёт клиенту `control_plane_url` (`AIBOX_MCP_PUBLIC_URL` в `.env` стенда
ai-box: прод `https://mcp.doitai.ru`, тест `https://mcp.test.doitai.ru`), и
раннер в контуре клиента ходит на `/api/external/runner/*` по внешнему домену
(спека ai-box `2026-07-31-runner-token-cabinet-design.md`).

Отличие переменных: `TEST_MCP_DOMAIN` обязательна (`:?` в
`docker-compose.testzone.yml` — тест-зона без неё не имеет смысла), а
`MCP_DOMAIN` опциональна с инертным дефолтом `mcp.invalid` (приём
`LANDING_DOMAIN`: прод-контур MCP есть не на каждом стенде, обязательность
уронила бы amulex/local). В SAN сертификата прод-домен попадает условным
`$(if $(MCP_DOMAIN),…)` в `DOMAINS` Makefile; при первом добавлении на живом
стенде — `make certs-expand`. Прод-шаблон живёт сразу в `templates/`, шаг
`testzone-sync` ему не нужен.
```

Дальнейший текст секции оставить как есть (буллеты про `^~ /api/external/`,
отсутствие `.php$`-локации, testzone-sync и риск `mcp.*` — они общие для
обоих шаблонов; в буллете про `TEST_MCP_DOMAIN` ничего не менять — про
опциональность MCP_DOMAIN уже сказано выше).

В `## Связанные Beads` добавить строку:

```markdown
- [[bead:ai-box-infra-lhn]] — прод-vhost `mcp.doitai.ru`, `MCP_DOMAIN`.
```

Frontmatter: `updated: 2026-07-31`.

- [x] **Step 2: deployment-topologies.md — упомянуть прод-контур у doitai**

В буллете стенда **doitai.ru** (строка ~56, «вторая копия, сплит…») после
предложения про домены/бренд добавить одно предложение:

```markdown
С 2026-07-31 у прод-копии есть и внешний контур раннеров полигона —
`mcp.doitai.ru` (`MCP_DOMAIN` в `env/doitai/config.env`, детали и
инертный дефолт — [[entity:nginx-edge]]).
```

Точное место вставки выбрать по смыслу абзаца (не разрывая скобок), frontmatter
`updated: 2026-07-31`.

- [x] **Step 3: log.md — запись**

Прочитать последние ~20 строк `.claude/wiki/log.md`, повторить формат записей:

```markdown
## [2026-07-31] ingest | Прод-vhost mcp.doitai.ru — внешний контур раннеров

Прод-аналог mcp.test.doitai.ru: `nginx/templates/mcp.conf.template`
(наружу только `/api/external/`), `MCP_DOMAIN` с инертным дефолтом
`mcp.invalid` в compose, условный `-d` в DOMAINS, `MCP_DOMAIN=mcp.doitai.ru`
в `env/doitai/config.env`. Обновлены [[entity:nginx-edge]],
[[concept:deployment-topologies]]. Bead [[bead:ai-box-infra-lhn]].
```

- [x] **Step 4: Проверить ссылки**

Run: `grep -rn "bead:ai-box-infra-lhn" .claude/wiki/ | wc -l`
Expected: ≥2 (nginx-edge + log).

### Task 7: Коммит

- [x] **Step 1: Проверить полноту диффа**

Run: `git status --short`
Expected: ровно эти файлы: `nginx/templates/mcp.conf.template` (new),
`docker-compose.yml`, `Makefile`, `env/doitai/config.env`,
`env/example/config.env`, `.claude/wiki/entities/nginx-edge.md`,
`.claude/wiki/concepts/deployment-topologies.md`, `.claude/wiki/log.md`,
`docs/superpowers/plans/2026-07-31-mcp-prod-vhost.md` (этот план тоже
закоммитить).

- [x] **Step 2: Коммит (БЕЗ push)**

```bash
git add nginx/templates/mcp.conf.template docker-compose.yml Makefile \
  env/doitai/config.env env/example/config.env .claude/wiki \
  docs/superpowers/plans/2026-07-31-mcp-prod-vhost.md
git commit -m "feat(nginx): прод-vhost mcp.doitai.ru — внешний контур раннеров полигона"
```

Expected: коммит создан, предупреждения wiki-хука нет (вика в коммите).

---

## Деплойная фаза (вне executor — выполняет главная сессия)

Зафиксировано для полноты плана; исполнителю НЕ делать.

1. Верификация диффа главной сессией → `git push origin master` → GH-workflow
   `deploy-doitai-infra` сам делает на сервере `git pull` + `STAND=doitai make
   eco-deploy` (пересоздание nginx с `MCP_DOMAIN`, рендер vhost'а, reload).
2. Проверка на сервере: `docker exec infra_nginx grep server_name
   /etc/nginx/conf.d/mcp.conf` → `mcp.doitai.ru`.
3. `ssh guha@doitai.ru 'cd /var/www/ai-box-infra && export STAND=doitai && make certs-expand'`
   — SAN += mcp.doitai.ru (DNS уже указывает на сервер, проверено 2026-07-31).
4. `AIBOX_MCP_PUBLIC_URL` в `.env` стендов (после строки `AIBOX_MCP_TIMEOUT=90`):
   `/var/www/ai-box/.env` → `https://mcp.doitai.ru`;
   `/var/www/test/ai-box/.env` → `https://mcp.test.doitai.ru`.
   Если в контейнерах (`ai-box-php`, `ai-box-test-php`) есть
   `bootstrap/cache/config.php` — пересобрать кэш `php artisan config:cache`.
5. Smoke: `curl -sI https://mcp.doitai.ru/` → 404 с валидным сертификатом;
   `curl -s https://mcp.doitai.ru/api/external/runner/poll` — ответ приложения
   (сверить поведение с `https://mcp.test.doitai.ru/api/external/runner/poll`).
6. `bd close ai-box-infra-lhn`.
