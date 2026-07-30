# Управление shared-стеком экосистемы AiBox.
# Все команды выполняются на сервере из корня этого репозитория.

COMPOSE = docker compose

# Домены и пароли — из .env этой копии
-include .env
export

# Домены одного SAN-сертификата (первый задаёт имя lineage = CERT_NAME).
# Тест-домены включены сюда осознанно: они уже в живом сертификате, и без них
# certs-init сузил бы SAN и уронил тест-зону.
DOMAINS = -d $(ROOT_DOMAIN) -d $(FRONT_DOMAIN) -d $(API_DOMAIN) -d $(ADMIN_DOMAIN) \
          -d $(TEST_FRONT_DOMAIN) -d $(TEST_API_DOMAIN) -d $(TEST_ADMIN_DOMAIN) \
          -d $(TEST_MCP_DOMAIN)
CERT_EMAIL ?= admin@amulex.ru

# Neo4j: плагин GDS ставим сами (пин версии + sha256), НЕ через NEO4J_PLUGINS —
# так нет egress-зависимости на старте контейнера. Версию Neo4j↔GDS пинить
# по матрице совместимости GDS (2.13.x — единственная линия под Neo4j 5.26.x).
NEO4J_GDS_VERSION ?= 2.13.4
NEO4J_GDS_SHA256  ?= 10e072f73992224f1159f246c9d6a89da5f3b3434aeffa5be42647edda13a8d8
NEO4J_GDS_URL     ?= https://github.com/neo4j/graph-data-science/releases/download/$(NEO4J_GDS_VERSION)/neo4j-graph-data-science-$(NEO4J_GDS_VERSION).jar
NEO4J_PLUGINS_DIR := neo4j/plugins
NEO4J_GDS_JAR     := $(NEO4J_PLUGINS_DIR)/neo4j-graph-data-science-$(NEO4J_GDS_VERSION).jar

.PHONY: up down restart ps logs build-base build-base-dev testzone-enable testzone-sync mariadb-cli redis-cli \
        certs-init certs-renew certs-selfsigned nginx-reload nginx-render nginx-test db-import \
        neo4j-plugins neo4j-cli neo4j-smoke neo4j-dump neo4j-restore

# neo4j-plugins — предшаг: host-каталог neo4j/plugins должен быть пополнён
# до старта контейнера neo4j (иначе GDS не загрузится, поймает neo4j-smoke).
up: neo4j-plugins
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f --tail=200

# Базовый PHP-образ для всех приложений экосистемы.
# Приложения используют его как FROM/image: aibox/php-base:8.3
build-base:
	docker build -t aibox/php-base:8.3 php-base

# Dev-вариант (+xdebug) для eco-стеков на dev-машинах
build-base-dev: build-base
	docker build -t aibox/php-base:8.3-dev -f php-base/Dockerfile.dev php-base

mariadb-cli:
	$(COMPOSE) exec mariadb mariadb -uroot -p$$DB_ROOT_PASSWORD

# Импорт дампа при миграции со старого прода:
#   make db-import DB=ai_box FILE=/path/ai_box.sql
db-import:
	test -n "$(DB)" && test -f "$(FILE)"
	$(COMPOSE) exec -T mariadb mariadb -uroot -p$$DB_ROOT_PASSWORD $(DB) < $(FILE)

redis-cli:
	$(COMPOSE) exec redis redis-cli -a $$REDIS_PASSWORD

nginx-test:
	$(COMPOSE) exec nginx nginx -t

# Тест-шаблоны лежат в templates-test/, а рендерятся из templates/test-*.template —
# это КОПИИ, которые делает testzone-enable. Без пересинхронизации правка
# templates-test/ не доезжает до nginx. На хостах без тест-зоны — no-op.
testzone-sync:
	@if [ "$$(readlink docker-compose.override.yml 2>/dev/null)" = "docker-compose.testzone.yml" ]; then \
		cp nginx/templates-test/front.conf.template nginx/templates/test-front.conf.template; \
		cp nginx/templates-test/api.conf.template nginx/templates/test-api.conf.template; \
		cp nginx/templates-test/admin.conf.template nginx/templates/test-admin.conf.template; \
		cp nginx/templates-test/internal-test.conf.template nginx/templates/test-internal.conf.template; \
		cp nginx/templates-test/mcp.conf.template nginx/templates/test-mcp.conf.template; \
		echo "тест-зона активна: шаблоны пересинхронизированы"; \
	else \
		echo "тест-зона не активирована — пересинхронизация не нужна"; \
	fi

# Перерендер templates → conf.d в РАБОТАЮЩЕМ контейнере. Штатный envsubst образа
# nginx отрабатывает только в entrypoint при старте, поэтому без этого шага правка
# шаблона доезжает до хоста, деплой отчитывается успехом, а nginx продолжает
# работать по старому конфигу — молча (ai-box-back-99co).
nginx-render: testzone-sync
	$(COMPOSE) exec nginx /docker-entrypoint.d/20-envsubst-on-templates.sh

# Рендер → проверка → перечитка. Порядок важен: nginx -t обязан проверять уже
# отрендеренный конфиг, иначе reload подхватит непроверенное.
nginx-reload:
	$(MAKE) nginx-render
	$(MAKE) nginx-test
	$(COMPOSE) exec nginx nginx -s reload

# Первичное получение сертификата на пустом сервере — ДО первого `make up`
# (standalone-режим занимает порт 80; nginx ещё не должен работать).
certs-init:
	$(COMPOSE) run --rm -p 80:80 certbot certonly --standalone \
		--non-interactive --agree-tos -m $(CERT_EMAIL) $(DOMAINS)

# Продление на работающем стеке (webroot через nginx) + перечитка сертификата.
# Повесить в cron хоста: 0 4 * * 1  cd /opt/ai-box-infra && make certs-renew
certs-renew:
	$(COMPOSE) run --rm certbot renew --webroot -w /var/www/certbot
	$(MAKE) nginx-reload

# Self-signed сертификат в volume letsencrypt (локальная разработка/репетиция).
# SAN — все четыре домена из .env; lineage = CERT_NAME (default ROOT_DOMAIN).
certs-selfsigned:
	$(COMPOSE) run --rm --entrypoint sh certbot -c '\
		CERT=$${CERT_NAME:-$(ROOT_DOMAIN)}; \
		mkdir -p /etc/letsencrypt/live/$$CERT && \
		openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
			-subj "/CN=$(ROOT_DOMAIN)" \
			-addext "subjectAltName=DNS:$(ROOT_DOMAIN),DNS:$(FRONT_DOMAIN),DNS:$(API_DOMAIN),DNS:$(ADMIN_DOMAIN)" \
			-keyout /etc/letsencrypt/live/$$CERT/privkey.pem \
			-out /etc/letsencrypt/live/$$CERT/fullchain.pem'

# Активация тест-зоны на хосте: тест-шаблоны в общий каталог templates
# + постоянный override (подробности — docker-compose.testzone.yml).
testzone-enable:
	ln -sf docker-compose.testzone.yml docker-compose.override.yml
	$(MAKE) testzone-sync
	$(COMPOSE) up -d --force-recreate nginx

# Идемпотентная установка плагина GDS в neo4j/plugins (bind-mount :/plugins:ro).
# Валидный jar на месте → skip. Иначе: удалить прочие версии, скачать во
# временный файл, ЖЁСТКО сверить sha256 (mismatch → abort), атомарно перенести.
# Предшаг перед `up` (host-каталог должен быть пополнён до старта контейнера).
neo4j-plugins:
	@mkdir -p $(NEO4J_PLUGINS_DIR)
	@if [ -f "$(NEO4J_GDS_JAR)" ] && echo "$(NEO4J_GDS_SHA256)  $(NEO4J_GDS_JAR)" | sha256sum -c - >/dev/null 2>&1; then \
		echo "GDS $(NEO4J_GDS_VERSION): jar на месте, sha256 ок — skip"; \
	else \
		echo "GDS $(NEO4J_GDS_VERSION): качаю $(NEO4J_GDS_URL)"; \
		rm -f $(NEO4J_PLUGINS_DIR)/neo4j-graph-data-science-*.jar; \
		curl -fsSL -o "$(NEO4J_GDS_JAR).tmp" "$(NEO4J_GDS_URL)"; \
		echo "$(NEO4J_GDS_SHA256)  $(NEO4J_GDS_JAR).tmp" | sha256sum -c - || { rm -f "$(NEO4J_GDS_JAR).tmp"; echo "GDS sha256 MISMATCH — abort"; exit 1; }; \
		mv "$(NEO4J_GDS_JAR).tmp" "$(NEO4J_GDS_JAR)"; chmod 644 "$(NEO4J_GDS_JAR)"; \
		echo "GDS $(NEO4J_GDS_VERSION): установлен"; \
	fi

neo4j-cli:
	$(COMPOSE) exec neo4j cypher-shell -u neo4j -p "$$NEO4J_PASSWORD"

# Проверка живого GDS: ОБЯЗАН вернуть $(NEO4J_GDS_VERSION). Ловит рассинхрон
# Neo4j↔GDS (несовместимый плагин Neo4j не загрузит → gds.version() не найдётся).
neo4j-smoke:
	$(COMPOSE) exec neo4j cypher-shell -u neo4j -p "$$NEO4J_PASSWORD" "RETURN gds.version() AS gds"

# Ручной офлайн-дамп community: стоп сервиса → дамп одноразовым контейнером на
# том же томе → старт. Дамп в ./backups/neo4j.dump. (Авто-бэкап — ai-box-infra-4tb.)
neo4j-dump:
	@mkdir -p backups
	$(COMPOSE) stop neo4j
	$(COMPOSE) run --rm -v $(PWD)/backups:/backups neo4j neo4j-admin database dump neo4j --to-path=/backups --overwrite-destination=true
	$(COMPOSE) start neo4j

# Восстановление из ./backups/neo4j.dump (ПЕРЕЗАПИШЕТ БД). Сервис остановлен на время.
neo4j-restore:
	$(COMPOSE) stop neo4j
	$(COMPOSE) run --rm -v $(PWD)/backups:/backups neo4j neo4j-admin database load neo4j --from-path=/backups --overwrite-destination=true
	$(COMPOSE) start neo4j
