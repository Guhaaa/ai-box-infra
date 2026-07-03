# Блок eco-* таргетов для Makefile ai-box (см. README парковки).
# Переменные — рядом с prod-аналогами в шапке Makefile:
#   DOCKER_COMPOSE_ECO = sudo docker compose --env-file .env -f .docker/docker-compose.ecosystem.yml
#   PHP_ECO = $(DOCKER_COMPOSE_ECO) exec -T php
#   ARTISAN_ECO = $(PHP_ECO) php artisan
# И в .PHONY: eco-up eco-down eco-restart eco-logs eco-shell eco-migrate eco-deploy

# ─── Production на общей инфре (ai-box-infra, сеть ecosystem) ────────────────
# Целевой прод-стек после переезда; см. runbook в репо ai-box-infra.
# Образ aibox/php-base:8.3 собирается в ai-box-infra (make build-base).

eco-up:
	$(DOCKER_COMPOSE_ECO) up -d

eco-down:
	$(DOCKER_COMPOSE_ECO) down

eco-restart:
	$(DOCKER_COMPOSE_ECO) restart

eco-logs:
	$(DOCKER_COMPOSE_ECO) logs -f

eco-shell:
	$(DOCKER_COMPOSE_ECO) exec php bash

eco-migrate:
	$(ARTISAN_ECO) migrate --force

eco-deploy:
	git pull origin master
	sudo chown -R $${PHP_UID:-1001}:$${PHP_GID:-1001} storage bootstrap/cache
	sudo chmod -R 775 storage bootstrap/cache
	$(DOCKER_COMPOSE_ECO) up -d
	$(PHP_ECO) composer install --no-dev --optimize-autoloader
	$(ARTISAN_ECO) migrate --force
	$(DOCKER_COMPOSE_ECO) restart php queue
	$(ARTISAN_ECO) optimize
