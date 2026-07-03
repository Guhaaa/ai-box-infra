# Парковка: ecosystem-стек ai-box

Файлы тонкого прод-стека ai-box, **временно откаченные** из репозитория
ai-box (2026-07-03): правка мешала деплою на этапе переезда на внутренний
LLM-сервис. При возобновлении этапа переезда инфры вернуть в ai-box:

- `docker-compose.ecosystem.yml` → `.docker/docker-compose.ecosystem.yml`
- `php-fpm-ecosystem.conf` → `.docker/php/php-fpm-ecosystem.conf`
- `Makefile.eco.mk` → блок eco-* таргетов в конец `Makefile` ai-box
  (+ `eco-*` в .PHONY и переменные `DOCKER_COMPOSE_ECO`/`PHP_ECO`/
  `ARTISAN_ECO` рядом с prod-аналогами).

Аналогичные файлы в ai-box-data-registry и ai-box-mcp остались на месте
(деплою там не мешают).
