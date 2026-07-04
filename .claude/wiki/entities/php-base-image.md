---
title: Базовый PHP-образ приложений
type: entity
tags: [docker, php, image]
sources: [php-base/Dockerfile, php-base/Dockerfile.dev]
updated: 2026-07-04
---

# Базовый PHP-образ

`aibox/php-base:8.3` (`php-base/Dockerfile`): php:8.3-fpm + pdo_mysql,
mbstring, zip, bcmath, intl, opcache, pcntl, gd, sockets + pecl redis +
composer. Заменил три почти идентичных `Dockerfile.prod` приложений
(различие было только в WORKDIR — теперь его задаёт `working_dir` compose).

`aibox/php-base:8.3-dev` (`Dockerfile.dev`): FROM базового + xdebug — для
eco-стеков на dev-машинах (`PHP_BASE_IMAGE` в `.env` приложения).

Сборка: `make build-base` / `make build-base-dev` на каждом хосте
(registry пока нет — при появлении CI публиковать версионированные теги;
изменение образа задевает все приложения).

## Связи

- [[entity:shared-stack]]
- [[integration:app-stacks]]
