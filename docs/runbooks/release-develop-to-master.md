# Runbook: релиз develop→master и раскатка на прод (doitai.ru → amulex)

> **Статус: ПОДГОТОВКА.** Слить develop→master во всех app-репозиториях,
> проставить новые env, выкатить на прод doitai.ru (вторая копия), затем —
> тем же кодом — на ai-box.amulex.ru (Jenkins + make). Эпик — `bead:ai-box-infra-ahh`.

## Что релизим (матрица репозиториев)

| Репо | develop→master | Мёрдж | Что нового на проде |
|---|---|---|---|
| **ai-box** (back) | 278 коммитов | **FF** | 14 миграций; `queue`→`horizon`; Redis-сессии/очереди; config-ассистент; агенты; титлер |
| **ai-box-mcp** | 30 коммитов | **FF** | **новый сервис `codapi`** + сеть `ai_box_sandbox` + box-образ `python-box`; плагины email/python_exec |
| **ai-box-front** | 131 коммит | **FF** | config-ассистент (нужен `VITE_CONFIG_ASSISTANT_INTEGRATION_ID` на сборке) |
| **ai-box-data-registry** | 1↔1 | **пропустить** | контент master == develop (дубль realpath_cache) — релизить нечего |
| ollama-router | — | — | ветки `develop` нет |
| pdn-cleaner | — | — | trunk `main`, вне схемы |

**Механика прод-деплоя doitai.ru:** push в `master` авто-триггерит
`deploy-doitai.yml` → по SSH `make eco-deploy` (`git pull master` +
`migrate --force` + `up -d --remove-orphans` + `restart php horizon`).
Фронт — сборка в CI с VITE_* и `rsync dist`. **Вывод: сам мёрдж выкатывает
прод — значит env и workflow готовим ДО мёрджа.**

## Ключевые факты про env (из аудита)

- **Жёстко-обязательных новых env-ключей нет** — все имеют дефолты в коде;
  тест-зона это доказывает (работает на дефолтах, ключей в её `.env` нет).
- doitai.ru прод **уже имеет** критичные `SYSTEM_CLIENT_ID` и `FRONTEND_URL`
  → seed-миграции отработают (не тихо-пропустятся).
- **env-читающие миграции** (значения нужны ДО `migrate`): seed config-ассистента
  (`CAPABILITY_INTEGRATION_ID`, деф. `01KWVSZ1FTYX58J212G4S62X77`), titler
  (`LLM_OLLAMA_TITLER_CODE`), common-agent (`LLM_AGENT_MODEL_CODE`/`LLM_AGENT_MODEL`),
  allowed_domains (`FRONTEND_URL`). На doitai дефолты совпадают со стендом — ок.
- **`CAPABILITY_INTEGRATION_ID` бэка обязан совпадать с `VITE_CONFIG_ASSISTANT_INTEGRATION_ID`
  фронта** — иначе фронт стучится в несуществующую интеграцию.

---

## Фаза 0 — подготовка (в develop, прод не трогаем)

Всё это коммитим в `develop` каждого репо ДО мёрджа в master.

1. **ai-box `.env.example`:** дописать 32 недокументированных ключа с дефолтами
   (`HORIZON_*`, `LLM_AGENT_*`, `CAPABILITY_*`, `TELEMETRY_*`,
   `CHAT_TITLE_RECOUNT_AFTER`, `LLM_OLLAMA_TITLER_CODE`). Гигиена: эксплуатация
   должна видеть ключи. Значения — дефолты из `config/*.php`.
2. **ai-box-mcp `.env.example`:** дописать `PYTHON_EXEC_TIMEOUT_MS`,
   `PYTHON_EXEC_MAX_TIMEOUT_MS` (уже есть `CODAPI_BASE_URL`/`CODAPI_SANDBOX`).
3. **ai-box-front `deploy-doitai.yml` (прод-workflow):** добавить строку
   `VITE_CONFIG_ASSISTANT_INTEGRATION_ID: 01KWVSZ1FTYX58J212G4S62X77`
   в build-env. `VITE_PROMPT_GENERATOR_MODEL=01KWNX…` уже верен (совпадает с
   ULID `common-prompt-generator` в прод-БД doitai.ru) — не трогать.
4. **doitai.ru прод-`.env` ai-box (опционально, belt-and-suspenders):** явно
   проставить `CAPABILITY_INTEGRATION_ID=01KWVSZ1FTYX58J212G4S62X77` (дефолт и так
   верный; фиксируем контракт с фронтом). Redis-индексы прод-копии оставить как есть
   (не пересекаются с тест-зоной 2/3, 4/5, 14/15).
5. **Сухая проверка Makefile'ов** (уже сверено): ai-box eco-deploy —
   `up -d --remove-orphans` + `restart php horizon`; MCP eco-deploy — сборка
   box-образа + создание сети `ai_box_sandbox` до `up`. Подтвердить, что прод-клоны
   на doitai.ru возьмут новый Makefile из master.

## Фаза 1 — раскатка doitai.ru (вторая копия)

Порядок мёрджа значим: сперва бэк (создаёт интеграцию миграцией), затем фронт.

1. **Мёрдж → master (FF)** и push:
   - `ai-box`: `git checkout master && git merge --ff-only origin/develop && git push origin master`
   - `ai-box-mcp`: то же
   - `ai-box-front`: то же (workflow уже с VITE-строкой из фазы 0)
   - `ai-box-data-registry`: **пропустить** (контент идентичен) либо выровнять
     указатель отдельно, вне окна.
2. Push в master авто-запускает `deploy-doitai.yml` каждого репо. Следить за CI
   (или `workflow_dispatch` вручную по одному, если нужен контроль порядка).
3. **Проверки на doitai.ru после деплоя:**
   - тест-клон бэка/mcp дошли до master-HEAD; `migrate` отработал без ошибок;
   - `ai-box-queue` исчез, поднялся `ai-box-horizon` (`docker ps`; `--remove-orphans`);
   - MCP: поднялся `ai-box-mcp-codapi`, создана сеть `ai_box_sandbox`, собран
     `python-box`-образ; `docker exec` проверка `curl http://codapi:1313`;
   - интеграция config-ассистента `01KWVSZ…` в `ai_box`, `is_active=1`;
   - фронт-сборка содержит `01KWVSZ…` (grep в dist);
   - smoke: `curl -I https://app.doitai.ru` (TLS), логин, шаг чата (Ollama-титлер
     проставляет заголовок), ИИ-помощник (виджет `i/{id}/create` — CORS ок,
     allowed_domains сеются из FRONTEND_URL), агенты (horizon-очередь `LLM_AGENT_QUEUE`),
     python_exec/email в MCP.
4. **Ручной пост-деплой шаг** (НЕ в автоматике eco-deploy, вне миграций — внешний
   HTTP к MCP): зарегистрировать builtin python_exec конфиг-ассиста —
   `docker exec ai-box-php sh -c 'cd /var/www/ai-box && php artisan mcp:register-config-builtin'`.
   Идемпотентна; предпосылки — SYSTEM_CLIENT_ID, config-модель засеяна, MCP поднят.
   Без неё «Питон интерпретатор» не появится у конфиг-ассиста. (На doitai выполнено 2026-07-08.)
5. **Отстояться** (часы/сутки) — логи horizon, sentry, ошибки 5xx.

## Фаза 2 — раскатка ai-box.amulex.ru (addons — боевая, по разрешению)

> ⚠️ Прод addons.amulex.ru. Только с явного разрешения человека.

### 2.0 — живая read-only проверка ПЕРЕД любыми правками

Runbook `split-cutover-ai-box.md` (2026-07-04) говорит: amulex переведён на эко-стек,
но фаза 3 не завершена и состояние могло измениться. Проверить на сервере:

- база и redis — **докерные эко или ещё хостовые?** (`docker ps`, чем слушают
  прод-клоны, `.env` `DB_HOST`/`REDIS_HOST`);
- **Redis-индексы исторические**: ai-box `0/1`, DR `6/7`, MCP `8/9` (НЕ README-схема!)
  — новые Redis-ключи (`REDIS_SESSION_DB`) проставлять в этой раскладке;
- MCP живёт из отдельного клона `/var/www/ai-box-mcp-eco` + некоммитный
  `docker-compose.prod-local.yml`;
- завершена ли фаза 3 (кто держит 80/443, Jenkins-цели, хостовые сервисы);
- `SYSTEM_CLIENT_ID`/`FRONTEND_URL` в прод-`.env` (для seed-миграций);
- `CORS_ALLOWED_ORIGINS` содержит `https://app.ai-box.amulex.ru`.

### 2.1 — env и сборка

- Дозаполнить прод-`.env` (те же новые ключи, что doitai; **но redis-индексы
  исторические**). `CAPABILITY_INTEGRATION_ID` = `01KWVSZ…` (= VITE фронта).
- **Фронт на amulex собирается Jenkins/make, не GitHub Actions** — добавить
  `VITE_CONFIG_ASSISTANT_INTEGRATION_ID=01KWVSZ…` и корректный (пер-БД!)
  `VITE_PROMPT_GENERATOR_MODEL` в механизм сборки Jenkins. **ULID prompt-generator
  вытащить из прод-БД amulex** (`SELECT id FROM client_models WHERE code='common-prompt-generator'`).
- codapi на MCP: нужен хостовый `docker.sock` и сборка box-образа — проверить,
  что Jenkins-таргет/`make eco-deploy` на amulex это делает (перенести правки
  Makefile, если клон MCP отдельный `-eco`).

### 2.2 — деплой (Jenkins + make)

- master уже смёрджен (Фаза 1) — amulex тянет тот же master.
- Прогнать Jenkins-деплой на новые эко-каталоги (не старые `ai-box-back`/
  `ai-box-data-regestry`), `make eco-deploy` с `--remove-orphans` (queue→horizon)
  и сборкой codapi-box.
- `migrate --force` (env-читающие миграции — env уже проставлен в 2.1).
- **Ручной пост-деплой** (как в Фазе 1.4): `php artisan mcp:register-config-builtin`
  на amulex-контейнере ai-box (иначе «Питон» не появится у конфиг-ассиста).
- Прогрев + smoke под живым трафиком (список Фазы 1.3 + вебхуки ботов,
  виджеты клиентов — см. грабли split-cutover).

## Грабли (сводно)

- **queue→horizon:** деплой без `--remove-orphans` оставит зависший `*-queue`
  контейнер, жрущий очередь параллельно horizon. Makefile уже с флагом — проверить.
- **codapi монтирует хостовый `/var/run/docker.sock`** — security-поверхность;
  сеть `ai_box_sandbox` изолирует эфемерные box-контейнеры. Box-образ собирается
  деплой-таргетом ДО `up` (иначе сервис не стартует).
- **Фронт-ULID:** `VITE_CONFIG_ASSISTANT_INTEGRATION_ID` (фикс, одинаков везде) vs
  `VITE_PROMPT_GENERATOR_MODEL` (**генерится per-БД** — на каждом стенде свой,
  брать из его БД). Бэк `CAPABILITY_INTEGRATION_ID` = VITE config-assistant id.
- **env-читающие seed-миграции** засеют дефолты, если env не задан ДО `migrate`;
  на doitai дефолты верны, на amulex — проверить перед прогоном.
- **amulex Redis-индексы историко-прод** (0/1, 6/7, 8/9), не README — не перепутать
  при заполнении `REDIS_*`.
- **data-registry** релиза не требует (master == develop по контенту).
- **Мёрдж в master = авто-деплой doitai** — не пушить master, пока Фаза 0 не готова.

## Связанные Beads

- `bead:ai-box-infra-ahh` — эпик релиза.
