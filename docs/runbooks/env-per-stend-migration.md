# Runbook: миграция боевых стендов на env-per-stend (Фаза 2)

> **Статус: НЕ ВЫПОЛНЕН.** Фаза 1 (сборка артефактов + миграция локального
> стенда) готова на ветке `feat/env-per-stend` и в master **не запушена**.
> Эта фаза — операция на боевых серверах, идёт только с явного «go» человека.
>
> Задача — bead `ai-box-infra-11l`. Решение и trade-off'ы —
> `.claude/wiki/decisions/env-per-stend.md`. Спека —
> `docs/superpowers/specs/2026-07-08-env-per-stend-design.md`, план Фазы 1 —
> `docs/superpowers/plans/2026-07-27-env-per-stend-infra.md` (§ФАЗА 2 — конспект
> этого раннбука).

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
   `TEST_API_DOMAIN`, `TEST_ADMIN_DOMAIN` (+ `TEST_MCP_DOMAIN` после мержа
   ветки полигона, см. §«Порядок мержа»).
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

---

## Фаза 2A — doitai (первый, автодеплой)

### Шаг 0. Подготовка на dev-машине (сервер не трогаем)

1. Запушить ветку в origin — **деплой не триггерится** (workflow только на master):

```bash
git push -u origin feat/env-per-stend
```

2. Привести README к новой модели (сейчас там ещё `cp .env.example .env`,
   строки ~82/119/133 и cron-пример без `STAND`) — правка едет в ветке,
   до мержа. Иначе master документирует выпиленный контракт.

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

### Шаг 7. Постпроверки

```bash
cd /var/www/ai-box-infra
STAND=doitai make ps                        # все сервисы Up, не restarting
STAND=doitai make nginx-test                # рендер+конфиг чист
STAND=doitai make neo4j-smoke               # ожидание: gds 2.13.4
docker inspect --format '{{.Config.Image}}' infra_qdrant   # версия НЕ откатилась
for h in doitai.ru app.doitai.ru api.doitai.ru admin.doitai.ru \
         app.test.doitai.ru api.test.doitai.ru admin.test.doitai.ru; do
  printf '%-26s %s\n' "$h" "$(curl -sS -o /dev/null -w '%{http_code}' -m 10 https://$h/)"
done
```

Отдельно — живой сценарий приложения (создание чата/шаг) и то, что диктовка
(ASR-локация) отвечает, если `ASR_WS_UPSTREAM` переносился.

### Шаг 8. Выпил плоского `.env` — **после контрольного срока**

Пока `.env` жив, откат = `git revert` мержа (старый Makefile снова читает
`.env`). Поэтому удаляем не в день мержа, а после зелёного деплоя + прогона
хотя бы одного `certs-renew` по cron:

```bash
cd /var/www/ai-box-infra
cp .env ~/env-backup-doitai-$(date +%F).env && chmod 600 ~/env-backup-doitai-*.env
rm .env
export STAND=doitai && make config && echo "стек не зависит от плоского .env"
```

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

## Порядок мержа: пересечение с ветками полигона

Ветка `feat/polygon-runner-ingress` (bead `ai-box-infra-3q9`, внешний вход
`mcp.test.doitai.ru`) конфликтует с этой:

| Файл | Пересечение |
|---|---|
| `Makefile` | обе правят верх файла: env-per-stend — блок `-include`/`COMPOSE`, polygon — `DOMAINS` (+ тест-SAN через `$(if …)`) и `testzone-sync` |
| `docker-compose.testzone.yml` | polygon добавляет **обязательный** `TEST_MCP_DOMAIN:?` |
| `.env.example` | polygon дописывает ключ в файл, который env-per-stend замещает `env/example/config.env` |
| `.claude/wiki/{concepts/deployment-topologies.md,log.md}` | обе дописывают секции |

**Рекомендация — polygon первым** (он завершён и держится на текущей модели
flat-`.env`; его гейт — `TEST_MCP_DOMAIN` в живом `.env` doitai + DNS + расширение
SAN). После его мержа `feat/env-per-stend` ребейзится на master и добирает:

1. `TEST_MCP_DOMAIN=mcp.test.doitai.ru` → `env/doitai/testzone.env`
   (иначе после мержа `compose up` на doitai красный на `:?`);
2. `DOMAINS` из polygon (вариант с `$(if …)` совместим со слоями: `testzone.env`
   подключается только на doitai, на прочих стендах переменные пусты);
3. `testzone-sync`-строку для `mcp.conf.template`;
4. комментарий про `TEST_MCP_DOMAIN` — в `env/example/config.env`, после чего
   `.env.example` удалить (он становится мёртвым дублем).

Если раньше уйдёт env-per-stend — те же четыре пункта делает ветка полигона,
и её гейт превращается в «ключ в `env/doitai/testzone.env`», а не в живой `.env`.

---

## Чек-лист (doitai)

- [ ] ветка запушена в origin, README приведён к env-per-stend
- [ ] сверка ключей `.env` ↔ новые слои выполнена, расхождения разобраны
- [ ] `ASR_WS_UPSTREAM`, `QDRANT_VERSION`, `ECOSYSTEM_SUBNET/GATEWAY` явно решены
- [ ] `env/doitai/config.env` финализирован и закоммичен
- [ ] `env/doitai/secrets.env` на сервере: 7 ключей, непустые, chmod 600, без `#`/`$`
- [ ] `make -C <worktree> STAND=doitai config` → exit 0, worktree и копия секрета убраны
- [ ] маркер `.stand` = `doitai` положен; вызовы `make` из cron/Jenkins/timers
      инвентаризованы (не из чужого каталога, без ошибочного `STAND=`)
- [ ] мерж в master, деплой зелёный
- [ ] `ps`/`nginx-test`/`neo4j-smoke`/7 доменов/образ qdrant — проверены
- [ ] плоский `.env` удалён после контрольного срока (бэкап в `~`)
- [ ] bead `ai-box-infra-11l` обновлён, `.claude/wiki/decisions/env-per-stend.md`
      дополнен фактическими отклонениями, запись в `log.md`

## Известные пробелы (следующими задачами)

- `.env.example` продолжает существовать рядом с `env/example/` — выпил
  привязан к мержу ветки полигона (см. выше).
