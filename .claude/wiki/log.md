# Журнал вики

## [2026-07-04] ingest | Первичная компиляция вики

Развёрнута llm-wiki по пакету beads-llm-wiki: overview, entities
(shared-stack, php-base-image, nginx-edge), concepts (contracts,
deployment-topologies), integrations (app-stacks, gpu-services), index.
Источник — кодовая база и документы `docs/` (спека дизайна, runbook
боевого переезда 2026-07-04). decisions/ пуста — наполняется при закрытии
задач beads.
## [2026-07-04] ingest | Развёрнута копия doitai.ru («всё внутри», CPU): инфра-стек без overlay (LE-серт certs-init), три приложения+фронт (бренд doitai), ollama-router+ollama CPU (qwen3:8b, embeddinggemma), pdn-cleaner CPU-образ (ждёт HF_TOKEN для модели), деплой GitHub Actions в пяти репо. Гочи: root-овый dist от bind-mount, --env-file для compose-файлов в подпапке, диск 82% после моделей
## [2026-07-04] ingest | doitai.ru переведён на внешние Ollama/pdn (192.168.101.114, связность проверена): в облаке тикет по GPU; локальный CPU-пул ollama свёрнут (volume моделей удалён, диск 82%→68%), env приложений переключены, воркеры стабильны, api/app 200. CPU-заготовки остаются в репозиториях до появления GPU
## [2026-07-04] ingest | CI-деплой doitai работает: секрет DOITAI_SSH_KEY поставлен в 5 репо через gh (GH_TOKEN), тестовые прогоны infra и front — success, сайт жив; заведён админ admin@doitai.ru; задачи 03g/x1p закрыты, заведена задача возврата локальных GPU-стеков после облачного тикета
## [2026-07-04] ingest | Шедулер ai-box: обнаружено, что schedule:run не запускался даже на старом проде (нет cron) — добавлен сервис ai-box-scheduler (schedule:work) в eco-compose, раскатан на doitai через CI и на addons вручную; цепочка scheduler→queue→worker проверена вживую на обеих копиях (EnrichCompletedSessionsJob 09:15 DONE). Очереди на doitai здоровы (failed=0). Включена генерация промпта на фронте doitai (VITE_PROMPT_GENERATOR_MODEL → ULID сидированного common-prompt-generator)
## [2026-07-04] ingest | Биллинг выключен явным флагом BILLING_ENABLED=false в .env ai-box на обеих копиях (addons и doitai); ранее ключ отсутствовал и работал дефолт false. Конфиг-кэш пересобран, scheduler/queue перезапущены, guard проверен реальным запуском billing:charge-services на обеих копиях («списание пропущено»)
## [2026-07-04] ingest | Тест-зона test.doitai.ru: шаблоны тест-vhost (templates-test, публичные + внутренние 818x), overlay docker-compose.testzone.yml (подключение симлинком docker-compose.override.yml на хосте), параметризация eco-compose приложений под второй инстанс (APP_PREFIX/APP_CODE_PATH/ECO_PROJECT), DEPLOY_BRANCH в деплой-таргетах, CI deploy-doitai-test.yml на push в develop (4 репо). Скоуп тест-копии минимальный: ai-box+front из develop, своя БД ai_box_test и Redis 2/3, DR/MCP — общие с основной копией сервера
## [2026-07-04] ingest | Тест-зона test.doitai.ru работает: тест-стек ai-box из develop (своя БД ai_box_test, Redis 2/3, staging, биллинг off), фронт develop через CI (success), тест-vhost отрендерены (гоча: entrypoint nginx рендерит шаблоны только на старте — testzone-enable теперь с --force-recreate), test-app/api 200, admin 302→login. DR/MCP у тест-копии общие с основной (gateway:8083/8084). Ожидает: DNS api.test.doitai.ru и расширение SAN-сертификата
## [2026-07-04] ingest | Тест-зона test.doitai.ru завершена: DNS api.test добавлен, SAN-сертификат расширен до 7 доменов (webroot через работающий nginx), все тест-домены с честным TLS (app/api 200, admin 302), основная копия не задета. bd qpa закрыта
## [2026-07-05] ingest | GPU на doitai установлен и ollama переведена на карту: RTX 2080 Ti, драйвер 550.163.01 (DKMS), Container Toolkit runtime, single-GPU режим ollama-router, модели на /mnt/data/ollama (новый диск sdb 20G ext4→/mnt/data, docker остался на sda). Инференс 100% GPU ~85 ток/с (было CPU). Два бага установки исправлены: libcuda1 не тянется nvidia-driver (без него CUDA N/A→CPU), NVIDIA_DRIVER_CAPABILITIES=compute,utility обязателен для device-reservations. Приложения (осн+тест) переключены на ollama-router:11434. pdn-cleaner пока внешний (ждёт HF_TOKEN)
## [2026-07-05] ingest | doitai: место под docker решено. Новый диск sdb увеличен до 40G (hot-resize БЕЗ ребута, resize2fs online). docker data-root → /mnt/data/docker (sdb). ВАЖНО: Docker 29 хранит образы в containerd image store (/var/lib/containerd 18G), НЕ в overlay2 — перенос docker data-root их не забирает, перенесён и containerd root (config.toml root=/mnt/data/containerd). Итог: sda 3.8G/40 (только система+БД-volumes), sdb 25G/40 (образы+модели). GPU/приложения/тест/БД целы. daemon.json: домержен data-root к nvidia-runtime (не перезатёр). Шаг 3 (БД-volumes на быстрый sda) — не делали, БД пока на sdb в data-root
## [2026-07-05] ingest | pdn-cleaner переведён на GPU (doitai): GPU-образ torch cu124 (UV_NO_CACHE против раздувания пика сборки ~25G), модель на /mnt/data/pdn-models, BERT-NER на карте, маскирование проверено (ИНН/телефон→маска). ollama+pdn делят одну RTX 2080 Ti on-demand (пик ~9G/11G). Явные имена проектов ai_box_pdn/ollama_router (compose в подкаталогах пересекался по «docker»). NVIDIA_DRIVER_CAPABILITIES для pdn (тот же CPU-fallback баг). PDN_CLEANER_URL+OLLAMA_BASE_URL приложений (осн+тест) → локальные. Диск sdb 50G, БД на быстром sda (шаг3). Итог: GPU-стек doitai полностью локальный
## [2026-07-05] ingest | Модели закреплены в VRAM постоянно (doitai, требование прода — не грузить на запрос): ollama qwen3:8b+embeddinggemma держатся через preloader min_replicas hints, НО preloadModel слал только /api/generate — для embedding не удерживает, добавлен fallback на /api/embed (router.go). pdn BERT грузился на CPU (warmup без .to(device)) — патч api.py (model.to(cuda) в warmup/lifespan) + bert.py (входы на device, логиты .cpu()), CPU-fallback сохранён. Итог: 3 процесса в VRAM (qwen 6.2G llama-server + gemma 0.8G llama-server + pdn BERT 0.87G python) = 7.9G/11.3G, маскирование ФИО+ИНН+паспорт на GPU, latency 0.36с
## [2026-07-05] query | Нужен ли Kubernetes / Ansible? → k8s не нужен (2 сервера, shared-GPU конфликтует с device-plugin, всё работает на compose), Ansible не нужен (bootstrap-скрипт проще для 2 хостов). Решение зафиксировано в decisions/orchestration-no-k8s.md, задача jfb переоформлена на bootstrap-скрипт
## [2026-07-05] ingest | Аудиты параллельными агентами. GPU (u83): flash attention + KV q8_0 (защита VRAM на длинных контекстах), nvidia-persistenced, fp16-BERT отклонён (CUDA-overhead доминирует, VRAM рос без ускорения — откат в fp32), num_parallel 2 оставлен. Итог 7944/11264 VRAM, 86.7 ток/с. Prod-конфиги (aki): mariadb buffer_pool через env MARIADB_BUFFER_POOL (doitai 4G), redis maxmemory+volatile-lru (очереди не теряются), nginx gzip+fastcgi_buffers, opcache уже оптимален. Всё параметризовано env для безопасности addons. realpath_cache в ai-box/MCP отложен (репо на develop с билинг-работой)
## [2026-07-05] ingest | Тест-зона расширена до полного dev-контура: развёрнуты тест-DR и тест-MCP из develop (клоны git init, БД ai_box_dr_test/ai_box_mcp_test, Redis 4/5 и 14/15, контейнеры ai-box-dr-test-*/ai-box-mcp-test-php, vhost 8183/8184). Тест ai-box переключён на тест DR/MCP (gateway:8183/8184, не общие), MCP→тест ai-box (8185). GitHub деплой develop→test проверен (CI-прогоны DR/MCP success). Также в тест-БД: админ admin@test.doitai.ru, биллинг on, 2 клиента (all-inclusive [all_inclusive+unlimited_tokens] 5000₽ + base 1000₽). Дев-ветки всех app-репо вылиты (realpath DR перенесён master→develop)

## [2026-07-06] ingest | Раскатка develop на test.doitai.ru + серт тест-доменов
Запушены develop ai-box-back (45) и ai-box-front (13, +VITE-ULID в workflow тест-зоны).
Интеграция config-ассистента (01KWVSZ…) сеется миграцией, активна. Серт doitai.ru
расширен SAN'ами тест-доменов (webroot). Детали — [[concept:deployment-topologies]].

## [2026-07-07] ingest | Инцидент: смена UUID GPU на doitai — ollama и pdn легли
RTX 2080 Ti сменила UUID после драйвера; ollama-gpu0 и ai-box-pdn-cleaner Exited(128)
(device unknown). Пул роутера пуст → титлер/эмбеддинги/ПДн не работали. Фикс: новый
UUID в оба .env + пересоздание (с -p и --env-file). Детали — [[integration:gpu-services]].

## [2026-07-23] ingest | Поток голосовой диктовки: nginx-проксирование ASR (auth_request)
Перенос из брифа ai-box: две локации в шаблоне API-домена — ws-поток
`…/asr/stream` (`auth_request`→`proxy_pass` на внешний ASR `${ASR_WS_UPSTREAM}`,
апгрейд, буферизация off, 600с) и внутренний подзапрос `= /internal/asr-authorize`
в Laravel. Снят `^~` с `location /api` (иначе regex-локация не получит управление).
`ASR_WS_UPSTREAM` в `nginx.environment` с инертным дефолтом 127.0.0.1:9 (не `:?` —
чтобы фича не роняла nginx на стендах без голоса). У нас исходников два
(`templates/` + `templates-test/`), не три: `conf.d/*.conf` — рендер-артефакты.
`nginx -t` чист на обоих; закрытый гейт → 403 на обеих поверхностях (assistant +
i/{integration}). Боевая раскатка (reload, nc, реальный ASR-адрес, опц. firewall)
— по runbook. Детали — [[decision:voice-dictation]]. bead `ai-box-infra-0fq`.

## [2026-07-23] ingest | Раскатка голосовой диктовки на doitai (дев-контур)
`.env` doitai += ASR_WS_UPSTREAM=192.168.100.29:49153. Инфра-коммит 1016c3e
доставлен CI deploy-doitai.yml: прод-vhost отрендерил ASR-локацию (инертна,
asr.enabled=false). Дев-контур test.doitai.ru: make testzone-enable
(пере-копия тест-шаблонов — CI-`up` их не обновляет, они копии; + recreate).
Достижимость ASR из nginx-контейнера подтверждена (nc → open, снят вопрос №1
брифа). Закрытый гейт → 403 на api.test.doitai.ru (assistant + i/{integration}).
Осталось: открытый гейт (asr.enabled=true в тест-ai-box — app-сторона) и amulex
(отдельный деплой по runbook). Детали — [[decision:voice-dictation]]. bead 0fq.

## [2026-07-24] ingest | make nginx-reload не применял правки шаблонов
Выкатка deny-блока /api/internal/ для ai-box (bead qhdg) вскрыла: envsubst образа
nginx отрабатывает только в entrypoint, а CI зовёт `nginx -s reload` — шаблон
доезжает, деплой зелёный, конфиг старый. Та же беда со вторым слоем: тестовые
vhost'ы рендерятся из копий templates-test/. Починено в Makefile: nginx-render
(рендер внутри работающего контейнера) + testzone-sync (копии, no-op без тест-зоны),
nginx-reload = рендер → nginx -t → reload. Детали и trade-off'ы —
[[decision:nginx-template-rendering]]. Биды 99co, qhdg.

## [2026-07-25] ingest | Neo4j + GDS в общий стек (decision + shared-stack, задача ai-box-infra-f15 / источник ai-box-dr-drf)

Соседняя команда реестра (`ai-box-data-registry`) завела у себя `ai-box-dr-drf`
на нас: поднять Neo4j Community + GDS в общей инфре для knowledge-графа. Решение —
сервис `neo4j` (5.26.28-community) на `ecosystem` рядом с qdrant, GDS 2.13.4
ставим сами идемпотентным `make neo4j-plugins` (пин+sha256, не NEO4J_PLUGINS —
снят egress со старта контейнера). Trade-off'ы и пины — [[decision:neo4j-graph-store]].

## [2026-07-27] ingest | env-per-stend: STAND-слои env/<stend>, выпил плоского .env, eco-deploy hook

Эталон на infra (bead ai-box-infra-11l, Фаза 1 на ветке feat/env-per-stend, не
пушено). Несекретный конфиг стендов — в git (`env/{local,doitai,amulex}/config.env`
+ `env/example/*`), секреты — некоммитный `env/<stend>/secrets.env`. Стенд — `STAND`
(дефолт local), Makefile слоями подключает config→testzone→secrets и мержит через
`docker compose --env-file`. Плоский `.env` выпилен (проверено `make config` без
него). Пост-деплой — `deploy/post-deploy.sh` + цель `eco-deploy`, workflow doitai
переведён на `STAND=doitai make eco-deploy`. Боевая миграция серверов + пуш — Фаза 2
(runbook + разрешение). Trade-off'ы — [[decision:env-per-stend]].

## [2026-07-30] ingest | Раннбук боевой миграции env-per-stend (Фаза 2)

`docs/runbooks/env-per-stend-migration.md` (bead ai-box-infra-11l): гейт перед
мержем в master (мерж = автодеплой doitai), механический diff ключей живого
`.env` ↔ слои `env/<stend>/*`, `secrets.env` на сервере (7 ключей, chmod 600),
прогон `STAND=doitai make config` во временном worktree (деплойный клон ветку не
переключает — workflow тянет master в текущую), инвентарь вызовов `make` из
cron/Jenkins (без `STAND` берётся стенд `local`), постпроверки и выпил плоского
`.env` после контрольного срока. Названы тихие ключи-с-дефолтом (`QDRANT_VERSION`
— даунгрейд storage, `ASR_WS_UPSTREAM` — заглушка 127.0.0.1:9, `ECOSYSTEM_SUBNET`)
и порядок мержа с `feat/polygon-runner-ingress` (конфликт Makefile/.env.example,
обязательный `TEST_MCP_DOMAIN`). Пробелы — [[decision:env-per-stend]].

## [2026-07-30] ingest | Маркер стенда .stand + громкая ошибка на незнакомом стенде

Закрыт пробел env-per-stend: `STAND ?= $(strip $(shell cat .stand …))` — приоритет
env → маркер `./.stand` (некоммитный, в .gitignore) → `local`. Незнакомый стенд
валит `make` сразу `$(error)`-ом вместо невнятного вороха `:?` от compose,
`make config` печатает `[stand] <стенд> (env/<стенд> [+ testzone])`. Мотив: вызовы
`make` из cron (`certs-renew`)/Jenkins/ssh на боевом хосте больше не зависят от
того, вспомнил ли человек `STAND=` — иначе брался конфиг dev-машины и рендерились
чужие домены. Проверено на пяти режимах (без маркера, маркер с пробелами, env
поверх маркера, битый маркер, штатный local). Раннбук Фазы 2 обновлён —
[[decision:env-per-stend]].

## [2026-07-30] ingest | Внешний ingress для раннеров полигона ai-box-mcp

Заведён публичный вхост `mcp.test.doitai.ru` (тест-зона, ветка
`feat/polygon-runner-ingress`, bead `ai-box-infra-3q9`): единственный
публичный вход в ai-box-mcp, `location ^~ /api/external/` прямым
`fastcgi_pass` (без `location ~ \.php$` — control plane `/api/v1` без
авторизации не должен быть достижим ни при каком regex-обходе),
`location /` → 404. Доставка шаблона — `make testzone-sync` (проверено
статически: копия `templates-test/mcp.conf.template` →
`templates/test-mcp.conf.template` идентична). Заодно починен дрейф
`DOMAINS` в Makefile — тестовые домены (уже в живом 7-SAN сертификате)
добавлены явно, иначе `certs-init` сузил бы SAN. Обновлены
[[entity:nginx-edge]], [[concept:deployment-topologies]]. Реальный
DNS/сертификат/деплой — вне этой задачи, делает главная сессия.

## [2026-07-30] ingest | Сведение env-per-stend с ветку полигона + README/certs-expand

Ветка `feat/polygon-runner-ingress` (bead ai-box-infra-3q9) влита в
`feat/env-per-stend` — в master уезжают одним гейтом. Разведено: Makefile (слои
env-per-stend + `DOMAINS` с тест-SAN через `$(if …)`; проверено — doitai 8 `-d`,
amulex 4, пустых `-d` нет), `TEST_MCP_DOMAIN` переехал из плоского `.env` в
`env/doitai/testzone.env`, добавлен шаблон `env/example/testzone.env`,
`.env.example` удалён как мёртвый дубль. README переписан под стенды (раскладка
файлов, приоритет STAND → .stand → local, dev через симлинк
`docker-compose.override.yml`, который теперь в .gitignore). Новая цель
`certs-expand`: `certbot renew` SAN НЕ расширяет, поэтому домен, добавленный в
`DOMAINS`, без неё в сертификат не попадал бы (тихая поломка — nginx стартует и
`nginx -t` проходит, серт отдаётся с чужим именем). Раннбук Фазы 2 стал общим
гейтом на две задачи: A-запись `mcp.test.doitai.ru` → мерж → `certs-expand` →
приёмка внешнего контура (401/404/404). Страницы — [[decision:env-per-stend]],
[[entity:shared-stack]], [[concept:deployment-topologies]], [[entity:nginx-edge]].

## [2026-07-30] ingest | Фаза 2 env-per-stend ВЫПОЛНЕНА на doitai + внешний контур раннеров

Мерж `0319a93` в master, деплой зелёный (3м09с). Сверка живого `.env` с слоями
вскрыла три ключа, потеря которых ломала бы тихо: `QDRANT_VERSION=v1.17.0`
(дефолт v1.12.4 = даунгрейд storage), `REDIS_MAXMEMORY=2gb` (дефолт 512mb —
вчетверо меньше, при volatile-lru очереди без TTL не вытесняются → OOM на
запись), `ASR_WS_UPSTREAM`; остальные 16 совпали. `COMPOSE_PROJECT_NAME` в
`.env` не было — имя проекта пинится `name: ai_box_infra` в compose, поэтому
тома не «переехали» (главный риск потери данных снят проверкой, а не удачей).
Пересоздан только `infra_nginx`; mariadb/redis/qdrant/neo4j не перезапускались,
`/var/lib/mysql` 469M до и после, стеки вне эко-контура (`ai_box_pdn`,
`docker`/ollama) не тронуты. До мержа сняты бэкапы: дамп 7 баз MariaDB, копия
каталога данных Redis, снапшот коллекции Qdrant. Сертификат doitai.ru расширен
`make certs-expand` до 8 SAN (89 дней), приёмка внешнего контура
`mcp.test.doitai.ru`: runner/poll 401, /api/v1 404, / 404, `.php`-обход 404.
Побочно: на doitai не было cron продления сертификата вовсе — поставлен
недельный `make certs-renew`. Уроки и остаток (выпил плоского `.env` после
контрольного срока; amulex не трогаем) — `docs/runbooks/env-per-stend-migration.md`,
[[decision:env-per-stend]].

## [2026-07-30] ingest | Плоский .env на doitai выпилен — переход завершён

По решению человека выпил сделан в день мержа, без выдержки контрольного срока.
Перед удалением: все 19 ключей сверены со слоями **по значениям** (не только по
именам) — расхождений нет; на хосте нет файлов, ссылающихся на
`ai-box-infra/.env` (app-стеки держат свои). Копии — вне git:
`~/env-backup-doitai-2026-07-30.env` и в каталоге бэкапов, chmod 600, `cmp`
побайтно (откат остаётся возможным: положить копию назад + `git revert`).
После удаления прогнаны ВСЕ пути, которые неявно опирались на автоподхват
`.env` докером: ручной `gh workflow run` → полный `git pull && make eco-deploy`
зелёный; `make nginx-reload`; путь cron `make certs-renew` (сертификат не due →
`No renewals were attempted` + render/test/reload); `make config`/`make ps`
(6 сервисов Up); домены снаружи. Гоча: `certbot renew --dry-run` без
`--non-interactive` подвисает и держит `/etc/letsencrypt/.certbot.lock` —
следующий запуск падает `Another instance of Certbot is already running`.
Детали — `docs/runbooks/env-per-stend-migration.md` (Шаг 8),
[[decision:env-per-stend]].

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

## [2026-07-30] ingest | Лендинг doitai выкачен: doitai.ru и test.doitai.ru

Боевая часть bead ai-box-infra-5jk. На doitai: удалён устаревший рендер
conf.d/root.conf (шаблона больше нет — рендер его не перезаписал бы), деплой
пересоздал nginx (новые env/маунты), `make certs-expand` довёл SAN до 9
(`test.doitai.ru`), контент выкачен workflow'ами ai-box-site. Приёмка: корень
200, /pricing-models без .html, README/.git/docs 403, PDF оферты (в
assets/docs/) не задет deny-правилом, тест-копия с noindex на страницах И
ассетах, соседние vhost'ы и amulex без регресса. Гоча деплоя: секреты GitHub
НЕ наследуются между репозиториями — в ai-box-site DOITAI_SSH_KEY отсутствовал
(rsync падал `error in libcrypto` на пустом ключе); заведён выделенный CI-ключ
(`~/.ssh/doitai_site_deploy`, отдельная строка в authorized_keys — отзываем
независимо от личного). Push-триггеры включены. Репетиция развилки прошла на
локальном стенде до пуша (тот же сценарий: rm устаревшего рендера +
force-recreate). Подробности — [[entity:nginx-edge]].

## [2026-07-31] ingest | Фикс RAM ollama: use_mmap при полном GPU-офлоаде

Bead ai-box-infra-txo, груминг + главный фикс. Диагноз по cgroup (anon=6.4G,
file=106M — НЕ page-cache): ollama 0.31.1 при полном офлоаде передаёт раннеру
`--no-mmap`, хостовая анонимная копия GGUF живёт рядом с VRAM (плюс 2.9G свопа).
Фикс — `PARAMETER use_mmap true` в Modelfile, тег qwen3:8b-q4_K_M пересоздан под
тем же именем. Итог: host used 9.7G→3.5G, available 2.0→8.2G, своп 4.9→2.4G,
флапа нет, путь app→router→gpu0 отвечает. Гоча про `ollama pull` (перезатрёт
манифест) — `bd memories ollama-doitai`. Остаток txo (right-size mariadb/redis,
mem-лимиты, структурный вопрос) — в биде. Заодно закрыт uzn (queue за profiles
в ai-box develop d8b640e0) и прибраны merged-ветки infra. [[integration:gpu-services]].

## [2026-07-31] ingest | Прод-vhost mcp.doitai.ru — внешний контур раннеров

Прод-аналог mcp.test.doitai.ru: `nginx/templates/mcp.conf.template`
(наружу только `/api/external/`), `MCP_DOMAIN` с инертным дефолтом
`mcp.invalid` в compose, условный `-d` в DOMAINS, `MCP_DOMAIN=mcp.doitai.ru`
в `env/doitai/config.env`. Обновлены [[entity:nginx-edge]],
[[concept:deployment-topologies]]. Bead [[bead:ai-box-infra-lhn]].

## [2026-08-08] ingest | Маршруты корпоративной wiki: /wiki/ на api-домене и vhost 8086

Вика (`ai-box-template-wiki-global`) переехала в экосистему без своего домена:
`location ^~ /wiki/` в шаблоне api-vhost (rewrite префикса, upstream
`ai-box-wiki-web:8080`) и внутренний `nginx/conf.d/internal-wiki.conf` на 8086.
Контракты и `WIKI_URL=http://gateway:8086` — в README, детали и грабли —
[[entity:nginx-edge]], [[concept:contracts]].
