# Runbook: миграция боевых стендов на env-per-stend (Фаза 2)

> **Статус: ВЫПОЛНЕН на doitai 2026-07-30** (merge `0319a93` в master, деплой
> зелёный 3м09с). Пересоздан **только** `infra_nginx` (новый `TEST_MCP_DOMAIN`
> в environment); mariadb/redis/qdrant/neo4j не перезапускались (uptime 2 недели
> / 4 дня), тома и размер данных те же (`/var/lib/mysql` 469M до и после),
> стеки вне эко-контура (`ai_box_pdn`, `docker`/ollama) не тронуты. Сертификат
> расширен до 8 SAN, приёмка внешнего контура пройдена (401/404/404/404).
>
> Плоский `.env` на doitai **удалён в тот же день** (по решению человека, без
> выдержки контрольного срока — все 19 ключей совпадали со слоями значение-в-
> значение, внешних ссылок на файл на хосте нет; копии лежат в
> `~/env-backup-doitai-2026-07-30.env` и в каталоге бэкапов, chmod 600).
>
> **Осталось:** стенд **amulex** — по решению от 2026-07-30 его не трогаем,
> Фаза 2B ниже остаётся инструкцией на будущее окно.
>
> Ветка `feat/polygon-runner-ingress` была влита сюда (merge `da54f89`): внешний
> вхост `mcp.test.doitai.ru` уехал в master тем же мержем, поэтому гейт ниже
> один и общий на две задачи — beads `ai-box-infra-11l` и `ai-box-infra-3q9`.
>
> Решение и trade-off'ы — `.claude/wiki/decisions/env-per-stend.md`, внешний
> контур — `.claude/wiki/entities/nginx-edge.md`. Спека —
> `docs/superpowers/specs/2026-07-08-env-per-stend-design.md`, план Фазы 1 —
> `docs/superpowers/plans/2026-07-27-env-per-stend-infra.md`.

## Что меняется на серверах

Плоский `/var/www/ai-box-infra/.env` (вне git, свой на каждом сервере)
заменяется слоями:

```
env/<stend>/config.env    несекретный конфиг — В GIT
env/<stend>/testzone.env  overlay тест-зоны — В GIT (только стенд doitai)
env/<stend>/secrets.env    секреты — НА СЕРВЕРЕ, chmod 600, gitignored
```

Стенд выбирается так: env-переменная `STAND` → некоммитный маркер `./.stand`
(одна строка с именем стенда) → `local`. Незнакомый стенд валит `make` сразу с
внятным сообщением (нет `env/<stend>/config.env`). Makefile мержит слои
многократным `docker compose --env-file` (секреты поверх). Деплойный
вызов doitai становится `export STAND=doitai && make eco-deploy`
(`build-base` + `up` + идемпотентный `deploy/post-deploy.sh`).

## Главные риски (читать до начала)

1. **Push в master = автодеплой doitai** (`.github/workflows/deploy-doitai.yml`,
   trigger `push: [master]`). Правки Makefile и workflow сцеплены: в момент
   мержа на сервере уже обязан лежать `env/doitai/secrets.env`.
2. **Незаданный `:?`-ключ валит `compose up` целиком** на этапе интерполяции
   (класс грабки `NEO4J_PASSWORD`, `bd memories neo4j-password`). Хорошая
   новость: до контейнеров дело не доходит — **работающий прод не падает**,
   деплой просто красный. Обязательные ключи:
   `ROOT_DOMAIN`, `FRONT_DOMAIN`, `API_DOMAIN`, `ADMIN_DOMAIN`,
   `DB_ROOT_PASSWORD`, `AI_BOX_DB_PASSWORD`, `AI_BOX_DR_DB_PASSWORD`,
   `AI_BOX_MCP_DB_PASSWORD`, `REDIS_PASSWORD`, `BROWSERLESS_TOKEN`,
   `NEO4J_PASSWORD` + при активной тест-зоне `TEST_FRONT_DOMAIN`,
   `TEST_API_DOMAIN`, `TEST_ADMIN_DOMAIN`, `TEST_MCP_DOMAIN` (последний пришёл
   с веткой полигона; в репозитории уже лежит в `env/doitai/testzone.env`).
3. **Ключ с дефолтом, потерянный при переносе, ломает тихо** — деплой зелёный,
   поведение другое. Опасные:
   - `QDRANT_VERSION` (дефолт `v1.12.4`): на doitai живёт новее — потеря ключа
     пересоздаст qdrant на старом образе, **storage не поднимется**;
   - `ECOSYSTEM_SUBNET`/`ECOSYSTEM_GATEWAY` (дефолт `172.30.0.0/24`/`.1`):
     расхождение с живой сетью → попытка пересоздать сеть `ecosystem`;
   - `ASR_WS_UPSTREAM` (дефолт-заглушка `127.0.0.1:9`): в закоммиченном
     `env/doitai/config.env` его **нет**, а на doitai ASR работает
     (`ai-box-infra-0fq`) → без переноса ключа диктовка отвалится;
   - `MARIADB_BUFFER_POOL`, `REDIS_MAXMEMORY`, `NEO4J_HEAP`/`NEO4J_PAGECACHE`,
     `NEO4J_VERSION`, `CERT_NAME`, `APPS_ROOT`.
4. **Не положенный маркер `.stand` = стенд `local`.** Вызов `make` на боевом
   сервере, где нет ни `STAND=` в команде, ни маркера, возьмёт
   `env/local/config.env` (домены dev-машины) — отрендерит чужие vhost'ы и/или
   запросит сертификат на чужой lineage. Маркер закрывает это на хосте раз и
   навсегда (Шаг 5), но положить его — обязательный шаг, а не формальность.
5. **Новый публичный домен `mcp.test.doitai.ru` приезжает тем же мержем**
   (внёс merge ветки полигона). Он не в SAN живого сертификата, а
   `make certs-renew` SAN **не расширяет** — `certbot renew` перевыпускает старый
   список. Пока не сделан `make certs-expand`, vhost отдаёт серт с чужим именем
   (nginx при этом стартует и `nginx -t` проходит — тихая поломка только у
   клиента). Порядок: A-запись → мерж/деплой → `certs-expand` → проверки.

---

## Фаза 2A — doitai (первый, автодеплой)

### Шаг 0. Подготовка на dev-машине (сервер не трогаем)

Запушить ветку в origin — **деплой не триггерится** (workflow только на master):

```bash
git push -u origin feat/env-per-stend
```

Что в репозитории уже сделано и в ветке не требует возвратов: README переписан
под слои env (`.env.example` удалён), маркер `.stand`, слой
`env/doitai/testzone.env` с `TEST_MCP_DOMAIN`, цель `certs-expand`, влита ветка
полигона. Отдельно **DNS**: A-запись `mcp.test.doitai.ru` на IP doitai — это
внешняя панель, делается человеком до Шага 7.

### Шаг 1. Сверка ключей на doitai (read-only)

На сервере, **не переключая ветку** деплойного клона:

```bash
cd /var/www/ai-box-infra
git fetch origin feat/env-per-stend
git show origin/feat/env-per-stend:env/doitai/config.env   > /tmp/new-config.env
git show origin/feat/env-per-stend:env/doitai/testzone.env > /tmp/new-testzone.env
git show origin/feat/env-per-stend:env/example/secrets.env > /tmp/new-secrets.env

keys() { grep -hoE '^[[:space:]]*[A-Z0-9_]+=' "$@" 2>/dev/null | tr -d ' =' | sort -u; }

echo '--- есть в живом .env, НЕТ в новых слоях (перенести или осознанно бросить) ---'
comm -23 <(keys .env) <(keys /tmp/new-config.env /tmp/new-testzone.env /tmp/new-secrets.env)

echo '--- есть в новых слоях, НЕТ в живом .env (появились позже) ---'
comm -13 <(keys .env) <(keys /tmp/new-config.env /tmp/new-testzone.env /tmp/new-secrets.env)

echo '--- расхождение значений по общим несекретным ключам ---'
for k in $(comm -12 <(keys .env) <(keys /tmp/new-config.env)); do
  printf '%-22s server=%-28s repo=%s\n' "$k" \
    "$(grep -E "^$k=" .env | tail -1 | cut -d= -f2-)" \
    "$(grep -E "^$k=" /tmp/new-config.env | cut -d= -f2-)"
done
```

Отдельно — сверка с **фактически работающим** стеком (истина в контейнерах,
а не в `.env`; их могли поднимать с иными значениями):

```bash
docker inspect --format '{{.Config.Image}}' infra_qdrant infra_neo4j infra_mariadb
docker network inspect ecosystem --format '{{range .IPAM.Config}}{{.Subnet}} {{.Gateway}}{{end}}'
docker exec infra_nginx sh -c 'grep -h "server_name\|asr" /etc/nginx/conf.d/*.conf | sort -u' | head -30
```

Зафиксировать результат сверки (сюда, в раннбук, или в комментарий bead).

### Шаг 2. Финализировать `env/doitai/config.env` (на dev-машине, в ветке)

Раскомментировать/поправить закомментированные `# СВЕРИТЬ`-ключи фактическими
значениями сервера, добавить недостающие (как минимум `ASR_WS_UPSTREAM`, если
Шаг 1 его показал). Ключ, оставленный на дефолте, — только осознанно и с
комментарием, почему дефолт верен.

```bash
STAND=local make config && echo "интерполяция стенда local не сломана"
git add env/doitai/config.env && git commit -m "feat(env): doitai — значения сверены с боем"
git push
```

### Шаг 3. `env/doitai/secrets.env` на сервере

Секреты берём **из живого `.env`** (они уже боевые — master-деплой с
`NEO4J_PASSWORD:?` проходит зелёным с 2026-07-25, значит все секреты в `.env`
есть). Ничего не перегенерировать: смена пароля MariaDB/Redis/Neo4j требует
согласованной правки в app-контурах — это не эта задача.

```bash
cd /var/www/ai-box-infra
umask 077 && mkdir -p env/doitai
for k in DB_ROOT_PASSWORD AI_BOX_DB_PASSWORD AI_BOX_DR_DB_PASSWORD \
         AI_BOX_MCP_DB_PASSWORD REDIS_PASSWORD BROWSERLESS_TOKEN NEO4J_PASSWORD; do
  grep -E "^$k=" .env | tail -1
done > env/doitai/secrets.env
chmod 600 env/doitai/secrets.env
grep -c . env/doitai/secrets.env   # ожидание: 7
grep -n '[#$]' env/doitai/secrets.env || echo "символов #/\$ нет — make -include не сломается"
```

Пустое значение любого ключа — стоп: доискать реальный секрет (для
`NEO4J_PASSWORD` он обязан совпадать с реестровым контуром, `bd show ai-box-infra-80w`).

> Файл инертен до мержа: master-версия Makefile его не читает. Создание
> `secrets.env` откатывать не нужно ни при каком сценарии.

### Шаг 4. Прогон `make config` на сервере до мержа

Деплойный клон переключать на ветку **нельзя** (workflow делает
`git pull origin master` в текущей ветке). Проверяем во временном worktree:

```bash
cd /var/www/ai-box-infra
git worktree add /tmp/eps-check origin/feat/env-per-stend
mkdir -p /tmp/eps-check/env/doitai
cp env/doitai/secrets.env /tmp/eps-check/env/doitai/secrets.env
make -C /tmp/eps-check STAND=doitai config; echo "exit=$?"
```

Ожидание: `exit=0`, первая строка — `[stand] doitai (env/doitai + testzone)`.
`STAND=doitai` здесь задаётся явно: маркер `.stand` некоммитный, во worktree его
нет, и без переменной проверка ушла бы на стенд `local`.

Также глазами сверить рендер до боя:

```bash
make -C /tmp/eps-check STAND=doitai -n up | head -3          # видны все --env-file
cd /tmp/eps-check && STAND=doitai docker compose --env-file env/doitai/config.env \
  --env-file env/doitai/testzone.env --env-file env/doitai/secrets.env config \
  | grep -E 'image:|_DOMAIN|Subnet' | sort -u | head -30
```

Уборка (обязательно — секрет во временном каталоге):

```bash
shred -u /tmp/eps-check/env/doitai/secrets.env 2>/dev/null || rm -f /tmp/eps-check/env/doitai/secrets.env
cd /var/www/ai-box-infra && git worktree remove --force /tmp/eps-check
```

`docker compose config` только рендерит — контейнеры и сети не трогает.

### Шаг 5. Маркер стенда + инвентарь вызовов `make` (до мержа)

Положить маркер на сервере — **можно и нужно заранее**: master-версия Makefile
его не читает, файл gitignored и `git pull` ему не мешает.

```bash
cd /var/www/ai-box-infra
echo doitai > .stand
```

После мержа любой вызов `make` из этого каталога (cron, Jenkins, руки в ssh)
сам подхватит стенд `doitai`; ошибочное имя в маркере валит `make` сразу, а не
рендерит чужой конфиг. Проверка после мержа — первая строка `make config`:
`[stand] doitai (env/doitai + testzone)`.

Дальше — инвентарь: убедиться, что нет вызовов `make` из **другого** каталога
(там маркер не подхватится) и что ни один вызов не задаёт `STAND=` руками с
неверным значением (env перекрывает маркер).

```bash
crontab -l | grep -n make; sudo crontab -l 2>/dev/null | grep -n make
grep -rn "ai-box-infra" /etc/cron.d/ /etc/cron.*/ 2>/dev/null
systemctl list-timers --all | grep -i infra
```

Каноничный вид cron-строки продления сертификата (стенд берётся из маркера;
`STAND=doitai` перед `make` тоже допустим — явное не мешает):

```
0 4 * * 1  cd /var/www/ai-box-infra && make certs-renew
```

`certs-init` не запускать: он занимает :80 standalone-режимом и конфликтует с
работающим nginx (потому и не входит в `post-deploy.sh`).

### Шаг 6. Мерж в master → автодеплой

```bash
git checkout master && git pull && git merge --no-ff feat/env-per-stend
git push origin master
gh run watch   # или: gh run list --limit 1
```

Красный деплой на интерполяции = недобранный ключ; прод при этом работает по
старым контейнерам. Починить `env/doitai/{config,secrets}.env` (несекретное —
коммитом, секреты — на сервере) и повторить: `gh workflow run "Deploy doitai.ru"`
либо на сервере `cd /var/www/ai-box-infra && export STAND=doitai && make eco-deploy`.

### Шаг 7. Сертификат нового домена + постпроверки

Маркер уже лежит, поэтому `STAND=` в командах ниже не обязателен — оставлен
явным для читаемости.

Сначала расширить SAN под `mcp.test.doitai.ru` (A-запись обязана существовать —
валидация webroot'ом ходит на этот домен):

```bash
cd /var/www/ai-box-infra
dig +short mcp.test.doitai.ru                # ожидание: IP doitai
make certs-expand                            # --expand на lineage doitai.ru + reload
docker compose exec nginx openssl x509 -noout -text \
  -in /etc/letsencrypt/live/doitai.ru/fullchain.pem | grep -A1 'Subject Alternative Name'
```

Ожидание: 8 SAN (4 публичных + 3 тест-зоны + `mcp.test.doitai.ru`).

```bash
STAND=doitai make ps                        # все сервисы Up, не restarting
STAND=doitai make nginx-test                # рендер+конфиг чист
STAND=doitai make neo4j-smoke               # ожидание: gds 2.13.4
docker inspect --format '{{.Config.Image}}' infra_qdrant   # версия НЕ откатилась
for h in doitai.ru app.doitai.ru api.doitai.ru admin.doitai.ru \
         app.test.doitai.ru api.test.doitai.ru admin.test.doitai.ru; do
  printf '%-26s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 https://$h/)"
done
```

Приёмка внешнего контура (критерии bead `ai-box-infra-3q9`) — TLS уже валидный,
поэтому без `-k`:

```bash
curl -sS -o /dev/null -w 'runner/poll  %{http_code}\n' -m 10 \
  -X POST https://mcp.test.doitai.ru/api/external/runner/poll     # ожидание: 401
curl -sS -o /dev/null -w 'api/v1       %{http_code}\n' -m 10 \
  https://mcp.test.doitai.ru/api/v1/integrations                  # ожидание: 404
curl -sS -o /dev/null -w 'root         %{http_code}\n' -m 10 \
  https://mcp.test.doitai.ru/                                     # ожидание: 404
```

Отдельно — живой сценарий приложения (создание чата/шаг) и то, что диктовка
(ASR-локация) отвечает, если `ASR_WS_UPSTREAM` переносился.

### Шаг 8. Выпил плоского `.env`

Пока `.env` жив, откат = `git revert` мержа (старый Makefile снова читает
`.env`). Отсюда правило: удалять **только с бэкапом вне git** — тогда откат
остаётся возможным (положить копию назад) и контрольный срок необязателен.
На doitai выпил сделан в день мержа; перед удалением проверено:

1. **все ключи совпадают со слоями по значениям**, а не только по именам:

```bash
cd /var/www/ai-box-infra
for k in $(grep -oE '^[A-Z0-9_]+' .env | sort -u); do
  old=$(grep -E "^$k=" .env | tail -1 | cut -d= -f2-)
  new=$(grep -hE "^$k=" env/$(cat .stand)/config.env env/$(cat .stand)/testzone.env \
                        env/$(cat .stand)/secrets.env 2>/dev/null | tail -1 | cut -d= -f2-)
  [ "$old" = "$new" ] || echo "РАСХОДИТСЯ: $k"
done; echo "проверено"
```

2. **никто на хосте не читает этот файл** (app-стеки держат свои `.env`):

```bash
grep -rln 'ai-box-infra/\.env' /var/www --include='*.yml' --include='*.sh' \
     --include='Makefile' --include='*.conf' 2>/dev/null || echo 'ссылок нет'
```

Само удаление:

```bash
cd /var/www/ai-box-infra
umask 077 && cp -p .env ~/env-backup-doitai-$(date +%F).env
cmp -s .env ~/env-backup-doitai-$(date +%F).env && echo 'копия побайтно идентична'
rm .env
make config && echo 'стек не зависит от плоского .env'
```

После удаления прогнать **все** пути, которые могли неявно опираться на `.env`
(docker compose подхватывал его автоматически, поэтому зависимость была
невидимой):

- `gh workflow run "Deploy doitai.ru"` → полный `git pull && make eco-deploy`;
- `make nginx-reload` — путь post-deploy руками;
- путь cron'а — `make certs-renew` целиком: на не-due сертификате это безопасный
  no-op (`Certificate not yet due for renewal` → `No renewals were attempted`) и
  затем render+test+reload. **Не** гонять для этого `certbot renew --dry-run` без
  `--non-interactive`: он подвисает на запросе аккаунта staging'а и держит
  `/etc/letsencrypt/.certbot.lock`, после чего следующий запуск падает
  `Another instance of Certbot is already running` (лечится `docker rm -f`
  залипшего `*-certbot-run-*` и удалением lock-файла в томе);
- домены снаружи + `make ps`.

---

## Фаза 2B — amulex (своё окно, без автодеплоя)

Отличия от doitai:

- **Нет CI-триггера**: infra на amulex деплоится руками (Jenkins на eco-таргеты
  ещё не переведён — `ai-box-infra-ki7`). Мерж в master сам по себе на amulex
  ничего не меняет — стенд мигрирует отдельно, `git pull` делает человек.
- Маркер на сервере: `echo amulex > .stand` (кладётся заранее, как на doitai).
  Без маркера и без `STAND=` в команде — стенд `local` (риск 4). Проверить
  Jenkins-джобу, cron и шпаргалки в `docs/runbooks/split-cutover-ai-box.md` на
  предмет вызовов `make` из другого каталога.
- Тест-зоны нет → `env/amulex/testzone.env` не создаётся, слой не подключается.
- Исторические особенности контура: Redis DB-индексы прод-исторические
  (ai-box 0/1, DR 6/7, MCP 8/9 — не по README), фаза 3 (захват 80/443)
  не завершена, часть сервисов внешние (`192.168.101.114`). Сверку ключей
  делать по факту сервера, не по аналогии с doitai; `QDRANT_VERSION` там
  своя (в config.env закомментировано `v1.12.4` — проверить `docker inspect`).

Порядок шагов тот же: сверка ключей (Шаг 1) → финализация `env/amulex/config.env`
в master (уже без риска автодеплоя, обычным коммитом) → `secrets.env` на сервере
→ `STAND=amulex make config` (после `git pull` можно прямо в клоне, CI не мешает)
→ `STAND=amulex make eco-deploy` в окне → постпроверки → выпил `.env` после
контрольного срока.

---

## Ветка полигона: сведено, отдельного мержа не нужно

`feat/polygon-runner-ingress` (bead `ai-box-infra-3q9`) влита в
`feat/env-per-stend` мержем `da54f89` — в master обе задачи уезжают вместе, одним
гейтом. Что было разведено при сведении:

| Файл | Пересечение и как решено |
|---|---|
| `Makefile` | верх файла: слои env-per-stend (`STAND`/`.stand`/`-include`/`COMPOSE`) + `DOMAINS` полигона с тест-SAN через `$(if …)`. Проверено: doitai → 8 `-d`, amulex → 4, пустых `-d` нет |
| `docker-compose.testzone.yml` | обязательный `TEST_MCP_DOMAIN:?` — значение переехало в слой `env/doitai/testzone.env` |
| `.env.example` | удалён как мёртвый дубль; TEST_*-ключи описаны в новом `env/example/testzone.env`, пояснения ASR/Qdrant/Neo4j — в `env/example/config.env`/`secrets.env` |
| `.claude/wiki/{concepts/deployment-topologies.md,log.md}` | обе секции сохранены |
| SAN сертификата | добавлена цель `make certs-expand` (renew SAN не расширяет) — Шаг 7 |

Единственное, что осталось от гейта полигона отдельным пунктом: **A-запись
`mcp.test.doitai.ru`** (внешняя DNS-панель) до `certs-expand`.

---

## Чек-лист (doitai)

- [x] ветка `feat/env-per-stend` (с влитым полигоном) запушена в origin
- [x] сверка ключей `.env` ↔ новые слои выполнена, расхождения разобраны
- [x] `ASR_WS_UPSTREAM`, `QDRANT_VERSION`, `ECOSYSTEM_SUBNET/GATEWAY` явно решены
- [x] `env/doitai/config.env` финализирован и закоммичен
- [x] `env/doitai/secrets.env` на сервере: 7 ключей, непустые, chmod 600, без `#`/`$`
- [x] `make -C <worktree> STAND=doitai config` → exit 0, worktree и копия секрета убраны
- [x] маркер `.stand` = `doitai` положен; вызовы `make` из cron/Jenkins/timers
      инвентаризованы (не из чужого каталога, без ошибочного `STAND=`)
- [x] A-запись `mcp.test.doitai.ru` создана (до `certs-expand`)
- [x] мерж в master, деплой зелёный
- [x] `make certs-expand` прошёл, в SAN 8 доменов
- [x] `ps`/`nginx-test`/`neo4j-smoke`/7 доменов/образ qdrant — проверены
- [x] приёмка внешнего контура: `runner/poll` 401, `api/v1` 404, `/` 404
- [ ] плоский `.env` удалён после контрольного срока (бэкап в `~`)
- [ ] beads `ai-box-infra-11l` и `ai-box-infra-3q9` закрыты,
      `.claude/wiki/decisions/env-per-stend.md` дополнен фактическими
      отклонениями, запись в `log.md`

## Боевые уроки прогона на doitai (2026-07-30)

- **Сверка вскрыла три ключа**, потеря которых ломала бы тихо: `QDRANT_VERSION`
  (живой storage v1.17.0 против дефолта v1.12.4), `REDIS_MAXMEMORY=2gb` (дефолт
  512mb — вчетверо меньше; при `volatile-lru` ключи без TTL, т.е. очереди
  Horizon, не вытесняются, и запись начала бы отдавать OOM), `ASR_WS_UPSTREAM`.
  Остальные 16 ключей живого `.env` совпали один-в-один.
- **`COMPOSE_PROJECT_NAME` в `.env` не оказалось** — имя проекта пинится строкой
  `name: ai_box_infra` в `docker-compose.yml`, поэтому при переходе на
  `--env-file` тома не «переехали». Это был главный риск потери данных: другое
  имя проекта = новые пустые тома и пустые БД под работающими приложениями.
  На новом стенде проверять **до** мержа: `grep COMPOSE .env` и `name:` в compose.
- **Плоский `.env` после перехода стал ловушкой для ручных команд**: `docker
  compose …` без `--env-file` подхватывает его автоматически и падает на
  `TEST_MCP_DOMAIN is missing a value`. Ручные вызовы — только через `make`
  (или с тремя `--env-file`). Ещё один довод довести Шаг 8 до конца.
- **`cron` на doitai не было вовсе** — `certs-renew` никогда не был запланирован,
  сертификат жил на ручных продлениях. Поставлена недельная строка (стенд из
  маркера, лог в `~/certs-renew.log`).
- **Гигиена секретов:** `REDIS_PASSWORD` виден в `docker inspect`/`ps` — compose
  передаёт его аргументом `--requirepass`. Не эта задача внесла, но на хосте с
  недоверенными пользователями пароль читается любым, у кого есть docker;
  кандидат на переезд в файл конфигурации/`REDIS_ARGS`.
- `docker exec infra_nginx openssl` не работает (в alpine-образе nginx нет
  openssl) — сертификат смотреть контейнером certbot (`certbot certificates`).
- Пересоздание `infra_nginx` на `up` неизбежно (меняется `environment`), и новый
  vhost появляется только после `post-deploy` → `testzone-sync` + render + reload:
  между `up` и reload шаблона `test-mcp.conf` в контейнере ещё нет. Это нормально,
  простоя нет — nginx перезапускается за секунды со старым набором vhost'ов.
