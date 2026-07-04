# Управление shared-стеком экосистемы AiBox.
# Все команды выполняются на сервере из корня этого репозитория.

COMPOSE = docker compose

# Домены и пароли — из .env этой копии
-include .env
export

# Домены одного SAN-сертификата (первый задаёт имя lineage = CERT_NAME)
DOMAINS = -d $(ROOT_DOMAIN) -d $(FRONT_DOMAIN) -d $(API_DOMAIN) -d $(ADMIN_DOMAIN)
CERT_EMAIL ?= admin@amulex.ru

.PHONY: up down restart ps logs build-base build-base-dev testzone-enable mariadb-cli redis-cli \
        certs-init certs-renew certs-selfsigned nginx-reload nginx-test db-import

up:
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

nginx-reload: nginx-test
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
	cp nginx/templates-test/front.conf.template nginx/templates/test-front.conf.template
	cp nginx/templates-test/api.conf.template nginx/templates/test-api.conf.template
	cp nginx/templates-test/admin.conf.template nginx/templates/test-admin.conf.template
	cp nginx/templates-test/internal-test.conf.template nginx/templates/test-internal.conf.template
	ln -sf docker-compose.testzone.yml docker-compose.override.yml
	$(COMPOSE) up -d --force-recreate nginx
